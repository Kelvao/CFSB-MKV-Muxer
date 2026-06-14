#!/usr/bin/env bash

set -euo pipefail

# ─── Constantes ───────────────────────────────────────────────────────────────
readonly SCRIPT_NAME="$(basename "$0")"
readonly TAG="CFSB"
THUMB_TS="${THUMB_TS:-00:03:00}"
readonly THUMB_TS

# ─── Cores & Estilos ──────────────────────────────────────────────────────────
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

# ─── UI ───────────────────────────────────────────────────────────────────────
die() {
    echo -e "${C_RED}${C_BOLD}  ✖  $*${C_RESET}" >&2
    exit 1
}

info()    { echo -e "${C_CYAN}  ℹ  ${C_RESET}${C_BOLD}$*${C_RESET}"; }
success() { echo -e "${C_GREEN}  ✔  ${C_RESET}${C_BOLD}$*${C_RESET}"; }
warn()    { echo -e "${C_YELLOW}  ⚠  ${C_RESET}$*" >&2; } # Melhoria 3: Enviado para stderr
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

# ─── Spinner ──────────────────────────────────────────────────────────────────
spinner() {
    local label="$1"; shift
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    local tmp_out tmp_err exit_code=0

    tmp_out=$(mktemp)
    tmp_err=$(mktemp)

    # Salva traps existentes e define os nossos
    local old_int old_term
    old_int=$(trap -p INT)
    old_term=$(trap -p TERM)
    trap 'tput cnorm 2>/dev/null || true; rm -f "$tmp_out" "$tmp_err"; exit 130' INT TERM

    "$@" >"$tmp_out" 2>"$tmp_err" &
    local pid=$!

    tput civis 2>/dev/null || true

    while kill -0 "$pid" 2>/dev/null; do
        echo -ne "\r${C_CYAN}  ${frames[$i]}  ${C_RESET}${C_BOLD}${label}${C_RESET}   "
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.08
    done

    wait "$pid" || exit_code=$?

    tput cnorm 2>/dev/null || true

    # Melhoria 1: Restaura traps de forma robusta com fallback seguro
    [[ -n "$old_int" ]]  && eval "$old_int"  || trap - INT
    [[ -n "$old_term" ]] && eval "$old_term" || trap - TERM

    echo -ne "\r"

    if [[ $exit_code -eq 0 ]]; then
        echo -e "${C_GREEN}  ✔  ${C_RESET}${C_BOLD}${label}${C_RESET}"
    else
        echo -e "${C_RED}  ✖  ${C_RESET}${C_BOLD}${label} falhou${C_RESET}"
        cat "$tmp_err" >&2
        rm -f "$tmp_out" "$tmp_err"
        exit "$exit_code"
    fi

    # Melhoria 2: Remoção do _SPINNER_OUT global que não era consumido
    rm -f "$tmp_out" "$tmp_err"
}

# ─── Verificações de dependências ─────────────────────────────────────────────
check_deps() {
    local missing=()

    for cmd in mkvmerge ffmpeg; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    if ! command -v crc32 &>/dev/null && ! command -v cfv &>/dev/null; then
        missing+=("crc32 ou cfv")
    fi

    [[ ${#missing[@]} -eq 0 ]] || die "Dependências faltando: ${missing[*]}"
}

# ─── Detecção de faixas ───────────────────────────────────────────────────────
detect_tracks() {
    _MKV_JSON=$(mkvmerge -J "$1")
}

parse_video_codec() {
    local codec_id
    codec_id=$(grep -oP '"codec_id":\s*"\K[^"]+' <<< "$_MKV_JSON" \
        | grep -i '^V_' | head -n 1 || true)

    if   [[ "$codec_id" == *"HEVC"* || "$codec_id" == *"H265"* ]]; then echo "HEVC"
    elif [[ "$codec_id" == *"AVC"* || "$codec_id" == *"H264"* ]]; then echo "AVC"
    elif [[ "$codec_id" == *"AV1"* ]];                             then echo "AV1"
    else
        warn "Codec de vídeo não reconhecido (${codec_id:-vazio}), assumindo HEVC"
        echo "HEVC"
    fi
}

parse_audio_codec() {
    local codec_id
    codec_id=$(grep -oP '"codec_id":\s*"\K[^"]+' <<< "$_MKV_JSON" \
        | grep -i '^A_' | head -n 1 || true)

    if   [[ "$codec_id" == *"AAC"* ]]; then echo "AAC"
    elif [[ "$codec_id" == *"FLAC"* ]]; then echo "FLAC"
    elif [[ "$codec_id" == *"OPUS"* ]]; then echo "Opus"
    else
        warn "Codec de áudio não reconhecido (${codec_id:-vazio}), assumindo AAC"
        echo "AAC"
    fi
}

parse_resolution() {
    local altura
    altura=$(grep -oP '"display_dimensions":\s*"\d+x\K\d+' <<< "$_MKV_JSON" \
        | head -n 1)

    if [[ -z "$altura" ]]; then
        altura=$(grep -oP '"pixel_dimensions":\s*"\d+x\K\d+' <<< "$_MKV_JSON" \
            | head -n 1)
    fi

    echo "${altura:-1080}p"
}

# ─── Cálculo de CRC-32 ────────────────────────────────────────────────────────
calc_crc32() {
    local file="$1"
    local hash

    if command -v crc32 &>/dev/null; then
        # Melhoria 4: Extrai apenas o valor hexadecimal de 8 caracteres (portabilidade)
        hash=$(crc32 "$file" | grep -oP '[0-9a-fA-F]{8}')
    else
        hash=$(cfv -g "$file" | tail -n 1 | awk '{print $NF}')
    fi

    echo "${hash^^}"
}

# ─── Coleta de entrada do usuário ─────────────────────────────────────────────
prompt_user() {
    # Melhoria 6: Uso de nameref para evitar globais implícitas e isolar o escopo
    declare -n ref_anime="$1"
    declare -n ref_ep="$2"
    declare -n ref_src="$3"

    echo
    echo -e "${C_BOLD}  📝  Informações do episódio${C_RESET}"
    sep
    echo -ne "  ${C_CYAN}🎬${C_RESET} Nome do Anime      : "; read -r ref_anime
    echo -ne "  ${C_CYAN}📺${C_RESET} Número do Episódio : "; read -r ref_ep
    echo -ne "  ${C_CYAN}💿${C_RESET} Source             : "; read -r ref_src
    sep
    echo

    [[ -n "$ref_anime" ]] || die "Nome do anime não pode ser vazio."
    [[ -n "$ref_ep" ]]    || die "Número do episódio não pode ser vazio."
    [[ -n "$ref_src" ]]   || die "Source não pode ser vazio."

    # Melhoria 7: Validação do formato padrão de numeração do episódio
    if [[ ! "$ref_ep" =~ ^[0-9]{2,4}(v[0-9])?$ ]]; then
        warn "Episódio '$ref_ep' fora do padrão numérico esperado (ex: 01, 002, 03v2)."
    fi
}

# ─── Principal ────────────────────────────────────────────────────────────────
main() {
    header

    [[ $# -eq 1 ]] || die "Uso: $SCRIPT_NAME /caminho/da/pasta"

    local pasta="$1"
    [[ -d "$pasta" ]] || die "Pasta não encontrada: $pasta"

    # Melhoria 6: Inicialização explícita das variáveis locais da main
    local ANIME="" EPISODIO="" SOURCE=""

    step "Verificando dependências..."
    check_deps
    success "Dependências OK"

    sep

    # Localiza arquivos — exige exatamente 1 de cada
    local -a mkv_files ass_files txt_files
    mapfile -t mkv_files < <(find "$pasta" -maxdepth 1 -type f -name "*.mkv" | sort)
    mapfile -t ass_files < <(find "$pasta" -maxdepth 1 -type f -name "*.ass" | sort)
    mapfile -t txt_files < <(find "$pasta" -maxdepth 1 -type f -name "*.txt" | sort)

    [[ ${#mkv_files[@]} -eq 1 ]] || die "Esperado 1 arquivo .mkv, encontrado ${#mkv_files[@]} em: $pasta"
    [[ ${#ass_files[@]} -eq 1 ]] || die "Esperado 1 arquivo .ass, encontrado ${#ass_files[@]} em: $pasta"
    [[ ${#txt_files[@]} -eq 1 ]] || die "Esperado 1 arquivo .txt, encontrado ${#txt_files[@]} em: $pasta"

    local mkv_original="${mkv_files[0]}"
    local legenda="${ass_files[0]}"
    local capitulos="${txt_files[0]}"

    info "Arquivos detectados"
    detail "🎞  $(basename "$mkv_original")"
    detail "💬  $(basename "$legenda")"
    detail "📖  $(basename "$capitulos")"

    # Passa as referências das variáveis locais para o prompt
    prompt_user ANIME EPISODIO SOURCE

    local tempo_inicial=$SECONDS

    # ── Detecta codecs e resolução (1 chamada mkvmerge -J) ──
    step "Analisando faixas de mídia..."
    detect_tracks "$mkv_original"

    local video_codec audio_codec qualidade
    video_codec=$(parse_video_codec)
    audio_codec=$(parse_audio_codec)
    qualidade=$(parse_resolution)

    success "Análise concluída"
    detail "🎥  Vídeo    : ${C_BOLD}${video_codec}${C_RESET}"
    detail "🔊  Áudio    : ${C_BOLD}${audio_codec}${C_RESET}"
    detail "📐  Resolução: ${C_BOLD}${qualidade}${C_RESET}"
    echo

    # ── Monta nomes ──
    local nome_base mkv_temp mkv_final thumb
    nome_base="[$TAG] ${ANIME} - ${EPISODIO} [${qualidade}][${SOURCE}][${video_codec}][${audio_codec}]"
    mkv_temp="${pasta}/${nome_base}_TEMP.mkv"

    # Limpeza de arquivo temporário em qualquer saída
    trap '[[ -n "${mkv_temp:-}" && -f "${mkv_temp:-}" ]] && rm -f "$mkv_temp"' EXIT

    rm -f "$mkv_temp"

    # ── Muxing ──
    spinner "Multiplexando faixas..." \
        mkvmerge \
            --priority lower \
            --output "$mkv_temp" \
            --no-subtitles \
            --language 1:ja-JP \
            --track-name '1:Japonês' \
            --original-flag 1:yes \
            '(' "$mkv_original" ')' \
            --language 0:pt-BR \
            --track-name '0:Português do Brasil' \
            '(' "$legenda" ')' \
            --chapters "$capitulos" \
            --generate-chapters-name-template 'Capítulo <NUM:2>' \
            --track-order 0:0,0:1,1:0

    # ── CRC-32 ──
    step "Calculando CRC-32..."
    local hash
    hash=$(calc_crc32 "$mkv_temp")
    success "CRC-32: ${C_BOLD}${hash}${C_RESET}"

    mkv_final="${pasta}/${nome_base}[${hash}].mkv"
    mv -- "$mkv_temp" "$mkv_final"
    mkv_temp=""  # limpa var pra trap não tentar deletar arquivo já renomeado

    # ── Thumbnail ──
    thumb="${pasta}/${nome_base}[${hash}].webp"
    # Melhoria 5: -ss reposicionado após -i e ajuste no filtro de amostragem para evitar telas pretas
    spinner "Gerando thumbnail (ts=${THUMB_TS})..." \
        ffmpeg -loglevel error -i "$mkv_final" -ss "$THUMB_TS" \
            -vf "thumbnail=n=50,setsar=1" -vframes 1 "$thumb" -y

    # ── Resumo final ──
    local duracao
    duracao=$(( SECONDS - tempo_inicial ))
    echo
    echo -e "${C_GREEN}${C_BOLD}  ╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}  ║   ✅  Episódio gerado com sucesso!           ║${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}  ╚══════════════════════════════════════════════╝${C_RESET}"
    echo
    detail "🎬  $(basename "$mkv_final")"
    detail "🌅  $(basename "$thumb")"
    detail "🕐  Tempo: $(( duracao / 60 ))m $(( duracao % 60 ))s"
    echo
}

main "$@"
