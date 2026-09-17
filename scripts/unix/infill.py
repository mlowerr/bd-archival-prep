#!/usr/bin/env python3
"""Fill existing disk directories with files from one or more infill trees."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path


UNITS = {
    "b": 1,
    "kb": 1000,
    "mb": 1000**2,
    "gb": 1000**3,
    "tb": 1000**4,
    "kib": 1024,
    "mib": 1024**2,
    "gib": 1024**3,
    "tib": 1024**4,
}


@dataclass(frozen=True)
class Candidate:
    source: Path
    destination_relative: Path
    size: int


def bundle_linked_candidates(candidates: list[Candidate]) -> list[list[Candidate]]:
    """Keep symlinks and their in-tree targets in the same allocation."""
    candidate_by_source = {candidate.source.absolute(): index for index, candidate in enumerate(candidates)}
    linked: list[set[int]] = [set() for _ in candidates]
    for index, candidate in enumerate(candidates):
        if not candidate.source.is_symlink():
            continue
        target_index = candidate_by_source.get(candidate.source.resolve())
        if target_index is not None:
            linked[index].add(target_index)
            linked[target_index].add(index)

    bundles: list[list[Candidate]] = []
    unbundled = set(range(len(candidates)))
    while unbundled:
        pending = [min(unbundled)]
        component: list[int] = []
        while pending:
            index = pending.pop()
            if index not in unbundled:
                continue
            unbundled.remove(index)
            component.append(index)
            pending.extend(linked[index])
        bundles.append([candidates[index] for index in sorted(component)])
    return bundles


def capacity_bytes(value: str) -> int:
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([kmgt]?i?b)?\s*", value, re.I)
    if not match:
        raise argparse.ArgumentTypeError(
            "capacity must be a positive number, optionally followed by B, KB, MB, GB, TB, KiB, MiB, GiB, or TiB"
        )
    number = float(match.group(1))
    unit = (match.group(2) or "gib").lower()
    result = round(number * UNITS[unit])
    if result <= 0:
        raise argparse.ArgumentTypeError("capacity must be greater than zero")
    return result


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Move largest-fitting files from infill directories into existing disk directories."
    )
    result.add_argument(
        "--disk-capacity", "--capacity", type=capacity_bytes, metavar="SIZE",
        help="capacity of every target disk directory (a bare number means GiB)",
    )
    result.add_argument(
        "--infill-dir", action="append", type=Path, metavar="DIR",
        help="directory containing infill files; may be supplied more than once",
    )
    result.add_argument(
        "--target-dir", type=Path, default=Path.cwd(), metavar="DIR",
        help="directory containing disk directories (default: current directory)",
    )
    result.add_argument("--dry-run", action="store_true", help="print moves without changing files")
    return result


def directory_file_size(path: Path) -> int:
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def allocate_bundles(
    targets: list[Path], bundles: list[list[Candidate]], capacity: int
) -> list[tuple[Path, list[Candidate]]]:
    """Allocate one fitting bundle per target per pass until none fit."""
    remaining_by_target = {
        target: capacity - directory_file_size(target)
        for target in targets
    }
    unallocated = list(bundles)
    allocations: list[tuple[Path, list[Candidate]]] = []
    reserved_destinations: set[Path] = set()

    while unallocated:
        allocated_this_pass = False
        for target in targets:
            remaining = remaining_by_target[target]
            if remaining <= 0:
                continue
            for bundle in unallocated:
                bundle_size = sum(candidate.size for candidate in bundle)
                destinations = [target / candidate.destination_relative for candidate in bundle]
                if bundle_size > remaining or any(
                    destination.exists() or destination in reserved_destinations
                    for destination in destinations
                ):
                    continue
                allocations.append((target, bundle))
                unallocated.remove(bundle)
                reserved_destinations.update(destinations)
                remaining_by_target[target] -= bundle_size
                allocated_this_pass = True
                break
        if not allocated_this_pass:
            break

    return allocations


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.disk_capacity is None:
        try:
            args.disk_capacity = capacity_bytes(input("Disk capacity (for example 46.5GiB): "))
        except (EOFError, argparse.ArgumentTypeError) as error:
            print(f"Error: {error}", file=sys.stderr)
            return 2
    if not args.infill_dir:
        try:
            entered = input("Infill directory: ").strip()
        except EOFError:
            entered = ""
        if not entered:
            print("Error: an infill directory is required.", file=sys.stderr)
            return 2
        args.infill_dir = [Path(entered)]

    target_root = args.target_dir.expanduser().resolve()
    sources = [path.expanduser().resolve() for path in args.infill_dir]
    if not target_root.is_dir():
        print(f"Error: target directory does not exist: {target_root}", file=sys.stderr)
        return 2
    for source in sources:
        if not source.is_dir():
            print(f"Error: infill directory does not exist: {source}", file=sys.stderr)
            return 2
        if source == target_root or source in target_root.parents:
            print("Error: an infill directory cannot be the target directory or contain it.", file=sys.stderr)
            return 2

    source_set = set(sources)
    targets = sorted(
        (path for path in target_root.iterdir() if path.is_dir() and path.name != ".archival-prep"
         and not any(path.resolve() == source or path.resolve() in source.parents for source in source_set)),
        key=lambda path: path.name,
    )
    if not targets:
        print(f"No infill opportunity: no disk directories found in {target_root}.")
        return 0

    candidates: list[Candidate] = []
    seen_files: set[Path] = set()
    for source in sources:
        for item in source.rglob("*"):
            if item.is_file():
                absolute_item = item.absolute()
                if absolute_item in seen_files:
                    continue
                seen_files.add(absolute_item)
                candidates.append(Candidate(item, Path(source.name) / item.relative_to(source), item.stat().st_size))
    candidates.sort(key=lambda item: (-item.size, str(item.source)))
    bundles = bundle_linked_candidates(candidates)
    bundles.sort(key=lambda bundle: (-sum(candidate.size for candidate in bundle), str(bundle[0].source)))

    allocations = allocate_bundles(targets, bundles, args.disk_capacity)
    moved = 0
    for target, bundle in allocations:
        destinations = [target / candidate.destination_relative for candidate in bundle]
        destination_by_source = {
            candidate.source.absolute(): destination
            for candidate, destination in zip(bundle, destinations)
        }
        for candidate, destination in zip(bundle, destinations):
            print(f"{'Would move' if args.dry_run else 'Moving'}: {candidate.source} -> {destination}")
            if not args.dry_run:
                destination.parent.mkdir(parents=True, exist_ok=True)
                target_destination = (
                    destination_by_source.get(candidate.source.resolve())
                    if candidate.source.is_symlink()
                    else None
                )
                if target_destination is None:
                    shutil.move(str(candidate.source), str(destination))
                else:
                    link_target = candidate.source.readlink()
                    candidate.source.unlink()
                    if link_target.is_absolute():
                        destination.symlink_to(target_destination)
                    else:
                        destination.symlink_to(os.path.relpath(target_destination, destination.parent))
            moved += 1

    if moved == 0:
        print("No infill opportunity: no infill file fits the available disk space.")
    else:
        verb = "would be moved" if args.dry_run else "moved"
        print(f"Infill complete: {moved} file(s) {verb}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
