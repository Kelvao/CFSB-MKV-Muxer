#!/usr/bin/env bash

set -euo pipefail

# ─── Constants ─────────────────────────────────────────────────────────────
readonly SCRIPT_NAME="$(basename "$0")"
readonly TAG="CFSB"
readonly THUMB_TIMESTAMP="00:00:30"
readonly SOURCES=("BD" "WEB-DL" "TV" "DVD" "HDTV")
GEN_THUMB=0
THUMB_TS=""

# ─── Colors & Styles ────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_CYAN='\033[36m'
    C_GREEN='\033[32m'
    C_YELLOW='\033[33m'
    C_RED='\033[31m'
    C_MAGENTA='\033[35m'
    C_BLUE='\033[34m'
else
    C_RESET='' C_BOLD='' C_DIM='' C_CYAN='' C_GREEN=''
    C_YELLOW='' C_RED='' C_MAGENTA='' C_BLUE=''
fi

# ─── UI ─────────────────────────────────────────────────────────────────────
die() {
    echo -e "${C_RED}${C_BOLD}  ✖  $*${C_RESET}" >&2
    exit 1
}

info()    { echo -e "${C_CYAN}  ℹ  ${C_RESET}${C_BOLD}$*${C_RESET}"; }
success() { echo -e "${C_GREEN}  ✔  ${C_RESET}${C_BOLD}$*${C_RESET}"; }
warn()    { echo -e "${C_YELLOW}  ⚠  ${C_RESET}$*"; }
step()    { echo -e "${C_MAGENTA}  ▶  ${C_RESET}${C_BOLD}$*${C_RESET}"; }
detail()  { echo -e "${C_DIM}       $*${C_RESET}"; }

sep() {
    echo -e "${C_DIM}  ────────────────────────────────────────────────${C_RESET}"
}

header() {
    echo
    echo -e "${C_BLUE}${C_BOLD}  ╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BLUE}${C_BOLD}  ║   🎌  Crystal FanSub MKV Muxer               ║${C_RESET}"
    echo -e "${C_BLUE}${C_BOLD}  ╚══════════════════════════════════════════════╝${C_RESET}"
    echo
}

# ─── Cleanup on interrupt/error ──────────────────────────────────────────────
# Restores cursor and removes orphaned temp file on Ctrl+C or mid-mux failure.
cleanup() {
    tput cnorm 2>/dev/null || true
    if [[ -n "${mkv_temp:-}" && -e "${mkv_temp:-}" ]]; then
        rm -f -- "$mkv_temp"
    fi
}
trap cleanup EXIT INT TERM

# ─── Spinner ──────────────────────────────────────────────────────────────────
spinner() {
    local label="$1"; shift
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0

    local tmp_out tmp_err
    tmp_out=$(mktemp)
    tmp_err=$(mktemp)

    "$@" >"$tmp_out" 2>"$tmp_err" &
    local pid=$!

    tput civis 2>/dev/null || true

    while kill -0 "$pid" 2>/dev/null; do
        echo -ne "\r${C_CYAN}  ${frames[$i]}  ${C_RESET}${C_BOLD}${label}${C_RESET}   "
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.08
    done

    wait "$pid"
    local exit_code=$?

    tput cnorm 2>/dev/null || true
    echo -ne "\r"

    if [[ $exit_code -eq 0 ]]; then
        echo -e "${C_GREEN}  ✔  ${C_RESET}${C_BOLD}${label}${C_RESET}"
    else
        echo -e "${C_RED}  ✖  ${C_RESET}${C_BOLD}${label} falhou${C_RESET}"
        cat "$tmp_err" >&2
        rm -f "$tmp_out" "$tmp_err"
        exit "$exit_code"
    fi

    # Caller reads command stdout via this global instead of a subshell,
    # since spinner already needs the PID in the current shell for kill -0.
    _SPINNER_OUT=$(cat "$tmp_out")
    rm -f "$tmp_out" "$tmp_err"
}

# ─── Dependency checks ────────────────────────────────────────────────────────
check_deps() {
    local missing=()

    for cmd in mkvmerge mkvinfo ffmpeg; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    if ! command -v crc32 &>/dev/null && ! command -v cfv &>/dev/null; then
        missing+=("crc32 ou cfv")
    fi

    (( ${#missing[@]} == 0 )) || die "Dependências faltando: ${missing[*]}"
}

# ─── Track detection ────────────────────────────────────────────────────────
detect_video_codec() {
    local info
    info=$(mkvmerge --identify "$1" | grep -i "video" || true)

    if [[ "$info" == *"HEVC"* || "$info" == *"H.265"* ]]; then echo "HEVC"
    elif [[ "$info" == *"AVC"* || "$info" == *"H.264"* ]]; then echo "AVC"
    elif [[ "$info" == *"AV1"* ]]; then echo "AV1"
    else
        warn "Codec de vídeo não reconhecido — usando 'Desconhecido' no nome do arquivo."
        echo "Desconhecido"
    fi
}

detect_audio_codec() {
    local info
    info=$(mkvmerge --identify "$1" | grep -i "audio" | head -n 1 || true)

    if [[ "$info" == *"AAC"* ]];   then echo "AAC"
    elif [[ "$info" == *"FLAC"* ]]; then echo "FLAC"
    elif [[ "$info" == *"Opus"* ]]; then echo "Opus"
    else
        warn "Codec de áudio não reconhecido — usando 'Desconhecido' no nome do arquivo."
        echo "Desconhecido"
    fi
}

detect_resolution() {
    local height
    height=$(mkvmerge -J "$1" \
        | grep -oP '"display_dimensions":\s*"\d+x\K\d+' \
        | head -n 1)

    if [[ -z "$height" ]]; then
        height=$(mkvmerge -J "$1" \
            | grep -oP '"pixel_dimensions":\s*"\d+x\K\d+' \
            | head -n 1)
    fi

    if [[ -z "$height" ]]; then
        warn "Resolução não detectada — usando 'Desconhecida' no nome do arquivo."
        echo "Desconhecida"
    else
        echo "${height}p"
    fi
}

count_source_tracks() {
    mkvmerge --ui-language en_US --identify "$1" | grep -cP "^Track ID \d+: $2 " || true
}

# ─── Video duration (for JSON export) ───────────────────────────────────────
get_video_duration_seconds() {
    local file="$1"
    local raw

    raw=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$file")
    printf '%.0f' "$raw"
}

format_duration() {
    local total_seconds="$1"
    local mins secs rem_hrs

    mins=$(( total_seconds / 60 ))
    secs=$(( total_seconds % 60 ))

    (( secs > 35 )) && (( mins++ ))

    if (( mins >= 60 )); then
        rem_hrs=$(( mins % 60 ))
        mins=$(( mins / 60 ))
        (( rem_hrs > 35 )) && (( mins++ ))
        echo "${mins}hr"
    else
        echo "${mins}m"
    fi
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

write_mux_metadata_json() {
    local json_path="$1"
    local anime="$2"
    local duracao="$3"
    local crc="$4"

    cat > "$json_path" <<EOF
{
  "anime": "$(json_escape "$anime")",
  "duracao": "$duracao",
  "crc": "$crc"
}
EOF
}

# ─── CRC-32 calculation ────────────────────────────────────────────────────
calc_crc32() {
    local file="$1"
    local hash

    if command -v crc32 &>/dev/null; then
        hash=$(crc32 "$file")
    else
        hash=$(cfv -g "$file" | tail -n 1 | awk '{print $NF}')
    fi

    echo "${hash^^}"
}

# ─── User input collection ───────────────────────────────────────────────────
select_source() {
    local selected=0
    local count=${#SOURCES[@]}
    local key rest

    echo -e "  ${C_CYAN}💿${C_RESET} Source (↑/↓ + Enter, ou digite o número):" >&2

    while true; do
        for i in "${!SOURCES[@]}"; do
            if [[ $i -eq $selected ]]; then
                echo -e "    ${C_GREEN}❯ ${SOURCES[$i]}${C_RESET}" >&2
            else
                echo -e "      ${SOURCES[$i]}" >&2
            fi
        done

        IFS= read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 rest
            key+="$rest"
        fi

        case "$key" in
            $'\x1b[A') (( selected = (selected - 1 + count) % count )) ;;
            $'\x1b[B') (( selected = (selected + 1) % count )) ;;
            "")        break ;;
            [1-9])     (( key <= count )) && { selected=$(( key - 1 )); break; } ;;
            *)         ;;
        esac

        echo -ne "\033[${count}A" >&2
    done

    echo "${SOURCES[$selected]}"
}

prompt_user() {
    echo
    echo -e "${C_BOLD}  📝  Informações do episódio${C_RESET}"
    sep
    echo -ne "  ${C_CYAN}🎬${C_RESET} Nome do Anime      : "; read -r ANIME
    echo -ne "  ${C_CYAN}📺${C_RESET} Número do Episódio : "; read -r EPISODE
    SOURCE=$(select_source)
    sep
    echo

    [[ -n "$ANIME" ]]    || die "Nome do anime não pode ser vazio."
    [[ -n "$EPISODE" ]]  || die "Número do episódio não pode ser vazio."

    # Strips '/' and ':' so user input can't break the output filename or
    # be interpreted as a path separator by mv.
    ANIME="${ANIME//[\/:]/_}"
    EPISODE="${EPISODE//[\/:]/_}"
}

prompt_thumbnail() {
    local answer

    echo -ne "  ${C_CYAN}🌅${C_RESET} Gerar thumbnail? (s/N): "; read -r answer
    [[ "${answer,,}" == "s" ]] || { GEN_THUMB=0; return; }

    GEN_THUMB=1
    echo -ne "  ${C_CYAN}⏱${C_RESET}  Timestamp (padrão ${THUMB_TIMESTAMP}): "; read -r answer
    THUMB_TS="${answer:-$THUMB_TIMESTAMP}"
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    header

    [[ $# -eq 1 ]] || die "Uso: $SCRIPT_NAME /caminho/da/pasta"

    local folder="$1"
    [[ -d "$folder" ]] || die "Pasta não encontrada: $folder"

    step "Verificando dependências..."
    check_deps
    success "Dependências OK"

    sep

    local source_mkv subtitle chapters
    local mkv_count ass_count txt_count fonts_count=0

    mkv_count=$(find "$folder" -maxdepth 1 -type f -name "*.mkv" | wc -l)
    ass_count=$(find "$folder" -maxdepth 1 -type f -name "*.ass" | wc -l)
    txt_count=$(find "$folder" -maxdepth 1 -type f -name "*.txt" | wc -l)

    if [[ -d "$folder/fonts" ]]; then
        fonts_count=$(find "$folder/fonts" -type f | wc -l)
    fi

    (( mkv_count <= 1 )) || die "Mais de um arquivo .mkv encontrado em: $folder — deixe apenas um por pasta."
    (( ass_count <= 1 )) || die "Mais de um arquivo .ass encontrado em: $folder — deixe apenas um por pasta."
    (( txt_count <= 1 )) || die "Mais de um arquivo .txt encontrado em: $folder — deixe apenas um por pasta."

    source_mkv=$(find "$folder" -maxdepth 1 -type f -name "*.mkv" | head -n 1)
    subtitle=$(find "$folder" -maxdepth 1 -type f -name "*.ass" | head -n 1)
    chapters=$(find "$folder" -maxdepth 1 -type f -name "*.txt" | head -n 1)

    [[ -n "$source_mkv" ]] || die "Nenhum arquivo .mkv encontrado em: $folder"
    [[ -n "$subtitle" ]]   || die "Nenhum arquivo .ass encontrado em: $folder"
    [[ -n "$chapters" ]]   || die "Nenhum arquivo .txt encontrado em: $folder"

    grep -qP '^CHAPTER\d+=' "$chapters" || die "Arquivo de capítulos inválido: $chapters"

    info "Arquivo de origem detectado"
    detail "🎞  $(basename "$source_mkv")"
    detail "💬  $(basename "$subtitle")"
    detail "📖  $(basename "$chapters")"
    if (( fonts_count > 0 )); then
        detail "📎  Pasta fonts com $fonts_count aquivo(s)"
    fi

    prompt_user
    prompt_thumbnail

    local start_time=$SECONDS

    step "Analisando faixas de mídia..."

    # ── Detect codecs and resolution ──
    local video_codec audio_codec quality
    video_codec=$(detect_video_codec "$source_mkv")
    audio_codec=$(detect_audio_codec "$source_mkv")
    quality=$(detect_resolution "$source_mkv")

    success "Análise concluída"
    detail "🎥  Vídeo  : ${C_BOLD}${video_codec}${C_RESET}"
    detail "🔊  Áudio  : ${C_BOLD}${audio_codec}${C_RESET}"
    detail "📐  Resolução: ${C_BOLD}${quality}${C_RESET}"
    echo

    # ── Build names ──
    local base_name mkv_final
    base_name="[$TAG] ${ANIME} - ${EPISODE} [${quality}][${SOURCE}][${video_codec}][${audio_codec}]"
    mkv_temp="${folder}/${base_name}_TEMP.mkv"

    [[ -e "$mkv_temp" ]] && rm -f "$mkv_temp"

    local required_kb available_kb
    required_kb=$(du -k "$source_mkv" | cut -f1)
    available_kb=$(df -Pk "$folder" | awk 'NR==2 {print $4}')
    (( available_kb > required_kb )) || die "Espaço em disco insuficiente em: $folder"

    local video_count audio_count source_track_order i
    video_count=$(count_source_tracks "$source_mkv" "video")
    audio_count=$(count_source_tracks "$source_mkv" "audio")

    source_track_order=""
    for (( i = 0; i < video_count + audio_count; i++ )); do
        source_track_order+="0:${i},"
    done

    # ── Fonts ─────────────────────────────────────────────────────────────────
    local attachment_args=()
    if (( fonts_count > 0 )); then
        attachment_args+=(--no-attachments)
        while IFS= read -r -d '' font_file; do
            attachment_args+=(--attach-file "$font_file")
        done < <(find "$folder/fonts" -type f \( -iname "*.ttf" -o -iname "*.otf" \) -print0)
    fi
    
    # ── Mux with spinner ──
    spinner "Multiplexando faixas..." \
        mkvmerge \
            --ui-language pt_BR \
            --priority lower \
            --output "$mkv_temp" \
            --title "" \
            --no-subtitles \
            --no-chapters \
            "${attachment_args[@]}" \
            --no-global-tags \
            --language 1:ja-JP \
            --track-name '1:Japonês' \
            --original-flag 1:yes \
            --audio-tracks 1 \
            '(' "$source_mkv" ')' \
            --language 0:pt-BR \
            --track-name '0:Português do Brasil' \
            '(' "$subtitle" ')' \
            --chapters "$chapters" \
            --generate-chapters-name-template 'Capítulo <NUM:2>' \
            --track-order "${source_track_order}1:0"

    # ── CRC-32 with spinner ──
    # calc_crc32 is exported and invoked via positional arg ("$1"), not
    # interpolated into the bash -c string, so paths with spaces/quotes
    # don't break the command.
    export -f calc_crc32
    spinner "Calculando CRC-32..." \
        bash -c 'calc_crc32 "$1"' _ "$mkv_temp"
    local hash
    hash="$_SPINNER_OUT"

    mkv_final="${folder}/${base_name}[${hash}].mkv"
    mv -- "$mkv_temp" "$mkv_final"
    mkv_temp=""

    # ── Thumbnail ──
    local thumb=""
    if [[ $GEN_THUMB -eq 1 ]]; then
        thumb="${folder}/${base_name}[${hash}].webp"
        spinner "Gerando thumbnail..." \
            ffmpeg -ss "$THUMB_TS" -i "$mkv_final" -vf "thumbnail,setsar=1" -vframes 1 "$thumb" -y
    fi

    local video_seconds duracao json_final
    video_seconds=$(get_video_duration_seconds "$mkv_final")
    duracao=$(format_duration "$video_seconds")
    json_final="${mkv_final%.mkv}.json"
    write_mux_metadata_json "$json_final" "$ANIME" "$duracao" "$hash"

    local duration=$(( SECONDS - start_time ))
    # ── Final summary ──
    echo
    echo -e "${C_GREEN}${C_BOLD}  ╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}  ║   ✅  Episódio gerado com sucesso!           ║${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}  ╚══════════════════════════════════════════════╝${C_RESET}"
    echo
    detail "🎬  $(basename "$mkv_final")"
    detail "📄  $(basename "$json_final")"
    [[ -n "$thumb" ]] && detail "🌅  $(basename "$thumb")"
    detail "🕐  Tempo: $(( duration / 60 ))m $(( duration % 60 ))s"
    echo
}

main "$@"
