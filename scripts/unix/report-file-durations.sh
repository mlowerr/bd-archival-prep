#!/usr/bin/env bash
set -euo pipefail

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Error: ffprobe is required but was not found in PATH." >&2
  echo "Install FFmpeg (which includes ffprobe), then re-run this script." >&2
  exit 1
fi

start_dir="${PWD}"
out_dir=""
out_dir_set=false

usage() {
  cat <<'USAGE'
Usage: report-file-durations.sh [--target-dir DIR] [--output-dir DIR] [--jobs N]

Options:
  --target-dir DIR   Directory to scan (default: current working directory)
  --output-dir DIR   Directory where reports are written (default: TARGET/.archival-prep)
  --log-dir DIR      Alias for --output-dir
  --jobs N           Number of concurrent ffprobe workers (default: 3)
  -h, --help         Show this help
USAGE
}

jobs=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-dir)
      start_dir="$2"
      shift 2
      ;;
    --output-dir|--log-dir)
      out_dir="$2"
      out_dir_set=true
      shift 2
      ;;
    --jobs)
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

if ! [[ "$jobs" =~ ^[0-9]+$ ]] || [[ "$jobs" -lt 1 ]]; then
  echo "Error: --jobs must be an integer >= 1." >&2
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
tmp_na="$(mktemp)"
tmp_results_dir="$(mktemp -d)"
trap 'rm -f "$tmp_tsv" "$tmp_na"; rm -rf "$tmp_results_dir"' EXIT

get_ffprobe_duration_raw() {
  local file_path="$1"
  ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file_path" 2>/dev/null
}

worker_count=0
while IFS= read -r -d '' abs_path; do
  if [[ "$abs_path" == "$out_dir/"* ]]; then
    continue
  fi

  worker_count=$((worker_count + 1))
  worker_file="$tmp_results_dir/$worker_count"
  (
    raw_duration="$(get_ffprobe_duration_raw "$abs_path" || true)"
    raw_duration="$(printf '%s' "$raw_duration" | tr -d '[:space:]')"

    if [[ -n "$raw_duration" && "$raw_duration" != "N/A" && "$raw_duration" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      normalized="$(awk -v d="$raw_duration" 'BEGIN { if (d ~ /^[0-9]+([.][0-9]+)?$/) printf "%d", int(d + 0.5) }' 2>/dev/null || true)"
      if [[ -n "$normalized" ]]; then
        printf 'D\t%s\t%s\n' "$abs_path" "$normalized" > "$worker_file"
        exit 0
      fi
    fi

    printf 'N\t%s\n' "$abs_path" > "$worker_file"
  ) &

  while [[ "$(jobs -pr | wc -l | tr -d '[:space:]')" -ge "$jobs" ]]; do
    wait -n
  done
done < <(find "$start_dir" -type f -print0)

wait

for result_file in "$tmp_results_dir"/*; do
  [[ -e "$result_file" ]] || continue
  IFS=$'\t' read -r result_type result_path result_duration < "$result_file"
  if [[ "$result_type" == "D" ]]; then
    printf '%s\t%s\n' "$result_path" "$result_duration" >> "$tmp_tsv"
  else
    printf '%s\n' "$result_path" >> "$tmp_na"
  fi
done

{
  printf '# Script: %s\n' "$script_name"
  printf '# Report date (UTC): %s\n' "$report_date_utc"
  printf '# Reporting on: %s\n' "$start_dir"
  printf '# Subject: file durations from ffprobe (seconds)\n\n'

  sort -t $'\t' -k1,1 "$tmp_tsv" | awk -F $'\t' '{ printf "%s | %s\n", $1, $2 }'

  printf '\n=== FILES WITH NO READABLE DURATION ===\n'
  sort "$tmp_na"
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
