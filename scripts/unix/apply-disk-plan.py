#!/usr/bin/env python3
import os
import re
import shutil
import sys
import argparse

def parse_args():
    parser = argparse.ArgumentParser(description="Apply a Blu-ray disk plan by moving items into disk-specific folders.")
    parser.add_argument("--recommendations", help="Path to a file or folder recommendation report.")
    parser.add_argument("--destination", help="Base path where disk folders will be created.")
    parser.add_argument("--disk-size", help="Plan to apply: mixed, 50, 100, a plan number, or a full plan heading.")
    parser.add_argument("--base-name", help="Base name for the disk folders.")
    naming_group = parser.add_mutually_exclusive_group()
    naming_group.add_argument(
        "--include-disk-number",
        action="store_true",
        help="Include -Disk1- when the selected plan contains only one disk.",
    )
    naming_group.add_argument(
        "--disk-number-with-total",
        action="store_true",
        help="Name disks with -DiskNofY- (including -Disk1of1- for a one-disk plan).",
    )
    parser.add_argument(
        "--include-can-add",
        action="store_true",
        help="Append -CanAddXXXGiB using each disk's unused capacity.",
    )
    parser.add_argument(
        "--item-type",
        choices=("files", "folders"),
        default="files",
        help="Move files (default) or first-level folders from the report target.",
    )
    parser.add_argument("--dry-run", action="store_true", help="Show what would be done without moving files.")
    return parser.parse_args()

def get_input(prompt, default=None):
    if default:
        prompt = f"{prompt} [{default}]: "
    else:
        prompt = f"{prompt}: "
    result = input(prompt).strip()
    return result if result else default

def parse_recommendation_file(file_path):
    if not os.path.exists(file_path):
        print(f"Error: File not found: {file_path}")
        sys.exit(1)

    plans = {}
    current_plan = None
    target_dir = None
    
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
    except Exception as e:
        print(f"Error reading file: {e}")
        sys.exit(1)

    plan_header_pattern = re.compile(r'^=== (OPTIMAL .* PLAN .*) ===')
    disk_header_pattern = re.compile(
        r'^Disk \[(\d+) of \d+\] \[.*\] \| Size used: ([\d.]+) GiB '
        r'\| Unused space: ([\d.]+) GiB$'
    )

    i = 0
    while i < len(lines):
        line = lines[i].strip()

        if line.startswith('# Target directory: '):
            raw_target_dir = line[len('# Target directory: '):].strip()
            if raw_target_dir:
                target_dir = os.path.realpath(os.path.expanduser(raw_target_dir))
            i += 1
            continue
        
        plan_match = plan_header_pattern.match(line)
        if plan_match:
            current_plan = plan_match.group(1)
            plans[current_plan] = []
            i += 1
            continue
        
        if current_plan:
            disk_match = disk_header_pattern.match(line)
            if disk_match:
                disk_num = int(disk_match.group(1))
                used_capacity = disk_match.group(2) + "GiB"
                unused_capacity = disk_match.group(3) + "GiB"
                files = []
                i += 1
                while i < len(lines) and lines[i].strip() and not plan_header_pattern.match(lines[i].strip()) and not disk_header_pattern.match(lines[i].strip()):
                    file_path_line = lines[i].strip()
                    if file_path_line.startswith('/'):
                        files.append(file_path_line)
                    i += 1
                plans[current_plan].append({
                    'number': disk_num,
                    'capacity': used_capacity,
                    'unused_capacity': unused_capacity,
                    'files': files
                })
                continue
        i += 1

    if not plans:
        print("Error: No valid plans found in the recommendation file.")
        sys.exit(1)
        
    return plans, target_dir

def select_plan(plan_names, value):
    """Resolve a command-line plan value without changing report plan ordering."""
    normalized = value.strip().casefold()
    matches = []

    size_aliases = {
        "mixed": "mixed disk plan",
        "50": "50 gb-only disk plan",
        "50gb": "50 gb-only disk plan",
        "50 gb": "50 gb-only disk plan",
        "100": "100 gb-only disk plan",
        "100gb": "100 gb-only disk plan",
        "100 gb": "100 gb-only disk plan",
    }

    if normalized in size_aliases:
        heading_fragment = size_aliases[normalized]
        matches = [name for name in plan_names if heading_fragment in name.casefold()]
    elif normalized.isdigit():
        index = int(normalized)
        if 1 <= index <= len(plan_names):
            matches = [plan_names[index - 1]]
    else:
        for name in plan_names:
            folded_name = name.casefold()
            is_match = normalized == folded_name
            if is_match:
                matches.append(name)

    if len(matches) == 1:
        return matches[0]

    choices = ", ".join(f"{idx} ({name})" for idx, name in enumerate(plan_names, 1))
    reason = "ambiguous" if len(matches) > 1 else "invalid"
    print(f"Error: Disk size/plan value {value!r} is {reason}. Accepted choices: {choices}")
    sys.exit(1)

def source_path_to_relative(path, target_dir):
    if target_dir:
        real_path = os.path.realpath(path)
        try:
            if os.path.commonpath([target_dir, real_path]) == target_dir:
                rel_path = os.path.relpath(real_path, target_dir)
                if rel_path != os.curdir and not rel_path.startswith(os.pardir + os.sep):
                    return rel_path
        except ValueError:
            pass

    # Legacy fallback for reports that predate the target-directory metadata header.
    match = re.search(r'/mnt/[a-zA-Z]/(.*)', path)
    if match:
        return match.group(1)
    return path.lstrip(os.sep)

def validate_folder_item(path, target_dir):
    """Return whether path is an immediate child directory of the report target."""
    if not target_dir:
        return False
    real_path = os.path.realpath(path)
    return (
        os.path.dirname(real_path) == target_dir
        and os.path.isdir(real_path)
    )

def main():
    args = parse_args()

    rec_file = args.recommendations
    if not rec_file:
        rec_file = get_input("Path to recommendation file")
    
    if not rec_file or not os.path.exists(rec_file):
        print(f"Error: Valid recommendation file path required.")
        sys.exit(1)

    plans, target_dir = parse_recommendation_file(rec_file)
    
    print("\nAvailable Plans:")
    plan_names = list(plans.keys())
    for idx, name in enumerate(plan_names, 1):
        print(f"{idx}. {name}")
    
    choice = args.disk_size
    if choice is None:
        choice = get_input(f"Select a plan (1-{len(plan_names)})")
    selected_plan_name = select_plan(plan_names, choice or "")
    
    selected_plan = plans[selected_plan_name]
    
    base_name = args.base_name
    if base_name is None:
        base_name = get_input("Base name for disks")
    if not base_name:
        print("Error: Base name is required.")
        sys.exit(1)
        
    dest_dir = args.destination
    if not dest_dir:
        dest_dir = get_input("Destination directory for disk folders")
    
    if not dest_dir:
        print("Error: Destination directory is required.")
        sys.exit(1)

    dest_dir = os.path.expanduser(dest_dir)
    if not args.dry_run and not os.path.exists(dest_dir):
        os.makedirs(dest_dir, exist_ok=True)

    print(f"\nApplying plan: {selected_plan_name}")
    if args.dry_run:
        print("--- DRY RUN MODE ---")

    total_disks = len(selected_plan)
    for disk in selected_plan:
        if args.disk_number_with_total:
            disk_label = f"-Disk{disk['number']}of{total_disks}"
        elif total_disks > 1 or args.include_disk_number:
            disk_label = f"-Disk{disk['number']}"
        else:
            disk_label = ""
        can_add_label = f"-CanAdd{disk['unused_capacity']}" if args.include_can_add else ""
        disk_folder_name = f"{base_name}{disk_label}-{disk['capacity']}{can_add_label}"
        disk_path = os.path.join(dest_dir, disk_folder_name)
        
        print(f"\nProcessing {disk_folder_name}...")
        
        for src_path in disk.get('files', []):
            if args.item_type == "folders" and not validate_folder_item(src_path, target_dir):
                print(f"  Error: Source is not a first-level folder of {target_dir}: {src_path}")
                continue
            rel_path = source_path_to_relative(src_path, target_dir)
            final_dest_path = os.path.join(disk_path, rel_path)
            dest_parent = os.path.dirname(final_dest_path)
            
            if args.dry_run:
                print(f"  [DRY-RUN] Move: {src_path} -> {final_dest_path}")
            else:
                if not os.path.exists(src_path):
                    print(f"  Error: Source file not found: {src_path}")
                    continue
                
                try:
                    os.makedirs(dest_parent, exist_ok=True)
                    shutil.move(src_path, final_dest_path)
                    print(f"  Moved: {rel_path}")
                except Exception as e:
                    print(f"  Error moving {src_path}: {e}")

    print("\nTask completed.")

if __name__ == "__main__":
    main()
