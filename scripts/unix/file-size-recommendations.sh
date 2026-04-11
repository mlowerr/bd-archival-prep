#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

INVOCATION_DIR="$(pwd)"
OUTPUT_DIR=""
OUTPUT_DIR_SET=false

usage() {
  cat <<'USAGE'
Usage: file-size-recommendations.sh [--target-dir DIR] [--output-dir DIR]

Options:
  --target-dir DIR   Directory to scan recursively for files (default: current working directory)
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

FILE_SIZES_FILE="${OUTPUT_DIR}/file-sizes.txt"
RECOMMENDATIONS_FILE="${OUTPUT_DIR}/blu-ray-file-recommendations.txt"
CANDIDATES_FILE="${OUTPUT_DIR}/file-sizes.tsv"
CANDIDATES_DATA_FILE="$(mktemp)"
trap 'rm -f "${CANDIDATES_DATA_FILE}"' EXIT

if [[ "${OUTPUT_DIR}" == "${INVOCATION_DIR}"/* ]]; then
  find_args=("${INVOCATION_DIR}" -path "${OUTPUT_DIR}" -prune -o -type f -print0)
else
  find_args=("${INVOCATION_DIR}" -type f -print0)
fi

while IFS= read -r -d '' file; do
  size_bytes="$(stat -c '%s' "$file")"
  printf '%s\t%s\n' "$file" "$size_bytes" >> "${CANDIDATES_DATA_FILE}"
done < <(find "${find_args[@]}")

sort -t $'\t' -k2,2nr -k1,1 -o "${CANDIDATES_DATA_FILE}" "${CANDIDATES_DATA_FILE}"

bd_write_size_reports_from_datafile \
  "${CANDIDATES_DATA_FILE}" \
  "${CANDIDATES_FILE}" \
  "${FILE_SIZES_FILE}" \
  "${SCRIPT_NAME}" \
  "${REPORT_DATE_UTC}" \
  "${INVOCATION_DIR}" \
  "recursive file size candidates in bytes (TSV: path<TAB>size_bytes)" \
  "recursive file sizes in GiB (binary units)"

python3 "${SCRIPT_DIR}/lib/blu_ray_packing.py" \
  "${CANDIDATES_FILE}" \
  "${RECOMMENDATIONS_FILE}" \
  "${SCRIPT_NAME}" \
  "${REPORT_DATE_UTC}" \
  "${INVOCATION_DIR}" \
  "optimal Blu-ray file packing recommendations (marketed GB labels with binary GiB capacities)"

echo "Wrote: ${FILE_SIZES_FILE}"
echo "Wrote: ${RECOMMENDATIONS_FILE}"
echo "Wrote: ${CANDIDATES_FILE}"
