#!/usr/bin/env bash
set -euo pipefail

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

INVOCATION_DIR="$(cd -- "$INVOCATION_DIR" && pwd)"
if [[ "${OUTPUT_DIR_SET}" == false ]]; then
  OUTPUT_DIR="${INVOCATION_DIR}/.archival-prep"
fi
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"

FILE_SIZES_FILE="${OUTPUT_DIR}/file-sizes.txt"
RECOMMENDATIONS_FILE="${OUTPUT_DIR}/blu-ray-file-recommendations.txt"
CANDIDATES_FILE="${OUTPUT_DIR}/file-sizes.tsv"
CANDIDATES_DATA_FILE="$(mktemp)"
trap 'rm -f "${CANDIDATES_DATA_FILE}"' EXIT

SCRIPT_NAME="$(basename "$0")"
REPORT_DATE_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if [[ "${OUTPUT_DIR}" == "${INVOCATION_DIR}"/* ]]; then
  find_args=("${INVOCATION_DIR}" -path "${OUTPUT_DIR}" -prune -o -type f -print0)
else
  find_args=("${INVOCATION_DIR}" -type f -print0)
fi

while IFS= read -r -d '' file; do
  size_bytes="$(stat -c '%s' "$file")"

  printf '%s	%s
' "$file" "$size_bytes" >> "${CANDIDATES_DATA_FILE}"
done < <(find "${find_args[@]}")

sort -t $'	' -k2,2nr -k1,1 -o "${CANDIDATES_DATA_FILE}" "${CANDIDATES_DATA_FILE}"

{
  printf '# Script: %s
' "${SCRIPT_NAME}"
  printf '# Report date (UTC): %s
' "${REPORT_DATE_UTC}"
  printf '# Target directory: %s
' "${INVOCATION_DIR}"
  printf '# Subject: recursive file size candidates in bytes (TSV: path<TAB>size_bytes)

'
  cat "${CANDIDATES_DATA_FILE}"
} > "${CANDIDATES_FILE}"

{
  printf '# Script: %s
' "${SCRIPT_NAME}"
  printf '# Report date (UTC): %s
' "${REPORT_DATE_UTC}"
  printf '# Target directory: %s
' "${INVOCATION_DIR}"
  printf '# Subject: recursive file sizes in GiB (binary units)

'
  awk -F $'\t' '{ printf "%s | %.3f GiB\n", $1, $2/1073741824 }' "${CANDIDATES_DATA_FILE}"
} > "${FILE_SIZES_FILE}"

python3 - "${CANDIDATES_FILE}" "${RECOMMENDATIONS_FILE}" "${SCRIPT_NAME}" "${REPORT_DATE_UTC}" "${INVOCATION_DIR}" <<'PY'
import csv
import math
import sys

candidates_file = sys.argv[1]
recommendations_file = sys.argv[2]
script_name = sys.argv[3]
report_date_utc = sys.argv[4]
report_target = sys.argv[5]
CAP_50_BYTES = int(round(46.4 * 1024**3))
CAP_100_BYTES = int(round(93.1 * 1024**3))

items = []
with open(candidates_file, newline="", encoding="utf-8") as f:
    reader = csv.reader(f, delimiter="\t")
    for row in reader:
        if not row:
            continue
        if row[0].startswith("#"):
            continue
        if len(row) != 2:
            continue
        path, size_bytes = row
        items.append((path, int(size_bytes)))

items.sort(key=lambda x: (-x[1], x[0]))
oversized_items = [(path, size) for path, size in items if size > CAP_100_BYTES]
packable_items = [(path, size) for path, size in items if size <= CAP_100_BYTES]
sizes_bytes = [size for _, size in packable_items]
suffix = [0] * (len(sizes_bytes) + 1)
for i in range(len(sizes_bytes) - 1, -1, -1):
    suffix[i] = suffix[i + 1] + sizes_bytes[i]


def try_pack(capacities):
    bins = [{"cap": c, "used": 0, "items": []} for c in capacities]
    failed = set()

    def dfs(idx):
        if idx == len(packable_items):
            return True

        free_spaces = [b["cap"] - b["used"] for b in bins]
        state = (idx, tuple(sorted(free_spaces, reverse=True)))
        if state in failed:
            return False
        if sum(free_spaces) < suffix[idx]:
            failed.add(state)
            return False

        needed = sizes_bytes[idx]
        seen_free = set()
        for b in bins:
            free = b["cap"] - b["used"]
            if free < needed or free in seen_free:
                continue
            seen_free.add(free)
            b["used"] += needed
            b["items"].append(idx)
            if dfs(idx + 1):
                return True
            b["items"].pop()
            b["used"] -= needed

        failed.add(state)
        return False

    if dfs(0):
        return bins
    return None


def find_optimal_mixed_plan():
    total = sum(sizes_bytes)
    if not packable_items:
        if oversized_items:
            return None
        return {"bins": [], "n100": 0, "n50": 0, "capacity": 0}

    min_disks = max(1, math.ceil(total / CAP_100_BYTES))
    max_disks = math.ceil(total / CAP_50_BYTES)

    for disk_count in range(min_disks, max_disks + 1):
        pairs = []
        for n100 in range(0, disk_count + 1):
            n50 = disk_count - n100
            capacity = n100 * CAP_100_BYTES + n50 * CAP_50_BYTES
            if capacity < total:
                continue
            pairs.append((capacity, n100, n50))

        pairs.sort(key=lambda x: (x[0], x[1]))
        for capacity, n100, n50 in pairs:
            capacities = [CAP_100_BYTES] * n100 + [CAP_50_BYTES] * n50
            packed = try_pack(capacities)
            if packed is not None:
                return {"bins": packed, "n100": n100, "n50": n50, "capacity": capacity}

    return None


def find_optimal_50_only_plan():
    total = sum(sizes_bytes)
    if not packable_items:
        if oversized_items:
            return None
        return {"bins": [], "n100": 0, "n50": 0, "capacity": 0}
    if any(size > CAP_50_BYTES for size in sizes_bytes):
        return None

    start = max(1, math.ceil(total / CAP_50_BYTES))
    for n50 in range(start, len(packable_items) + 1):
        capacities = [CAP_50_BYTES] * n50
        packed = try_pack(capacities)
        if packed is not None:
            return {"bins": packed, "n100": 0, "n50": n50, "capacity": n50 * CAP_50_BYTES}
    return None


def find_optimal_100_only_plan():
    total = sum(sizes_bytes)
    if not packable_items:
        if oversized_items:
            return None
        return {"bins": [], "n100": 0, "n50": 0, "capacity": 0}

    start = max(1, math.ceil(total / CAP_100_BYTES))
    for n100 in range(start, len(packable_items) + 1):
        capacities = [CAP_100_BYTES] * n100
        packed = try_pack(capacities)
        if packed is not None:
            return {"bins": packed, "n100": n100, "n50": 0, "capacity": n100 * CAP_100_BYTES}
    return None


def bytes_to_gib(value):
    return value / 1024**3


def write_plan(out, header, plan):
    total_data = sum(sizes_bytes)
    out.write(f"=== {header} ===\n")
    if plan is None:
        out.write("No feasible plan remains for packable items.\n\n")
        return

    total_disks = plan["n100"] + plan["n50"]
    unused = plan["capacity"] - total_data
    out.write(f"Combination: {plan['n100']} x 100 GB marketed (93.1 GiB) + {plan['n50']} x 50 GB marketed (46.4 GiB)\n")
    out.write(f"Total disks: {total_disks}\n")
    out.write(f"Disk counts by size (marketed): 100GB={plan['n100']}, 50GB={plan['n50']}\n")
    out.write(f"Total data size: {bytes_to_gib(total_data):.3f} GiB\n")
    out.write(f"Total writable capacity: {bytes_to_gib(plan['capacity']):.3f} GiB\n")
    out.write(f"Total unused space: {bytes_to_gib(unused):.3f} GiB\n\n")

    for i, b in enumerate(plan["bins"], start=1):
        used_gb = bytes_to_gib(b["used"])
        cap_gb = bytes_to_gib(b["cap"])
        unused_gb = cap_gb - used_gb
        out.write(
            f"Disk [{i} of {total_disks}] [{cap_gb:.1f} GiB] | Size used: {used_gb:.3f} GiB | Unused space: {unused_gb:.3f} GiB\n"
        )
        for pick in b["items"]:
            out.write(f"{packable_items[pick][0]}\n")
        out.write("\n")


def write_oversized(out):
    out.write("=== OVERSIZED ===\n")
    if not oversized_items:
        out.write("None.\n\n")
        return
    for path, size in oversized_items:
        out.write(f"{path} | {bytes_to_gib(size):.3f} GiB\n")
    out.write("\n")

with open(recommendations_file, "w", encoding="utf-8") as out:
    out.write(f"# Script: {script_name}\n")
    out.write(f"# Report date (UTC): {report_date_utc}\n")
    out.write(f"# Target directory: {report_target}\n")
    out.write("# Subject: optimal Blu-ray file packing recommendations (marketed GB labels with binary GiB capacities)\n\n")
    write_oversized(out)
    write_plan(out, "OPTIMAL MIXED DISK PLAN (50 GB marketed / 46.4 GiB + 100 GB marketed / 93.1 GiB)", find_optimal_mixed_plan())
    write_plan(out, "OPTIMAL 50 GB-ONLY DISK PLAN (46.4 GiB usable)", find_optimal_50_only_plan())
    write_plan(out, "OPTIMAL 100 GB-ONLY DISK PLAN (93.1 GiB usable)", find_optimal_100_only_plan())
PY


echo "Wrote: ${FILE_SIZES_FILE}"
echo "Wrote: ${RECOMMENDATIONS_FILE}"
echo "Wrote: ${CANDIDATES_FILE}"
