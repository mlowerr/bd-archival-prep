#!/usr/bin/env bash
set -euo pipefail

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

INVOCATION_DIR="$(cd -- "$INVOCATION_DIR" && pwd)"
if [[ "${OUTPUT_DIR_SET}" == false ]]; then
  OUTPUT_DIR="${INVOCATION_DIR}/.archival-prep"
fi
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"

FOLDER_SIZES_FILE="${OUTPUT_DIR}/folder-sizes.txt"
RECOMMENDATIONS_FILE="${OUTPUT_DIR}/blu-ray-recommendations.txt"
CANDIDATES_FILE="${OUTPUT_DIR}/folder-sizes.tsv"
CANDIDATES_DATA_FILE="$(mktemp)"
trap 'rm -f "${CANDIDATES_DATA_FILE}"' EXIT

SCRIPT_NAME="$(basename "$0")"
REPORT_DATE_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

while IFS= read -r -d '' dir; do
  size_kb="$(du -sk "$dir" | cut -f1)"
  size_gb="$(awk -v kb="$size_kb" 'BEGIN { printf "%.3f", kb/1048576 }')"
  abs_path="$(cd "$dir" && pwd)"

  printf '%s\t%s\n' "$abs_path" "$size_kb" >> "${CANDIDATES_DATA_FILE}"
  printf '%s | %s GB\n' "$abs_path" "$size_gb" >> "${FOLDER_SIZES_FILE}.body"
done < <(find "${INVOCATION_DIR}" -mindepth 1 -maxdepth 1 -type d ! -name '.archival-prep' -print0)

sort -t $'\t' -k2,2nr -o "${CANDIDATES_DATA_FILE}" "${CANDIDATES_DATA_FILE}"

{
  printf '# Script: %s\n' "${SCRIPT_NAME}"
  printf '# Report date (UTC): %s\n' "${REPORT_DATE_UTC}"
  printf '# Reporting on: %s\n' "${INVOCATION_DIR}"
  printf '# Subject: first-level folder sizes in GB\n\n'
  if [[ -f "${FOLDER_SIZES_FILE}.body" ]]; then
    cat "${FOLDER_SIZES_FILE}.body"
  fi
} > "${FOLDER_SIZES_FILE}"

{
  printf '# Script: %s\n' "${SCRIPT_NAME}"
  printf '# Report date (UTC): %s\n' "${REPORT_DATE_UTC}"
  printf '# Reporting on: %s\n' "${INVOCATION_DIR}"
  printf '# Subject: first-level folder size candidates in KB (TSV: path<TAB>size_kb)\n\n'
  cat "${CANDIDATES_DATA_FILE}"
} > "${CANDIDATES_FILE}"

python3 - "${CANDIDATES_FILE}" "${RECOMMENDATIONS_FILE}" "${SCRIPT_NAME}" "${REPORT_DATE_UTC}" "${INVOCATION_DIR}" <<'PY'
import csv
import math
import sys

candidates_file = sys.argv[1]
recommendations_file = sys.argv[2]
script_name = sys.argv[3]
report_date_utc = sys.argv[4]
report_target = sys.argv[5]
CAP_50_KB = int(round(46.4 * 1048576))
CAP_100_KB = int(round(93.1 * 1048576))

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
        path, size_kb = row
        items.append((path, int(size_kb)))

items.sort(key=lambda x: x[1], reverse=True)
sizes_kb = [size for _, size in items]
suffix = [0] * (len(sizes_kb) + 1)
for i in range(len(sizes_kb) - 1, -1, -1):
    suffix[i] = suffix[i + 1] + sizes_kb[i]


def try_pack(capacities):
    bins = [{"cap": c, "used": 0, "items": []} for c in capacities]
    failed = set()

    def dfs(idx):
        if idx == len(items):
            return True

        free_spaces = [b["cap"] - b["used"] for b in bins]
        state = (idx, tuple(sorted(free_spaces, reverse=True)))
        if state in failed:
            return False
        if sum(free_spaces) < suffix[idx]:
            failed.add(state)
            return False

        needed = sizes_kb[idx]
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
    total = sum(sizes_kb)
    if not items:
        return {"bins": [], "n100": 0, "n50": 0, "capacity": 0}

    if max(sizes_kb) > CAP_100_KB:
        return None

    min_disks = max(1, math.ceil(total / CAP_100_KB))
    max_disks = math.ceil(total / CAP_50_KB)

    for disk_count in range(min_disks, max_disks + 1):
        pairs = []
        for n100 in range(0, disk_count + 1):
            n50 = disk_count - n100
            capacity = n100 * CAP_100_KB + n50 * CAP_50_KB
            if capacity < total:
                continue
            pairs.append((capacity, n100, n50))

        pairs.sort(key=lambda x: (x[0], x[1]))
        for capacity, n100, n50 in pairs:
            capacities = [CAP_100_KB] * n100 + [CAP_50_KB] * n50
            packed = try_pack(capacities)
            if packed is not None:
                return {"bins": packed, "n100": n100, "n50": n50, "capacity": capacity}

    return None


def find_optimal_50_only_plan():
    total = sum(sizes_kb)
    if not items:
        return {"bins": [], "n100": 0, "n50": 0, "capacity": 0}
    if max(sizes_kb) > CAP_50_KB:
        return None

    start = max(1, math.ceil(total / CAP_50_KB))
    for n50 in range(start, len(items) + 1):
        capacities = [CAP_50_KB] * n50
        packed = try_pack(capacities)
        if packed is not None:
            return {"bins": packed, "n100": 0, "n50": n50, "capacity": n50 * CAP_50_KB}
    return None


def find_optimal_100_only_plan():
    total = sum(sizes_kb)
    if not items:
        return {"bins": [], "n100": 0, "n50": 0, "capacity": 0}
    if max(sizes_kb) > CAP_100_KB:
        return None

    start = max(1, math.ceil(total / CAP_100_KB))
    for n100 in range(start, len(items) + 1):
        capacities = [CAP_100_KB] * n100
        packed = try_pack(capacities)
        if packed is not None:
            return {"bins": packed, "n100": n100, "n50": 0, "capacity": n100 * CAP_100_KB}
    return None


def kb_to_gb(value):
    return value / 1048576.0


def write_plan(out, header, plan):
    total_data = sum(sizes_kb)
    out.write(f"=== {header} ===\n")
    if plan is None:
        out.write("No feasible plan found.\n\n")
        return

    total_disks = plan["n100"] + plan["n50"]
    unused = plan["capacity"] - total_data
    out.write(f"Combination: {plan['n100']} x 93.1 GB + {plan['n50']} x 46.4 GB\n")
    out.write(f"Total disks: {total_disks}\n")
    out.write(f"Disk counts by size: 100GB={plan['n100']}, 50GB={plan['n50']}\n")
    out.write(f"Total data size: {kb_to_gb(total_data):.3f} GB\n")
    out.write(f"Total writable capacity: {kb_to_gb(plan['capacity']):.3f} GB\n")
    out.write(f"Total unused space: {kb_to_gb(unused):.3f} GB\n\n")

    for i, b in enumerate(plan["bins"], start=1):
        used_gb = kb_to_gb(b["used"])
        cap_gb = kb_to_gb(b["cap"])
        unused_gb = cap_gb - used_gb
        out.write(
            f"Disk [{i} of {total_disks}] [{cap_gb:.1f} GB] | Size used: {used_gb:.3f} GB | Unused space: {unused_gb:.3f} GB\n"
        )
        for pick in b["items"]:
            out.write(f"{items[pick][0]}\n")
        out.write("\n")

with open(recommendations_file, "w", encoding="utf-8") as out:
    out.write(f"# Script: {script_name}\n")
    out.write(f"# Report date (UTC): {report_date_utc}\n")
    out.write(f"# Reporting on: {report_target}\n")
    out.write("# Subject: optimal Blu-ray folder packing recommendations\n\n")
    write_plan(out, "OPTIMAL MIXED DISK PLAN (50GB + 100GB)", find_optimal_mixed_plan())
    write_plan(out, "OPTIMAL 50GB-ONLY DISK PLAN", find_optimal_50_only_plan())
    write_plan(out, "OPTIMAL 100GB-ONLY DISK PLAN", find_optimal_100_only_plan())
PY

rm -f "${FOLDER_SIZES_FILE}.body"

echo "Wrote: ${FOLDER_SIZES_FILE}"
echo "Wrote: ${RECOMMENDATIONS_FILE}"
echo "Wrote: ${CANDIDATES_FILE}"
