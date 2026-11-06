#!/bin/sh
PAK_DIR="$(dirname "$0")"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"
[ -f "$USERDATA_PATH/PSP-ppsspp/debug" ] && set -x

rm -f "$LOGS_PATH/$PAK_NAME.txt"
exec >>"$LOGS_PATH/$PAK_NAME.txt"
exec 2>&1

echo "$0" "$@"
cd "$PAK_DIR" || exit 1
mkdir -p "$USERDATA_PATH/PSP-ppsspp"

architecture=arm
if uname -m | grep -q '64'; then
    architecture=arm64
fi

export PAK_DIR="$SDCARD_PATH/Emus/$PLATFORM/$PAK_NAME.pak"
export EMU_DIR="$PAK_DIR/PPSSPP"

export PATH="$EMU_DIR:$PAK_DIR/bin/$architecture:$PAK_DIR/bin/$PLATFORM:$PAK_DIR/bin:$PATH"
export HOME="$EMU_DIR"
export LD_LIBRARY_PATH="$EMU_DIR:$PAK_DIR/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"
export SDL_GAMECONTROLLERCONFIG_FILE="$EMU_DIR/assets/gamecontrollerdb.txt"

PPSSPP_BIN="PPSSPPSDL"
PPSSPP_INI="$EMU_DIR/.config/ppsspp/PSP/SYSTEM/ppsspp.ini"

cleanup() {
    rm -f /tmp/stay_awake
    
    restore_cpu_settings 0
    restore_cpu_settings 4

    umount "$EMU_DIR/.config/ppsspp/PSP/SAVEDATA" || true
    umount "$EMU_DIR/.config/ppsspp/PSP/PPSSPP_STATE" || true
}

update_ppsspp_setting() {
    setting_name="$1"
    setting_value="$2"
    
    # Allow users to disable config changes
    if [ -f "$USERDATA_PATH/PSP-ppsspp/no-config-changes" ]; then
        echo "Config changes disabled via no-config-changes flag."
        return
    fi

    if [ ! -f "$PPSSPP_INI" ]; then
        echo "Error: $PPSSPP_INI not found."
        exit 1
    fi

    if grep -q "^${setting_name}" "$PPSSPP_INI"; then
        sed -i "s/^${setting_name} *= *.*/${setting_name} = ${setting_value}/" "$PPSSPP_INI"
    else
        echo "Setting '$setting_name' not found in ini."
    fi
}

save_cpu_settings() {
    cpu_num="$1"
    cpu_path="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq"
    
    cat "${cpu_path}/scaling_governor" >"$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_governor.txt"
    cat "${cpu_path}/scaling_min_freq" >"$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_min_freq.txt"
    cat "${cpu_path}/scaling_max_freq" >"$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_max_freq.txt"
}

restore_cpu_settings() {
    cpu_num="$1"
    cpu_path="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq"
    
    if [ -f "$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_governor.txt" ]; then
        cat "$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_governor.txt" >"${cpu_path}/scaling_governor"
        rm -f "$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_governor.txt"
    fi
    if [ -f "$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_min_freq.txt" ]; then
        cat "$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_min_freq.txt" >"${cpu_path}/scaling_min_freq"
        rm -f "$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_min_freq.txt"
    fi
    if [ -f "$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_max_freq.txt" ]; then
        cat "$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_max_freq.txt" >"${cpu_path}/scaling_max_freq"
        rm -f "$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_max_freq.txt"
    fi
}

set_cpu_settings() {
    cpu_num="$1"
    governor="$2"
    min_freq="$3"
    max_freq="$4"
    cpu_path="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq"
    
    echo "$governor" >"${cpu_path}/scaling_governor"
    echo "$min_freq" >"${cpu_path}/scaling_min_freq"
    echo "$max_freq" >"${cpu_path}/scaling_max_freq"
}

# Auto-resume after shutdown.
# NextUI/MinUI read $SHARED_USERDATA_PATH/.minui/auto_resume.txt on boot
# (autoResume()): it holds the ROM path relative to $SDCARD_PATH, is deleted
# as soon as it is read, and the ROM is relaunched through its Emu Pak.
# minarch writes it only right before it powers the device off, so a crash,
# a forced power-off or a dead battery never resumes. We follow the same
# rule: the marker is written only once a power-off has been positively
# detected, never while the game is running.
AUTO_RESUME_PATH="$SHARED_USERDATA_PATH/.minui/auto_resume.txt"
# Written by NextUI/MinUI on an auto-resume (slot 9) for minarch, which reads
# and deletes it. PPSSPP never reads it, so we remove it ourselves, otherwise
# the next built-in core started in this boot would load its slot 9 state.
RESUME_SLOT_PATH="/tmp/resume_slot.txt"

set_auto_resume() {
    rom_path="$1"
    case "$rom_path" in
        "$SDCARD_PATH"/*) ;;
        *) return 1 ;;
    esac
    mkdir -p "$(dirname "$AUTO_RESUME_PATH")"
    printf '%s' "${rom_path#"$SDCARD_PATH"}" >"$AUTO_RESUME_PATH.tmp" &&
        mv -f "$AUTO_RESUME_PATH.tmp" "$AUTO_RESUME_PATH"
    sync
}

# True if the device is powering off (rather than the user quitting PPSSPP).
# Called once, right after PPSSPP exits.
shutdown_in_progress() {
    # Set by NextUI and by minui-power-control 3.0.0+.
    [ -f /tmp/poweroff ] && return 0
    # minui-power-control 1.x/2.x: button-handler runs its `shutdown` script
    # by absolute path (/tmp/selfgz*/shutdown). That script kills the
    # emulator first, then runs `poweroff` and sleeps until the system kills
    # it, so it is always still alive when PPSSPP exits because of it. Match
    # the command line only: the selfgz dir itself is deleted as soon as
    # power-control's launcher notices the emulator is gone.
    pgrep -f '/shutdown$|^([^ ]*/)?poweroff( |$)' >/dev/null 2>&1
}

# Arm auto-resume, then wait for the power-off to finish. We must not return
# to NextUI/MinUI here: on its next start it would read (and delete) the
# marker before the device is off.
arm_auto_resume_and_wait() {
    rom_path="$1"
    set_auto_resume "$rom_path" || return 0
    echo "Shutdown detected, auto-resume armed for $rom_path."
    cleanup
    # Signals are ignored by the caller; poweroff ends us with SIGKILL. If
    # the device has not powered off after a minute, drop the marker and go
    # back to the menu.
    i=0
    while [ "$i" -lt 60 ]; do
        sleep 1
        i=$((i + 1))
    done
    echo "Device did not power off, removing auto-resume marker."
    rm -f "$AUTO_RESUME_PATH"
    sync
}

main() {
    echo "1" >/tmp/stay_awake
    trap "cleanup" EXIT
    trap "exit 1" INT TERM HUP QUIT

    # NextUI/MinUI already consumed the marker if this is an auto-resume.
    # Drop the slot file meant for minarch, and any leftover marker.
    rm -f "$RESUME_SLOT_PATH" "$AUTO_RESUME_PATH"

    if [ "$PLATFORM" = "tg3040" ] && [ -z "$DEVICE" ]; then
        export PLATFORM="tg5040"
    fi

    if [ "$PLATFORM" = "tg5040" ]; then

        # Detect Trimui model (Brick or Smart Pro)
        trimui_model=$(strings /usr/trimui/bin/MainUI | grep ^Trimui)
        if [ "$trimui_model" = "Trimui Brick" ]; then
            update_ppsspp_setting "DisplayAspectRatio" "0.848000"
        else
            update_ppsspp_setting "DisplayAspectRatio" "1.000000"
        fi

        update_ppsspp_setting "GraphicsBackend" "0 (OPENGL)"
        export SDL_VIDEODRIVER=mali
        setalpha 0
        rm -f "$EMU_DIR/.config/ppsspp/PSP/SYSTEM/FailedGraphicsBackends.txt"
        save_cpu_settings 0
        set_cpu_settings 0 ondemand 1608000 1800000

    elif [ "$PLATFORM" = "tg5050" ]; then
        update_ppsspp_setting "DisplayAspectRatio" "1.000000"
        update_ppsspp_setting "GraphicsBackend" "3 (VULKAN)"
        save_cpu_settings 0
        save_cpu_settings 4
        set_cpu_settings 0 ondemand 1416000 1416000
        set_cpu_settings 4 performance 1992000 2160000
    fi

    if ! command -v minui-power-control >/dev/null 2>&1; then
        show_message "Minui-power-control not found." 3
        exit 1
    fi

    chmod +x "$PAK_DIR/bin/minui-power-control"

    allowed_platforms="tg5040 tg5050"
    if ! echo "$allowed_platforms" | grep -q "$PLATFORM"; then
        echo "$PLATFORM is not a supported platform."
        exit 1
    fi

    mkdir -p "$SDCARD_PATH/Saves/PSP"
    mkdir -p "$EMU_DIR/.config/ppsspp/PSP/SAVEDATA"
    mount -o bind "$SDCARD_PATH/Saves/PSP" "$EMU_DIR/.config/ppsspp/PSP/SAVEDATA"

    mkdir -p "$SHARED_USERDATA_PATH/PSP-ppsspp"
    mkdir -p "$EMU_DIR/.config/ppsspp/PSP/PPSSPP_STATE"
    mount -o bind "$SHARED_USERDATA_PATH/PSP-ppsspp" "$EMU_DIR/.config/ppsspp/PSP/PPSSPP_STATE"

    # Launch emulator
    minui-power-control "${PPSSPP_BIN}_${PLATFORM}" &
    "${PPSSPP_BIN}_${PLATFORM}" "$*" --fullscreen --pause-menu-exit

    # PPSSPP exited. A SIGTERM from here on most likely comes from poweroff
    # tearing everything down: finish the decision instead of dying halfway.
    trap "" INT TERM HUP QUIT
    if shutdown_in_progress; then
        arm_auto_resume_and_wait "$*"
    fi
    trap "exit 1" INT TERM HUP QUIT
}

main "$@"
