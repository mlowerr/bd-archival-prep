#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UNIX_SCRIPT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

apply_args=(
  --recommendations .archival-prep/blu-ray-file-recommendations.txt
  --destination .
)

while (( $# > 0 )); do
  case "$1" in
    --disk-size)
      (( $# >= 2 )) || { echo "Error: --disk-size requires a value." >&2; exit 2; }
      apply_args+=(--disk-size "$2")
      shift 2
      ;;
    --base-name)
      (( $# >= 2 )) || { echo "Error: --base-name requires a value." >&2; exit 2; }
      apply_args+=(--base-name "$2")
      shift 2
      ;;
    --include-disk-number|--disk-number-with-total)
      apply_args+=("$1")
      shift
      ;;
    --help|-h)
      echo "Usage: $(basename "$0") [--disk-size PLAN] [--base-name NAME] [--include-disk-number | --disk-number-with-total]"
      exit 0
      ;;
    *)
      echo "Error: Unknown option: $1" >&2
      echo "Usage: $(basename "$0") [--disk-size PLAN] [--base-name NAME] [--include-disk-number | --disk-number-with-total]" >&2
      exit 2
      ;;
  esac
done

"${UNIX_SCRIPT_DIR}/file-size-recommendations.sh"

python3 "${UNIX_SCRIPT_DIR}/apply-disk-plan.py" "${apply_args[@]}"
