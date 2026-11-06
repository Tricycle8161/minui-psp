#!/bin/sh
PAK_DIR="$(dirname "$0")"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"
[ -f "$USERDATA_PATH/PSP-ppsspp/debug" ] && set -x

# shellcheck disable=SC2153 # LOGS_PATH is set by NextUI/MinUI
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
    write_game_switcher_preview
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

# Game switcher preview.
# NextUI's game switcher shows $SHARED_USERDATA_PATH/.minui/<EMU>/<rom file>.<slot>.bmp,
# but only when $SHARED_USERDATA_PATH/.minui/<EMU>/<rom file>.txt exists and holds <slot>
# (see readyResumePath() in NextUI's nextui.c). The image is opened with IMG_Load, so the
# content may be BMP or PNG regardless of the .bmp name (minarch itself writes PNG there).
# The stock TrimUI SDL2_image cannot decode JPEG, so PPSSPP's save-state thumbnails are
# converted to BMP with the bundled jpg2bmp.
#
# The same <rom file>.txt makes NextUI offer "Resume" for the game. Resuming is done by
# PPSSPP itself: the pak ships AutoLoadSaveState = 2 (newest), so every launch, resume or
# not, loads the game's newest save state, which is also the state whose thumbnail is
# shown. If the user turned auto-load off, a NextUI resume passes that state with --state
# instead. Without any save state, "Resume" simply starts the game.
STATE_DIR="$SHARED_USERDATA_PATH/PSP-ppsspp"
PREVIEW_ROM=""
STATE_THUMBS_BEFORE=""

# One "<crc> <size> <path>" line per save-state thumbnail (undo thumbnails excluded).
# Content checksums, unlike mtimes, catch every save, even several within one second.
list_state_thumbnails() {
    for jpg in "$STATE_DIR"/*.jpg; do
        case "$jpg" in *.undo.jpg) continue ;; esac
        [ -f "$jpg" ] && cksum "$jpg"
    done
}

# Prints the NextUI emu tag of a ROM the way NextUI's getEmuName() does: the Roms folder
# name, then the text in its last (...). Falls back to the pak name, then "PSP".
game_switcher_emu_tag() {
    emu_tag=""
    if [ -n "$ROMS_PATH" ]; then
        case "$1" in
        "$ROMS_PATH"/*/*)
            emu_tag="${1#"$ROMS_PATH"/}"
            emu_tag="${emu_tag%%/*}"
            ;;
        esac
    fi
    case "$emu_tag" in
    *"("*")"*)
        emu_tag="${emu_tag##*(}"
        emu_tag="${emu_tag%%)*}"
        ;;
    esac
    [ -n "$emu_tag" ] || emu_tag="$PAK_NAME"
    [ -n "$emu_tag" ] || emu_tag="PSP"
    printf '%s' "$emu_tag"
}

# The pak's own record of a ROM's preview: "source=<thumbnail|boxart|placeholder>" and
# "prefix=<PPSSPP save-state prefix of the game, e.g. ULUS10041_1.00>".
game_switcher_meta_file() {
    printf '%s' "$SHARED_USERDATA_PATH/.minui/$(game_switcher_emu_tag "$1")/.ppsspp/$(basename "$1").txt"
}

read_meta_value() {
    [ -f "$1" ] && sed -n "s/^$2=//p" "$1" | head -n 1
}

# Prints the newest slot thumbnail of a save-state prefix (nothing if none).
newest_state_thumbnail() {
    newest=""
    [ -n "$1" ] || return 0
    for jpg in "$STATE_DIR/$1"_*.jpg; do
        slot_part="${jpg#"$STATE_DIR/$1"_}"
        slot_part="${slot_part%.jpg}"
        case "$slot_part" in "" | *[!0-9]*) continue ;; esac
        [ -f "$jpg" ] || continue
        if [ -z "$newest" ] || [ "$jpg" -nt "$newest" ]; then
            newest="$jpg"
        fi
    done
    printf '%s' "$newest"
}

# Writes image $2 to $1 through a temp file, so a partial file never replaces the preview.
install_preview() {
    if [ "$3" = convert ]; then
        jpg2bmp "$2" "$1.tmp"
    else
        cp -f "$2" "$1.tmp"
    fi && mv -f "$1.tmp" "$1" && return 0
    rm -f "$1.tmp"
    return 1
}

# Called after PPSSPP exits and from cleanup(), so it also runs when the script is
# signalled (e.g. SIGTERM on power-off). Does its work at most once per launch.
write_game_switcher_preview() {
    rom_path="$PREVIEW_ROM"
    PREVIEW_ROM=""
    [ -n "$rom_path" ] && [ -n "$SHARED_USERDATA_PATH" ] || return 0

    rom_file="$(basename "$rom_path")"
    minui_dir="$SHARED_USERDATA_PATH/.minui/$(game_switcher_emu_tag "$rom_path")"
    slot_file="$minui_dir/$rom_file.txt"
    meta_file="$(game_switcher_meta_file "$rom_path")"
    mkdir -p "$minui_dir" "$(dirname "$meta_file")" || return 0

    # Reuse the slot if something already wrote one, otherwise point NextUI at slot 0.
    slot=""
    [ -f "$slot_file" ] && slot="$(head -n 1 "$slot_file" | tr -cd '0-9')"
    if [ -z "$slot" ]; then
        slot=0
        printf '%s' "$slot" >"$slot_file.tmp" && mv -f "$slot_file.tmp" "$slot_file"
    fi
    preview="$minui_dir/$rom_file.$slot.bmp"

    prefix="$(read_meta_value "$meta_file" prefix)"
    preview_source="$(read_meta_value "$meta_file" source)"
    boxart="$(dirname "$rom_path")/.media/${rom_file%.*}.png"
    placeholder="$PAK_DIR/res/game-switcher-placeholder.png"
    if [ ! -f "$preview" ]; then
        preview_source=""
    elif [ -z "$preview_source" ]; then
        # A preview without a record (older pak version): identify it by content.
        if cmp -s "$preview" "$placeholder"; then
            preview_source=placeholder
        elif [ -f "$boxart" ] && cmp -s "$preview" "$boxart"; then
            preview_source=boxart
        else
            preview_source=thumbnail
        fi
    fi

    # Thumbnails that are new or changed since launch. Only the launched game ran, so they
    # all belong to it; the newest is also the state PPSSPP auto-loads next time.
    thumb=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "
$STATE_THUMBS_BEFORE
" in *"
$line
"*) continue ;; esac
        jpg="${line#* * }"
        if [ -z "$thumb" ] || [ "$jpg" -nt "$thumb" ]; then
            thumb="$jpg"
        fi
    done <<EOF
$(list_state_thumbnails)
EOF
    if [ -n "$thumb" ]; then
        # PPSSPP names states <DISC_ID>_<DISC_VERSION>_<slot>.ppst/.jpg
        prefix="$(basename "$thumb" .jpg)"
        prefix="${prefix%_*}"
    elif [ "$preview_source" != thumbnail ]; then
        # No new state, but an earlier one of this game still beats boxart/placeholder.
        thumb="$(newest_state_thumbnail "$prefix")"
    fi

    # Upgrade order: placeholder < boxart < save-state thumbnail.
    if [ -n "$thumb" ] && install_preview "$preview" "$thumb" convert; then
        preview_source=thumbnail
        echo "Game switcher preview from save state: $thumb"
    elif [ -f "$boxart" ] && { [ -z "$preview_source" ] || [ "$preview_source" = placeholder ]; }; then
        install_preview "$preview" "$boxart" && preview_source=boxart
    elif [ -z "$preview_source" ]; then
        install_preview "$preview" "$placeholder" && preview_source=placeholder
    fi

    if [ -n "$preview_source" ]; then
        printf 'source=%s\nprefix=%s\n' "$preview_source" "$prefix" >"$meta_file.tmp" &&
            mv -f "$meta_file.tmp" "$meta_file"
    fi
    sync
}

# NextUI writes /tmp/resume_slot.txt when the user picks "Resume". PPSSPP's auto-load
# already resumes, so this only prints a state for --state when auto-load is turned off.
resume_state_path() {
    [ -f /tmp/resume_slot.txt ] || return 0
    rm -f /tmp/resume_slot.txt
    auto_load="$(sed -n 's/^AutoLoadSaveState *= *//p' "$PPSSPP_INI" 2>/dev/null | head -n 1)"
    [ "$auto_load" = 0 ] || return 0
    state="$(newest_state_thumbnail "$(read_meta_value "$(game_switcher_meta_file "$1")" prefix)")"
    state="${state%.jpg}.ppst"
    [ -f "$state" ] && printf '%s' "$state"
}

main() {
    echo "1" >/tmp/stay_awake
    trap "cleanup" EXIT INT TERM HUP QUIT

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

    resume_state="$(resume_state_path "$1")"
    [ -n "$resume_state" ] && echo "Resuming from $resume_state"
    STATE_THUMBS_BEFORE="$(list_state_thumbnails)"
    PREVIEW_ROM="$1"

    # Launch emulator
    minui-power-control "${PPSSPP_BIN}_${PLATFORM}" &
    "${PPSSPP_BIN}_${PLATFORM}" "$*" --fullscreen --pause-menu-exit ${resume_state:+"--state=$resume_state"}

    write_game_switcher_preview
}

main "$@"
