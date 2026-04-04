#!/usr/bin/env bash
set -euo pipefail

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Error: ffprobe is required but was not found in PATH." >&2
  echo "Install FFmpeg (which includes ffprobe), then re-run this script." >&2
  exit 1
fi

start_dir="${PWD}"
out_dir="$start_dir/.archival-prep"

usage() {
  cat <<'USAGE'
Usage: report-file-durations.sh [--target-dir DIR] [--output-dir DIR]

Options:
  --target-dir DIR   Directory to scan (default: current working directory)
  --output-dir DIR   Directory where reports are written (default: TARGET/.archival-prep)
  --log-dir DIR      Alias for --output-dir
  -h, --help         Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-dir)
      start_dir="$2"
      shift 2
      ;;
    --output-dir|--log-dir)
      out_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

start_dir="$(cd -- "$start_dir" && pwd)"
mkdir -p "$out_dir"
out_dir="$(cd -- "$out_dir" && pwd)"

file_durations="$out_dir/file-durations.txt"
duplicates="$out_dir/possible-duplicates-by-duration.txt"

script_name="$(basename "$0")"
report_date_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

tmp_tsv="$(mktemp)"
trap 'rm -f "$tmp_tsv"' EXIT

get_ffprobe_duration_raw() {
  local file_path="$1"
  ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file_path" 2>/dev/null
}

is_video_file() {
  local file_path="$1"
  local codec_type
  codec_type="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of default=noprint_wrappers=1:nokey=1 "$file_path" 2>/dev/null | tr -d '[:space:]')"
  [[ "$codec_type" == "video" ]]
}

while IFS= read -r -d '' abs_path; do
  if [[ "$abs_path" == "$out_dir/"* ]]; then
    continue
  fi

  if ! is_video_file "$abs_path"; then
    continue
  fi

  if ! raw_duration="$(get_ffprobe_duration_raw "$abs_path")"; then
    continue
  fi

  raw_duration="$(printf '%s' "$raw_duration" | tr -d '[:space:]')"
  if [[ -z "$raw_duration" || "$raw_duration" == "N/A" ]]; then
    continue
  fi
  if [[ ! "$raw_duration" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    continue
  fi

  normalized="$(awk -v d="$raw_duration" 'BEGIN { if (d ~ /^[0-9]+([.][0-9]+)?$/) printf "%d", int(d + 0.5) }' 2>/dev/null || true)"
  if [[ -z "$normalized" ]]; then
    continue
  fi

  printf '%s\t%s\n' "$abs_path" "$normalized" >> "$tmp_tsv"
done < <(find "$start_dir" -type f -print0 | sort -z)

{
  printf '# Script: %s\n' "$script_name"
  printf '# Report date (UTC): %s\n' "$report_date_utc"
  printf '# Reporting on: %s\n' "$start_dir"
  printf '# Subject: video file durations from ffprobe (seconds)\n\n'

  sort -t $'\t' -k1,1 "$tmp_tsv" | awk -F $'\t' '{ printf "%s | %s\n", $1, $2 }'
} > "$file_durations"

{
  printf '# Script: %s\n' "$script_name"
  printf '# Report date (UTC): %s\n' "$report_date_utc"
  printf '# Reporting on: %s\n' "$start_dir"
  printf '# Subject: possible duplicates grouped by identical normalized duration\n\n'

  sort -t $'\t' -k2,2n -k1,1 "$tmp_tsv" | awk -F $'\t' '
function flush_group() {
  if (group_count >= 2) {
    group_index++
    printf "POSSIBLE DUPLICATE [%d] - Duration: %s\n", group_index, current_duration
    for (i=1; i<=group_count; i++) {
      print group_paths[i]
    }
    print ""
  }
}
BEGIN {
  current_duration = ""
  group_count = 0
  group_index = 0
}
{
  path = $1
  duration = $2

  if (current_duration == "") {
    current_duration = duration
  }

  if (duration != current_duration) {
    flush_group()
    delete group_paths
    group_count = 0
    current_duration = duration
  }

  group_count++
  group_paths[group_count] = path
}
END {
  flush_group()
}
'
} > "$duplicates"

echo "Wrote: $file_durations"
echo "Wrote: $duplicates"
