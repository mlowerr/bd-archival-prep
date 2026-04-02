#!/usr/bin/env bash
set -euo pipefail

INVOCATION_DIR="$(pwd)"
OUTPUT_DIR="${INVOCATION_DIR}/.archival-prep"
FOLDER_SIZES_FILE="${OUTPUT_DIR}/folder-sizes.txt"
RECOMMENDATIONS_FILE="${OUTPUT_DIR}/blu-ray-recommendations.txt"
CANDIDATES_FILE="${OUTPUT_DIR}/folder-sizes.tsv"

mkdir -p "${OUTPUT_DIR}"
: > "${FOLDER_SIZES_FILE}"
: > "${RECOMMENDATIONS_FILE}"
: > "${CANDIDATES_FILE}"

while IFS= read -r -d '' dir; do
  size_kb="$(du -sk "$dir" | cut -f1)"
  size_gb="$(awk -v kb="$size_kb" 'BEGIN { printf "%.3f", kb/1048576 }')"
  abs_path="$(cd "$dir" && pwd)"

  printf '%s\t%s\n' "$abs_path" "$size_kb" >> "${CANDIDATES_FILE}"
  printf '%s | %s GB\n' "$abs_path" "$size_gb" >> "${FOLDER_SIZES_FILE}"
done < <(find "${INVOCATION_DIR}" -mindepth 1 -maxdepth 1 -type d ! -name '.archival-prep' -print0)

sort -t $'\t' -k2,2nr -o "${CANDIDATES_FILE}" "${CANDIDATES_FILE}"

python3 - "${CANDIDATES_FILE}" "${RECOMMENDATIONS_FILE}" <<'PY'
import csv
import heapq
import sys

candidates_file = sys.argv[1]
recommendations_file = sys.argv[2]
limits = [46.4, 93.1]
top_k = 3

items = []
with open(candidates_file, newline="", encoding="utf-8") as f:
    reader = csv.reader(f, delimiter="\t")
    for row in reader:
        if len(row) != 2:
            continue
        path, size_kb = row
        items.append((path, int(size_kb)))

sizes_kb = [s for _, s in items]
suffix = [0] * (len(sizes_kb) + 1)
for i in range(len(sizes_kb) - 1, -1, -1):
    suffix[i] = suffix[i + 1] + sizes_kb[i]


def best_subsets(limit_gb):
    limit_kb = limit_gb * 1048576.0
    heap = []  # (used_size, mask)
    seen_masks = set()

    def maybe_add(mask, used):
        rounded = round(used, 6)
        key = (mask, rounded)
        if key in seen_masks:
            return
        seen_masks.add(key)
        if len(heap) < top_k:
            heapq.heappush(heap, (used, mask))
            return
        if used > heap[0][0] + 1e-9:
            heapq.heapreplace(heap, (used, mask))

    def dfs(idx, used_kb, mask):
        if used_kb > limit_kb + 1e-9:
            return
        if idx == len(items):
            maybe_add(mask, used_kb)
            return

        floor = heap[0][0] if len(heap) == top_k else -1.0
        if used_kb + suffix[idx] < floor - 1e-9:
            return

        dfs(idx + 1, used_kb + items[idx][1], mask | (1 << idx))
        dfs(idx + 1, used_kb, mask)

    dfs(0, 0.0, 0)
    results = sorted(heap, key=lambda x: x[0], reverse=True)
    return results

with open(recommendations_file, "w", encoding="utf-8") as out:
    for limit in limits:
        subsets = best_subsets(limit)
        if not subsets:
            out.write(f"[{limit:.1f} GB] Blu Ray Disk [1 of recommendation] | Size used: 0.000 GB | Unused space: {limit:.3f} GB\n")
            continue

        for idx, (used_kb, mask) in enumerate(subsets, start=1):
            used_gb = used_kb / 1048576.0
            unused = limit - used_gb
            out.write(
                f"[{limit:.1f} GB] Blu Ray Disk [{idx} of recommendation] | Size used: {used_gb:.3f} GB | Unused space: {unused:.3f} GB\n"
            )
            for bit in range(len(items)):
                if mask & (1 << bit):
                    out.write(f"{items[bit][0]}\n")
            out.write("\n")
PY

echo "Wrote: ${FOLDER_SIZES_FILE}"
echo "Wrote: ${RECOMMENDATIONS_FILE}"
