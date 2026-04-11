#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

INVOCATION_DIR="$(pwd)"
OUTPUT_DIR=""
OUTPUT_DIR_SET=false

usage() {
  cat <<'USAGE'
Usage: folder-size-recommendations.sh [--target-dir DIR] [--output-dir DIR]

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
      INVOCATION_DIR="$2"
      shift 2
      ;;
    --output-dir|--log-dir)
      OUTPUT_DIR="$2"
      OUTPUT_DIR_SET=true
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

bd_init_report_env "$0" "$INVOCATION_DIR" "$OUTPUT_DIR" "$OUTPUT_DIR_SET"

FOLDER_SIZES_FILE="${OUTPUT_DIR}/folder-sizes.txt"
RECOMMENDATIONS_FILE="${OUTPUT_DIR}/blu-ray-recommendations.txt"
CANDIDATES_FILE="${OUTPUT_DIR}/folder-sizes.tsv"
CANDIDATES_DATA_FILE="$(mktemp)"
trap 'rm -f "${CANDIDATES_DATA_FILE}"' EXIT

folder_size_bytes() {
  local dir="$1"
  local size_output=""
  local size_bytes=""

  if bd_is_path_within "$dir" "$OUTPUT_DIR"; then
    size_output="$(find "$dir" -path "$OUTPUT_DIR" -prune -o -type f -printf '%s\n' | awk '{total += $1} END {print total + 0}' || true)"
    size_bytes="${size_output:-0}"
  else
    size_output="$(du -sb "$dir" || true)"
    size_bytes="$(awk 'NR==1 {print $1}' <<< "${size_output}")"
    size_bytes="${size_bytes:-0}"
  fi

  printf '%s\n' "$size_bytes"
}

while IFS= read -r -d '' dir; do
  resolved_dir="$(cd -- "$dir" && pwd)"
  if [[ "$resolved_dir" == "$OUTPUT_DIR" ]]; then
    continue
  fi

  size_bytes="$(folder_size_bytes "$dir")"
  printf '%s\t%s\n' "$dir" "$size_bytes" >> "${CANDIDATES_DATA_FILE}"
done < <(find "${INVOCATION_DIR}" -mindepth 1 -maxdepth 1 -type d -print0)

sort -t $'\t' -k2,2nr -k1,1 -o "${CANDIDATES_DATA_FILE}" "${CANDIDATES_DATA_FILE}"

bd_write_size_reports_from_datafile \
  "${CANDIDATES_DATA_FILE}" \
  "${CANDIDATES_FILE}" \
  "${FOLDER_SIZES_FILE}" \
  "${SCRIPT_NAME}" \
  "${REPORT_DATE_UTC}" \
  "${INVOCATION_DIR}" \
  "first-level folder size candidates in bytes (TSV: path<TAB>size_bytes)" \
  "first-level folder sizes in GiB (binary units)"

python3 "${SCRIPT_DIR}/lib/blu_ray_packing.py" \
  "${CANDIDATES_FILE}" \
  "${RECOMMENDATIONS_FILE}" \
  "${SCRIPT_NAME}" \
  "${REPORT_DATE_UTC}" \
  "${INVOCATION_DIR}" \
  "optimal Blu-ray folder packing recommendations (marketed GB labels with binary GiB capacities)"

echo "Wrote: ${FOLDER_SIZES_FILE}"
echo "Wrote: ${RECOMMENDATIONS_FILE}"
echo "Wrote: ${CANDIDATES_FILE}"
