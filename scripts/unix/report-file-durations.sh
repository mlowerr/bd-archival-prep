#!/usr/bin/env bash
set -euo pipefail

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Error: ffprobe is required but was not found in PATH." >&2
  echo "Install FFmpeg (which includes ffprobe), then re-run this script." >&2
  exit 1
fi

start_dir="$(pwd)"
out_dir="$start_dir/.archival-prep"
mkdir -p "$out_dir"

file_durations="$out_dir/file-durations.txt"
duplicates="$out_dir/possible-duplicates-by-duration.txt"

tmp_tsv="$(mktemp)"
trap 'rm -f "$tmp_tsv"' EXIT

while IFS= read -r rel_path; do
  abs_path="$start_dir/${rel_path#./}"
  raw_duration="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$abs_path" 2>/dev/null || true)"

  # Skip files with no usable duration (e.g., "N/A" for non-timed formats).
  raw_duration="$(printf '%s' "$raw_duration" | tr -d '[:space:]')"
  if [[ -z "$raw_duration" ]]; then
    continue
  fi
  if [[ ! "$raw_duration" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    continue
  fi

  normalized="$(awk -v d="$raw_duration" 'BEGIN { printf "%d", int(d + 0.5) }' 2>/dev/null || true)"
  if [[ -z "$normalized" ]]; then
    continue
  fi

  printf '%s\t%s\n' "$abs_path" "$normalized" >> "$tmp_tsv"
done < <(find . -type f | sort)

sort -t $'\t' -k1,1 "$tmp_tsv" | awk -F $'\t' '{ printf "%s | %s\n", $1, $2 }' > "$file_durations"

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
' > "$duplicates"

echo "Wrote: $file_durations"
echo "Wrote: $duplicates"
