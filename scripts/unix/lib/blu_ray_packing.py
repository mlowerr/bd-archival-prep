#!/usr/bin/env python3
import csv
import math
import sys

CAP_50_BYTES = int(round(46.4 * 1024**3))
CAP_100_BYTES = int(round(93.1 * 1024**3))
MEDIUM_WORKLOAD_MIN_ITEMS = 50
MEDIUM_WORKLOAD_MAX_ITEMS = 500
MEDIUM_DFS_STATE_BUDGET = 250000
RECURSION_PADDING = 100


def load_items(candidates_file):
    items = []
    with open(candidates_file, newline="", encoding="utf-8") as handle:
        reader = csv.reader(handle, delimiter="\t")
        for row in reader:
            if not row:
                continue
            if row[0].startswith("#"):
                continue
            if len(row) != 2:
                continue
            path, size_bytes = row
            items.append((path, int(size_bytes)))
    items.sort(key=lambda entry: (-entry[1], entry[0]))
    return items


def bytes_to_gib(value):
    return value / 1024**3


def build_context(items):
    oversized_items = [(path, size) for path, size in items if size > CAP_100_BYTES]
    packable_items = [(path, size) for path, size in items if size <= CAP_100_BYTES]
    sizes_bytes = [size for _, size in packable_items]
    suffix = [0] * (len(sizes_bytes) + 1)
    for index in range(len(sizes_bytes) - 1, -1, -1):
        suffix[index] = suffix[index + 1] + sizes_bytes[index]
    return {
        "items": items,
        "oversized_items": oversized_items,
        "packable_items": packable_items,
        "sizes_bytes": sizes_bytes,
        "suffix": suffix,
    }


def try_pack(context, capacities):
    sizes_bytes = context["sizes_bytes"]
    packable_items = context["packable_items"]
    suffix = context["suffix"]
    used_fallback = False
    bins = [{"cap": capacity, "used": 0, "items": []} for capacity in capacities]
    failed = set()

    def result(packed_bins):
        return {"bins": packed_bins, "used_fallback": used_fallback}

    def greedy_pack():
        for index, needed in enumerate(sizes_bytes):
            best_bin = None
            best_free_after = None
            for bin_index, bin_info in enumerate(bins):
                free = bin_info["cap"] - bin_info["used"]
                if free < needed:
                    continue
                free_after = free - needed
                if best_bin is None or free_after < best_free_after or (
                    free_after == best_free_after and bin_index < best_bin
                ):
                    best_bin = bin_index
                    best_free_after = free_after

            if best_bin is None:
                return None

            bins[best_bin]["used"] += needed
            bins[best_bin]["items"].append(index)
        return bins

    if len(sizes_bytes) == 0:
        return result(bins)

    if len(packable_items) > MEDIUM_WORKLOAD_MAX_ITEMS:
        used_fallback = True
        return result(greedy_pack())

    recursion_limit = max(sys.getrecursionlimit(), len(packable_items) + RECURSION_PADDING)
    sys.setrecursionlimit(recursion_limit)
    search_budget = (
        MEDIUM_DFS_STATE_BUDGET
        if MEDIUM_WORKLOAD_MIN_ITEMS <= len(packable_items) <= MEDIUM_WORKLOAD_MAX_ITEMS
        else None
    )
    states_visited = 0
    budget_exhausted = False

    def dfs(index):
        nonlocal states_visited, budget_exhausted
        states_visited += 1
        if search_budget is not None and states_visited > search_budget:
            budget_exhausted = True
            return False
        if index == len(packable_items):
            return True

        free_spaces = [bin_info["cap"] - bin_info["used"] for bin_info in bins]
        state = (index, tuple(sorted(free_spaces, reverse=True)))
        if state in failed:
            return False
        if sum(free_spaces) < suffix[index]:
            failed.add(state)
            return False

        needed = sizes_bytes[index]
        seen_free = set()
        for bin_info in bins:
            free = bin_info["cap"] - bin_info["used"]
            if free < needed or free in seen_free:
                continue
            seen_free.add(free)
            bin_info["used"] += needed
            bin_info["items"].append(index)
            if dfs(index + 1):
                return True
            bin_info["items"].pop()
            bin_info["used"] -= needed

        failed.add(state)
        return False

    if dfs(0):
        return result(bins)
    if budget_exhausted:
        used_fallback = True
        return result(greedy_pack())
    return result(None)


def find_optimal_mixed_plan(context):
    sizes_bytes = context["sizes_bytes"]
    packable_items = context["packable_items"]
    oversized_items = context["oversized_items"]
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

        pairs.sort(key=lambda value: (value[0], value[1]))
        for capacity, n100, n50 in pairs:
            capacities = [CAP_100_BYTES] * n100 + [CAP_50_BYTES] * n50
            pack_result = try_pack(context, capacities)
            if pack_result["bins"] is not None:
                return {
                    "bins": pack_result["bins"],
                    "n100": n100,
                    "n50": n50,
                    "capacity": capacity,
                    "used_fallback": pack_result["used_fallback"],
                }

    return None


def find_optimal_50_only_plan(context):
    sizes_bytes = context["sizes_bytes"]
    packable_items = context["packable_items"]
    oversized_items = context["oversized_items"]
    total = sum(sizes_bytes)
    if not packable_items:
        if oversized_items:
            return None
        return {"bins": [], "n100": 0, "n50": 0, "capacity": 0}
    if max(sizes_bytes) > CAP_50_BYTES:
        return None

    start = max(1, math.ceil(total / CAP_50_BYTES))
    for n50 in range(start, len(packable_items) + 1):
        capacities = [CAP_50_BYTES] * n50
        pack_result = try_pack(context, capacities)
        if pack_result["bins"] is not None:
            return {
                "bins": pack_result["bins"],
                "n100": 0,
                "n50": n50,
                "capacity": n50 * CAP_50_BYTES,
                "used_fallback": pack_result["used_fallback"],
            }
    return None


def find_optimal_100_only_plan(context):
    sizes_bytes = context["sizes_bytes"]
    packable_items = context["packable_items"]
    oversized_items = context["oversized_items"]
    total = sum(sizes_bytes)
    if not packable_items:
        if oversized_items:
            return None
        return {"bins": [], "n100": 0, "n50": 0, "capacity": 0}

    start = max(1, math.ceil(total / CAP_100_BYTES))
    for n100 in range(start, len(packable_items) + 1):
        capacities = [CAP_100_BYTES] * n100
        pack_result = try_pack(context, capacities)
        if pack_result["bins"] is not None:
            return {
                "bins": pack_result["bins"],
                "n100": n100,
                "n50": 0,
                "capacity": n100 * CAP_100_BYTES,
                "used_fallback": pack_result["used_fallback"],
            }
    return None


def write_plan(output_handle, header, plan, context):
    sizes_bytes = context["sizes_bytes"]
    items = context["items"]
    oversized_items = context["oversized_items"]
    packable_items = context["packable_items"]
    total_data = sum(sizes_bytes)

    output_handle.write(f"=== {header} ===\n")
    if plan is None:
        if packable_items and len(packable_items) < len(items):
            output_handle.write("No feasible plan found for packable items.\n\n")
            return
        if not packable_items and oversized_items:
            output_handle.write("All items are oversized (> 93.1 GiB); no packable items remain.\n\n")
            return
        output_handle.write("No feasible plan found.\n\n")
        return

    total_disks = plan["n100"] + plan["n50"]
    unused = plan["capacity"] - total_data
    output_handle.write(
        f"Combination: {plan['n100']} x 100 GB marketed (93.1 GiB) + {plan['n50']} x 50 GB marketed (46.4 GiB)\n"
    )
    output_handle.write(f"Total disks: {total_disks}\n")
    output_handle.write(
        f"Disk counts by size (marketed): 100GB={plan['n100']}, 50GB={plan['n50']}\n"
    )
    output_handle.write(f"Total data size: {bytes_to_gib(total_data):.3f} GiB\n")
    output_handle.write(f"Total writable capacity: {bytes_to_gib(plan['capacity']):.3f} GiB\n")
    output_handle.write(f"Total unused space: {bytes_to_gib(unused):.3f} GiB\n\n")
    if plan.get("used_fallback", False):
        output_handle.write(
            f"Packing strategy: best-fit fallback used (exact DFS target range: {MEDIUM_WORKLOAD_MIN_ITEMS}-{MEDIUM_WORKLOAD_MAX_ITEMS} items, budget {MEDIUM_DFS_STATE_BUDGET} explored states).\n\n"
        )

    for index, bin_info in enumerate(plan["bins"], start=1):
        used_gib = bytes_to_gib(bin_info["used"])
        capacity_gib = bytes_to_gib(bin_info["cap"])
        unused_gib = capacity_gib - used_gib
        output_handle.write(
            f"Disk [{index} of {total_disks}] [{capacity_gib:.1f} GiB] | Size used: {used_gib:.3f} GiB | Unused space: {unused_gib:.3f} GiB\n"
        )
        for pick in bin_info["items"]:
            output_handle.write(f"{packable_items[pick][0]}\n")
        output_handle.write("\n")


def main():
    candidates_file = sys.argv[1]
    recommendations_file = sys.argv[2]
    script_name = sys.argv[3]
    report_date_utc = sys.argv[4]
    report_target = sys.argv[5]
    recommendations_subject = sys.argv[6]

    context = build_context(load_items(candidates_file))
    oversized_items = context["oversized_items"]

    with open(recommendations_file, "w", encoding="utf-8") as output_handle:
        output_handle.write(f"# Script: {script_name}\n")
        output_handle.write(f"# Report date (UTC): {report_date_utc}\n")
        output_handle.write(f"# Target directory: {report_target}\n")
        output_handle.write(f"# Subject: {recommendations_subject}\n\n")
        output_handle.write("=== OVERSIZED ===\n")
        if oversized_items:
            for path, size in oversized_items:
                output_handle.write(f"{path} | {bytes_to_gib(size):.3f} GiB\n")
        else:
            output_handle.write("None.\n")
        output_handle.write("\n")
        write_plan(
            output_handle,
            "OPTIMAL MIXED DISK PLAN (50 GB marketed / 46.4 GiB + 100 GB marketed / 93.1 GiB)",
            find_optimal_mixed_plan(context),
            context,
        )
        write_plan(
            output_handle,
            "OPTIMAL 50 GB-ONLY DISK PLAN (46.4 GiB usable)",
            find_optimal_50_only_plan(context),
            context,
        )
        write_plan(
            output_handle,
            "OPTIMAL 100 GB-ONLY DISK PLAN (93.1 GiB usable)",
            find_optimal_100_only_plan(context),
            context,
        )


if __name__ == "__main__":
    main()
