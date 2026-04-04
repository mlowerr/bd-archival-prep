#!/usr/bin/env bash
set -euo pipefail

start_dir="${PWD}"
out_dir=""
out_dir_set=false
jobs=3

usage() {
  cat <<'USAGE'
Usage: report-file-durations.sh [--target-dir DIR] [--output-dir DIR] [--jobs N]

Options:
  --target-dir DIR   Directory to scan (default: current working directory)
  --output-dir DIR   Directory where reports are written (default: TARGET/.archival-prep)
  --log-dir DIR      Alias for --output-dir
  --jobs N           Number of concurrent ffprobe workers (default: 3; use 1 for sequential)
  -h, --help         Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-dir)
      if [[ $# -lt 2 ]]; then
        echo "Error: --target-dir requires a value." >&2
        exit 2
      fi
      start_dir="$2"
      shift 2
      ;;
    --output-dir|--log-dir)
      if [[ $# -lt 2 ]]; then
        echo "Error: $1 requires a value." >&2
        exit 2
      fi
      out_dir="$2"
      out_dir_set=true
      shift 2
      ;;
    --jobs)
      if [[ $# -lt 2 ]]; then
        echo "Error: --jobs requires a value." >&2
        exit 2
      fi
      jobs="$2"
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

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Error: ffprobe is required but was not found in PATH." >&2
  echo "Install FFmpeg (which includes ffprobe), then re-run this script." >&2
  exit 1
fi

if [[ ! "$jobs" =~ ^[0-9]+$ ]] || (( jobs < 1 )); then
  echo "Error: --jobs must be a positive integer (received: $jobs)" >&2
  exit 2
fi

start_dir="$(cd -- "$start_dir" && pwd)"
if [[ "${out_dir_set}" == false ]]; then
  out_dir="${start_dir}/.archival-prep"
fi
mkdir -p "$out_dir"
out_dir="$(cd -- "$out_dir" && pwd)"

file_durations="$out_dir/file-durations.txt"
duplicates="$out_dir/possible-duplicates-by-duration.txt"

script_name="$(basename "$0")"
report_date_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

tmp_tsv="$(mktemp)"
trap 'rm -f "$tmp_tsv"' EXIT

collect_parallel() {
  find "$start_dir" -type f -print0 | sort -z | xargs -0 -n1 -P "$jobs" bash -c '
    file_path="$1"
    out_prefix="$2"

    if [[ "$file_path" == "$out_prefix"/* ]]; then
      exit 0
    fi

    codec_type="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of default=noprint_wrappers=1:nokey=1 "$file_path" 2>/dev/null | tr -d "[:space:]")"
    if [[ "$codec_type" != "video" ]]; then
      exit 0
    fi

    raw_duration="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file_path" 2>/dev/null || true)"
    raw_duration="$(printf "%s" "$raw_duration" | tr -d "[:space:]")"

    if [[ -z "$raw_duration" || "$raw_duration" == "N/A" ]]; then
      exit 0
    fi
    if [[ ! "$raw_duration" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      exit 0
    fi

    normalized="$(awk -v d="$raw_duration" "BEGIN { if (d ~ /^[0-9]+([.][0-9]+)?$/) printf \"%d\", int(d + 0.5) }" 2>/dev/null || true)"
    if [[ -z "$normalized" ]]; then
      exit 0
    fi

    printf "%s\t%s\n" "$file_path" "$normalized"
  ' _ '{}' "$out_dir"
}

collect_sequential() {
  while IFS= read -r -d '' abs_path; do
    if [[ "$abs_path" == "$out_dir/"* ]]; then
      continue
    fi

    codec_type="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of default=noprint_wrappers=1:nokey=1 "$abs_path" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$codec_type" != "video" ]]; then
      continue
    fi

    raw_duration="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$abs_path" 2>/dev/null || true)"
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

    printf '%s\t%s\n' "$abs_path" "$normalized"
  done < <(find "$start_dir" -type f -print0 | sort -z)
}

if (( jobs == 1 )); then
  collect_sequential > "$tmp_tsv"
else
  collect_parallel > "$tmp_tsv"
fi

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
