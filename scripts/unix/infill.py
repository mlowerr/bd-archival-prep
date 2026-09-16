#!/usr/bin/env python3
"""Fill existing disk directories with files from one or more infill trees."""

from __future__ import annotations

import argparse
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
                resolved_item = item.resolve()
                if resolved_item in seen_files:
                    continue
                seen_files.add(resolved_item)
                candidates.append(Candidate(item, Path(source.name) / item.relative_to(source), item.stat().st_size))
    candidates.sort(key=lambda item: (-item.size, str(item.source)))

    moved = 0
    for target in targets:
        remaining = args.disk_capacity - directory_file_size(target)
        if remaining <= 0:
            continue
        for candidate in list(candidates):
            destination = target / candidate.destination_relative
            if candidate.size > remaining or destination.exists():
                continue
            print(f"{'Would move' if args.dry_run else 'Moving'}: {candidate.source} -> {destination}")
            if not args.dry_run:
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(candidate.source), str(destination))
            candidates.remove(candidate)
            remaining -= candidate.size
            moved += 1

    if moved == 0:
        print("No infill opportunity: no infill file fits the available disk space.")
    else:
        verb = "would be moved" if args.dry_run else "moved"
        print(f"Infill complete: {moved} file(s) {verb}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
