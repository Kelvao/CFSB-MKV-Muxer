#!/usr/bin/env bash

set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────

readonly SCRIPT_NAME="$(basename "$0")"
readonly TAG="CFSB"

# ─── Colors & Styles ──────────────────────────────────────────────────────────

if [[ -t 1 ]]; then

readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_DIM='\033[2m'
readonly C_CYAN='\033[36m'
readonly C_GREEN='\033[32m'
readonly C_YELLOW='\033[33m'
readonly C_RED='\033[31m'
readonly C_MAGENTA='\033[35m'
readonly C_BLUE='\033[34m'

else

readonly C_RESET='' C_BOLD='' C_DIM='' C_CYAN='' C_GREEN=''
readonly C_YELLOW='' C_RED='' C_MAGENTA='' C_BLUE=''

fi

# ─── UI ───────────────────────────────────────────────────────────────────────

die() {
  echo -e "${C_RED}${C_BOLD} ✖ $*${C_RESET}" >&2
  exit 1
}

info()    { echo -e "${C_CYAN} ℹ ${C_RESET}${C_BOLD}$*${C_RESET}"; }
success() { echo -e "${C_GREEN} ✔ ${C_RESET}${C_BOLD}$*${C_RESET}"; }
warn()    { echo -e "${C_YELLOW} ⚠ ${C_RESET}$*"; }
step()    { echo -e "${C_MAGENTA} ▶ ${C_RESET}${C_BOLD}$*${C_RESET}"; }
detail()  { echo -e "${C_DIM} $*${C_RESET}"; }

sep() {
  echo -e "${C_DIM} ────────────────────────────────────────────────${C_RESET}"
}

header() {
  echo
  echo -e "${C_BLUE}${C_BOLD} ╔══════════════════════════════════════════════╗${C_RESET}"
  echo -e "${C_BLUE}${C_BOLD} ║ 🎌 Crystal FanSub MKV Muxer ║${C_RESET}"
  echo -e "${C_BLUE}${C_BOLD} ╚══════════════════════════════════════════════╝${C_RESET}"
  echo
}

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
    echo -ne "\r${C_CYAN} ${frames[$i]} ${C_RESET}${C_BOLD}${label}${C_RESET} "
    i=$(( (i + 1) % ${#frames[@]} ))
    sleep 0.08
  done || true

  set +e
  wait "$pid"
  local exit_code=$?
  set -e

  tput cnorm 2>/dev/null || true
  echo -ne "\r"

  if [[ $exit_code -eq 0 ]]; then
    echo -e "${C_GREEN} ✔ ${C_RESET}${C_BOLD}${label}${C_RESET}"
  else
    echo -e "${C_RED} ✖ ${C_RESET}${C_BOLD}${label} falhou${C_RESET}"
    cat "$tmp_err" >&2
    rm -f "$tmp_out" "$tmp_err"
    exit "$exit_code"
  fi

  _SPINNER_OUT=$(cat "$tmp_out")
  rm -f "$tmp_out" "$tmp_err"
}

# ─── Dependency check ─────────────────────────────────────────────────────────

check_deps() {
  local missing=()

  for cmd in mkvmerge mkvinfo ffmpeg jq; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done

  if ! command -v crc32 &>/dev/null && ! command -v perl &>/dev/null; then
    missing+=("crc32 ou perl")
  fi

  (( ${#missing[@]} == 0 )) || die "Dependências faltando: ${missing[*]}"
}

# ─── Track detection ──────────────────────────────────────────────────────────

detect_codecs_and_resolution() {
  local file="$1"
  local identify_out json_out

  identify_out=$(mkvmerge --identify "$file")
  json_out=$(mkvmerge -J "$file")

  local video_info audio_info
  video_info=$(echo "$identify_out" | grep -i "video" || true)
  audio_info=$(echo "$identify_out" | grep -i "audio" | head -n 1 || true)

  if [[ "$video_info" == *"HEVC"* || "$video_info" == *"H.265"* ]]; then _DETECT_VIDEO="HEVC"
  elif [[ "$video_info" == *"AVC"* || "$video_info" == *"H.264"* ]]; then _DETECT_VIDEO="AVC"
  elif [[ "$video_info" == *"AV1"* ]]; then _DETECT_VIDEO="AV1"
  else _DETECT_VIDEO="HEVC"
  fi

  if [[ "$audio_info" == *"AAC"* ]]; then _DETECT_AUDIO="AAC"
  elif [[ "$audio_info" == *"FLAC"* ]]; then _DETECT_AUDIO="FLAC"
  elif [[ "$audio_info" == *"Opus"* ]]; then _DETECT_AUDIO="Opus"
  else _DETECT_AUDIO="AAC"
  fi

  local dims height
  dims=$(echo "$json_out" | jq -r '[.tracks[] | select(.type=="video")] | first | .properties.display_dimensions // .properties.pixel_dimensions // empty' 2>/dev/null || true)
  height=$(echo "$dims" | cut -dx -f2)

  _DETECT_RES="${height:-1080}p"
}

detect_track_ids() {
  local file="$1"
  local json_out

  json_out=$(mkvmerge -J "$file")

  _TRACK_VIDEO=$(echo "$json_out" | jq -r '[.tracks[] | select(.type=="video")] | first | .id // 0')
  _TRACK_AUDIO=$(echo "$json_out" | jq -r '[.tracks[] | select(.type=="audio")] | first | .id // 1')
}

# ─── CRC-32 ───────────────────────────────────────────────────────────────────

calc_crc32() {
  local file="$1"
  local hash

  if command -v crc32 &>/dev/null; then
    hash=$(crc32 "$file")
  else
    hash=$(perl -e '
      open(F, "<", $ARGV[0]) or die;
      binmode F; local $/; my $data = <F>;
      my $crc = 0xFFFFFFFF;
      for my $byte (unpack("C*", $data)) {
        $crc ^= $byte;
        for (1..8) { $crc = ($crc & 1) ? (($crc >> 1) ^ 0xEDB88320) : ($crc >> 1); }
      }
      printf "%08X\n", $crc ^ 0xFFFFFFFF;
    ' "$file")
  fi

  echo "${hash^^}"
}

# ─── User input ───────────────────────────────────────────────────────────────

prompt_user() {
  echo
  echo -e "${C_BOLD} 📝 Informações do episódio${C_RESET}"
  sep

  echo -ne " ${C_CYAN}🎬${C_RESET} Nome do Anime       : "; read -r ANIME
  echo -ne " ${C_CYAN}📺${C_RESET} Número do Episódio  : "; read -r EPISODE
  echo -ne " ${C_CYAN}💿${C_RESET} Source              : "; read -r SOURCE

  sep
  echo

  [[ -n "$ANIME" ]]   || die "Nome do anime não pode ser vazio."
  [[ "$EPISODE" =~ ^[0-9]{1,4}[a-zA-Z]?$ ]] || die "Número do episódio inválido: $EPISODE"
  [[ -n "$SOURCE" ]]  || die "Source não pode ser vazio."
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  header
  trap 'tput cnorm 2>/dev/null || true' EXIT

  [[ $# -eq 1 ]] || die "Uso: $SCRIPT_NAME /caminho/da/pasta"

  local dir="$1"
  [[ -d "$dir" ]] || die "Pasta não encontrada: $dir"

  step "Verificando dependências..."
  check_deps
  success "Dependências OK"
  sep

  local source_mkv subtitle chapters
  local -a mkv_files

  mapfile -d '' -t mkv_files < <(find "$dir" -maxdepth 1 -type f -name "*.mkv" -print0 | sort -z)

  (( ${#mkv_files[@]} == 1 )) || die "Esperado 1 arquivo .mkv, encontrado ${#mkv_files[@]} em: $dir"

  source_mkv="${mkv_files[0]}"
  subtitle=$(find "$dir" -maxdepth 1 -type f -name "*.ass" -print0 | sort -z | tr '\0' '\n' | head -n 1)
  chapters=$(find "$dir" -maxdepth 1 -type f -name "*.txt" -print0 | sort -z | tr '\0' '\n' | head -n 1)

  [[ -n "$subtitle" ]]  || die "Nenhum arquivo .ass encontrado em: $dir"
  [[ -n "$chapters" ]]  || die "Nenhum arquivo .txt encontrado em: $dir"

  info "Arquivo de origem detectado"
  detail "🎞 $(basename "$source_mkv")"
  detail "💬 $(basename "$subtitle")"
  detail "📖 $(basename "$chapters")"

  prompt_user

  local start_time=$SECONDS

  step "Analisando faixas de mídia..."
  detect_codecs_and_resolution "$source_mkv"
  detect_track_ids "$source_mkv"

  local video_codec="$_DETECT_VIDEO"
  local audio_codec="$_DETECT_AUDIO"
  local resolution="$_DETECT_RES"
  local track_video="$_TRACK_VIDEO"
  local track_audio="$_TRACK_AUDIO"

  success "Análise concluída"
  detail "🎥 Vídeo     : ${C_BOLD}${video_codec}${C_RESET}"
  detail "🔊 Áudio     : ${C_BOLD}${audio_codec}${C_RESET}"
  detail "📐 Resolução : ${C_BOLD}${resolution}${C_RESET}"
  echo

  local base_name output_temp output_final
  base_name="[$TAG] ${ANIME} - ${EPISODE} [${resolution}][${SOURCE}][${video_codec}][${audio_codec}]"
  output_temp="${dir}/${base_name}_TEMP.mkv"

  rm -f "$output_temp"
  trap 'tput cnorm 2>/dev/null || true; rm -f "$output_temp"' EXIT ERR

  spinner "Multiplexando faixas..." \
    mkvmerge \
      --ui-language pt_BR \
      --priority lower \
      --output "$output_temp" \
      --no-subtitles \
      --language "${track_video}:ja-JP" \
      --track-name "${track_video}:Japonês" \
      --original-flag "${track_video}:yes" \
      '(' "$source_mkv" ')' \
      --language 0:pt-BR \
      --track-name '0:Português do Brasil' \
      '(' "$subtitle" ')' \
      --chapters "$chapters" \
      --generate-chapters-name-template 'Capítulo <NUM:2>' \
      --track-order "0:${track_video},0:${track_audio},1:0"

  step "Calculando CRC-32..."
  local hash
  hash=$(calc_crc32 "$output_temp")
  success "CRC-32: $hash"

  output_final="${dir}/${base_name}[${hash}].mkv"
  mv -- "$output_temp" "$output_final"

  trap 'tput cnorm 2>/dev/null || true' EXIT

  local thumbnail="${dir}/${base_name}[${hash}].webp"

  spinner "Gerando thumbnail..." \
    ffmpeg -ss 00:02:30 -i "$output_final" -vf "thumbnail=10,setsar=1" -vframes 1 "$thumbnail" -y

  local elapsed
  elapsed=$(( SECONDS - start_time ))

  echo
  echo -e "${C_GREEN}${C_BOLD} ╔══════════════════════════════════════════════╗${C_RESET}"
  echo -e "${C_GREEN}${C_BOLD} ║ ✅ Episódio gerado com sucesso! ║${C_RESET}"
  echo -e "${C_GREEN}${C_BOLD} ╚══════════════════════════════════════════════╝${C_RESET}"
  echo
  detail "🎬 $(basename "$output_final")"
  detail "🌅 $(basename "$thumbnail")"
  detail "🕐 Tempo: $(( elapsed / 60 ))m $(( elapsed % 60 ))s"
  echo
}

main "$@"
