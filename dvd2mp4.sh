#!/usr/bin/env bash
# dvd2mp4.sh — Transcode every DVD VIDEO_TS title to MP4 (H.264 + MP3) with subtitle sidecars.
#
# USAGE
#   ./dvd2mp4.sh /path/to/VIDEO_TS                       # output -> ./output/
#   ./dvd2mp4.sh /path/to/DVD_ROOT -o ./mp4s             # auto-detects VIDEO_TS subdir
#   ./dvd2mp4.sh /path/to/VIDEO_TS -q 20 -b 224k         # custom CRF + audio bitrate
#   ./dvd2mp4.sh /path/to/VIDEO_TS --dry-run             # show commands without running
#   ./dvd2mp4.sh /path/to/VIDEO_TS --titles 01,02,05     # only specific VTS sets
#   ./dvd2mp4.sh /path/to/VIDEO_TS --min-len 300         # only titles >= 5 minutes
#
# WHAT IT DOES (per VTS_xx title set found in VIDEO_TS):
#   1. Concatenates VTS_xx_1.VOB .. VTS_xx_9.VOB via ffmpeg's concat: protocol.
#   2. Transcodes video (libx264, CRF 22 default, yuv420p, +faststart) and ALL audio tracks (libmp3lame 192k default). Output: title_NN.mp4.
#   3. Extracts every subtitle stream:
#        - If mkvextract + vobsub2srt are installed: OCR to SRT, then embed as a mov_text track inside title_NN.mp4 (toggleable soft subs).
#        - Otherwise: dump each stream as title_NN.sub.MM.mkv (VOBSUB preserved inside a tiny Matroska sidecar) so you can OCR later with whatever tool you like (vobsub2srt, ccextractor, bdsup2sub++, etc.).
#
# REQUIREMENTS
#   Required:  ffmpeg (built with libx264 + libmp3lame); ffprobe (usually shipped with ffmpeg)
#   Optional:  lsdvd        for accurate title lengths (skipped automatically if missing)
#              mkvextract   for needed for the OCR path (from mkvtoolnix)
#              vobsub2srt   for needed for the OCR path (wraps tesseract)
#
# NOTES
#   - "All titles" means every VTS_xx_*.VOB set the DVD has. The longest one is almost always the main feature; the rest are extras/trailers. The script prints durations so you can spot which is which.
#   - VOBSUB (DVD bitmap subtitles) cannot live inside an MP4 container. ffmpeg alone cannot OCR them. That's why the no-OCR fallback produces .mkv sidecars instead of stuffing them into the .mp4.
#   - The script is idempotent per title: re-running skips titles whose .mp4 already exists and is non-empty. Delete the .mp4 to re-transcode.

set -euo pipefail

# - defaults -
CRF=22
AUDIO_BITRATE=192k
PRESET=slow
OUT_DIR="./output"
DRY_RUN=0
VIDEO_TS_DIR=""
ONLY_TITLES=""
MIN_LEN_SECONDS=0

# - helpers -
yesno() { [[ "$1" -eq 1 ]] && echo "yes" || echo "no"; }

usage() {
  awk 'NR==1 { next }          # skip shebang
       /^#/ { sub(/^# ?/, ""); print; next }
       { exit }' "$0" >&2
}

die() { echo "ERROR: $*" >&2; exit 1; }

# - arg parsing -
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -o) OUT_DIR="$2"; shift 2 ;;
    -q) CRF="$2"; shift 2 ;;
    -b) AUDIO_BITRATE="$2"; shift 2 ;;
    -p) PRESET="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --titles) ONLY_TITLES="$2"; shift 2 ;;
    --min-len) MIN_LEN_SECONDS="$2"; shift 2 ;;
    --) shift; [[ $# -gt 0 ]] && VIDEO_TS_DIR="$1"; shift ;;
    *) VIDEO_TS_DIR="$1"; shift ;;
  esac
done

# - locate VIDEO_TS -
[[ -n "$VIDEO_TS_DIR" ]] || { usage; die "VIDEO_TS path required."; }
[[ -d "$VIDEO_TS_DIR" ]] || die "directory not found: $VIDEO_TS_DIR"
if [[ -d "$VIDEO_TS_DIR/VIDEO_TS" ]]; then
  VIDEO_TS_DIR="$VIDEO_TS_DIR/VIDEO_TS"
fi
[[ -f "$VIDEO_TS_DIR/VIDEO_TS.IFO" || -n "$(ls "$VIDEO_TS_DIR"/VTS_*_1.VOB 2>/dev/null)" ]] \
  || die "no VTS_*.VOB files found in $VIDEO_TS_DIR — is this really a VIDEO_TS folder?"

mkdir -p "$OUT_DIR"

# - tool detection -
have() { command -v "$1" >/dev/null 2>&1; }

have ffmpeg  || die "ffmpeg not found in PATH."
have ffprobe || die "ffprobe not found (usually ships with ffmpeg)."

HAVE_LSDVD=0;       have lsdvd       && HAVE_LSDVD=1
HAVE_MKVEXTRACT=0;  have mkvextract  && HAVE_MKVEXTRACT=1
HAVE_VOBSUB2SRT=0;  have vobsub2srt  && HAVE_VOBSUB2SRT=1
OCR_AVAILABLE=0
(( HAVE_MKVEXTRACT && HAVE_VOBSUB2SRT )) && OCR_AVAILABLE=1

echo "=== dvd2mp4.sh ==="
echo "Source : $VIDEO_TS_DIR"
echo "Output : $OUT_DIR"
echo "Quality: H.264 CRF $CRF, preset $PRESET | MP3 $AUDIO_BITRATE | all audio tracks"
echo "Tools  : ffmpeg=$(yesno 1) lsdvd=$(yesno $HAVE_LSDVD) mkvextract=$(yesno $HAVE_MKVEXTRACT) vobsub2srt=$(yesno $HAVE_VOBSUB2SRT)"
if (( OCR_AVAILABLE )); then
  echo "Subs   : OCR -> mov_text (embedded in MP4)"
else
  echo "Subs   : VOBSUB sidecars (.sub.MM.mkv) — install mkvextract + vobsub2srt for in-mp4 OCR"
fi
(( DRY_RUN )) && echo "Mode   : DRY RUN (no files written)"
echo

# - enumerate titles (VTS_xx sets) -
# Each VTS_xx_*_1.VOB marks the start of one title set. VTS_NN_0.VOB is the
# menu VOB and is intentionally skipped.
mapfile -t ALL_VTS < <(
  ls "$VIDEO_TS_DIR"/VTS_*_1.VOB 2>/dev/null \
    | sed -E 's/.*VTS_([0-9]+)_1\.VOB/\1/' \
    | sort -n -u
)
[[ ${#ALL_VTS[@]} -gt 0 ]] || die "no VTS_*_1.VOB files found."

# Optional title filter (--titles 01,02,05)
filter_titles() {
  if [[ -z "$ONLY_TITLES" ]]; then
    printf '%s\n' "${ALL_VTS[@]}"
    return
  fi
  local want
  IFS=',' read -ra want <<< "$ONLY_TITLES"
  local w t ok
  for t in "${ALL_VTS[@]}"; do
    ok=0
    for w in "${want[@]}"; do
      w="$(printf '%02d' "$((10#$w))")"
      [[ "$w" == "$t" ]] && ok=1 && break
    done
    (( ok )) && printf '%s\n' "$t"
  done
}
mapfile -t TITLES < <(filter_titles)
[[ ${#TITLES[@]} -gt 0 ]] || die "title filter matched nothing."

echo "Found ${#TITLES[@]} title set(s): ${TITLES[*]}"
echo

# - helpers -
# Build ffmpeg concat: URL for a VTS number (e.g. "01" -> "concat:.../VTS_01_1.VOB|.../VTS_01_2.VOB|...")
vob_concat_url() {
  local vts="$1" n f
  local parts=()
  for n in 1 2 3 4 5 6 7 8 9; do
    f="$VIDEO_TS_DIR/VTS_${vts}_${n}.VOB"
    [[ -f "$f" ]] && parts+=("$f")
  done
  [[ ${#parts[@]} -gt 0 ]] || return 1
  local IFS='|'
  printf 'concat:%s' "${parts[*]}"
}

# Probe duration in seconds (integer) of a concat: URL
probe_duration_seconds() {
  local url="$1"
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$url" 2>/dev/null \
    | awk '{printf "%d", $1+0}'
}

# Count subtitle streams in a concat: URL
count_sub_streams() {
  local url="$1"
  ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$url" 2>/dev/null \
    | wc -l | awk '{print $1+0}'
}

# OCR a VOBSUB .mkv sidecar to .srt and embed in the .mp4 as mov_text.
# Args: <mkv_sidecar> <out_srt> <mp4_to_augment>
ocr_and_embed() {
  local sidecar="$1" srt="$2" mp4="$3" base tmp_mp4
  base="${sidecar%.mkv}"
  # mkvextract writes <base>.sub and <base>.idx
  mkvextract tracks "$sidecar" 0:"${base}.sub" >/dev/null 2>&1 || return 1
  vobsub2srt "${base%.*}" >/dev/null 2>&1 || return 1   # writes <basename>.srt
  [[ -f "$srt" ]] || return 1
  tmp_mp4="${mp4%.mp4}.tmp.mp4"
  ffmpeg -y -i "$mp4" -i "$srt" \
    -map 0 -map 1 \
    -c copy -c:s mov_text \
    -metadata:s:s:0 language=eng \
    "$tmp_mp4" >/dev/null 2>&1 || return 1
  mv "$tmp_mp4" "$mp4"
}

# - main loop -
process_title() {
  local vts="$1" url out_prefix out_mp4 dur sub_count i sub_mkv sub_srt
  url="$(vob_concat_url "$vts")" || { echo "  [skip] no VOBs"; return 0; }
  out_prefix="$OUT_DIR/title_${vts}"
  out_mp4="${out_prefix}.mp4"

  dur="$(probe_duration_seconds "$url")"
  printf '== VTS_%s  duration=%s  -> %s\n' "$vts" "$(printf '%dh%02dm%02ds' $((dur/3600)) $(((dur%3600)/60)) $((dur%60)))" "$out_mp4"

  if (( MIN_LEN_SECONDS > 0 && dur < MIN_LEN_SECONDS )); then
    echo "   [skip] shorter than --min-len ${MIN_LEN_SECONDS}s"
    return 0
  fi

  if [[ -s "$out_mp4" ]]; then
    echo "   [exists] $out_mp4 already present — delete it to re-transcode"
  else
    echo "   [video] transcoding H.264 CRF $CRF + MP3 $AUDIO_BITRATE (all audio tracks)"
    if (( ! DRY_RUN )); then
      ffmpeg -hide_banner -loglevel error -y \
        -i "$url" \
        -map 0:v:0 -map 0:a? \
        -c:v libx264 -crf "$CRF" -preset "$PRESET" -pix_fmt yuv420p \
        -c:a libmp3lame -b:a "$AUDIO_BITRATE" \
        -movflags +faststart \
        "$out_mp4"
    fi
  fi

  # - subtitles -
  sub_count="$(count_sub_streams "$url")"
  if (( sub_count == 0 )); then
    echo "   [subs ] none"
    return 0
  fi
  echo "   [subs ] $sub_count stream(s)"

  for (( i=0; i<sub_count; i++ )); do
    sub_mkv="${out_prefix}.sub.$(printf '%02d' "$i").mkv"
    sub_srt="${out_prefix}.sub.$(printf '%02d' "$i").srt"

    if (( OCR_AVAILABLE )); then
      echo "       sub $i: extract -> OCR -> embed mov_text"
      if (( ! DRY_RUN )); then
        ffmpeg -hide_banner -loglevel error -y \
          -i "$url" -map "0:s:$i" -c:s copy -f matroska "$sub_mkv"
        if ocr_and_embed "$sub_mkv" "$sub_srt" "$out_mp4"; then
          rm -f "$sub_mkv" "${sub_mkv%.mkv}.sub" "${sub_mkv%.mkv}.idx"
        else
          echo "       [warn] OCR failed for sub $i — keeping sidecar $sub_mkv"
        fi
      fi
    else
      echo "       sub $i: -> $sub_mkv (VOBSUB sidecar, OCR later)"
      if (( ! DRY_RUN )); then
        ffmpeg -hide_banner -loglevel error -y \
          -i "$url" -map "0:s:$i" -c:s copy -f matroska "$sub_mkv" \
          || echo "       [warn] extract failed for sub $i"
      fi
    fi
  done
}

for vts in "${TITLES[@]}"; do
  process_title "$vts" || echo "   [warn] title $vts had errors, continuing"
  echo
done

echo "=== done ==="
echo "Output directory: $OUT_DIR"
if (( ! OCR_AVAILABLE )); then
  echo
  echo "Tip: to OCR the .sub.MM.mkv sidecars later:"
  echo "  mkvextract tracks title_XX.sub.MM.mkv 0:track.sub   # produces .sub + .idx"
  echo "  vobsub2srt track                                  # produces .srt"
  echo "  ffmpeg -i title_XX.mp4 -i track.srt -map 0 -map 1 -c copy -c:s mov_text out.mp4"
fi
