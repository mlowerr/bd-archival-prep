#!/usr/bin/env python3
import os
import re
import shutil
import sys
import argparse

def parse_args():
    parser = argparse.ArgumentParser(description="Apply a Blu-ray disk plan by moving files into disk-specific folders.")
    parser.add_argument("--recommendations", help="Path to the recommendation file (blu-ray-file-recommendations.txt).")
    parser.add_argument("--destination", help="Base path where disk folders will be created.")
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
    
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
    except Exception as e:
        print(f"Error reading file: {e}")
        sys.exit(1)

    plan_header_pattern = re.compile(r'^=== (OPTIMAL .* PLAN .*) ===')
    disk_header_pattern = re.compile(r'^Disk \[(\d+) of \d+\] \[.*\] \| Size used: ([\d.]+) GiB \|')

    i = 0
    while i < len(lines):
        line = lines[i].strip()
        
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
                    'files': files
                })
                continue
        i += 1

    if not plans:
        print("Error: No valid plans found in the recommendation file.")
        sys.exit(1)
        
    return plans

def strip_mnt_prefix(path):
    # Search for /mnt/[drive letter]/ anywhere in the path and return what follows it.
    # If not found, return the original path.
    match = re.search(r'/mnt/[a-zA-Z]/(.*)', path)
    if match:
        return match.group(1)
    return path

def main():
    args = parse_args()

    rec_file = args.recommendations
    if not rec_file:
        rec_file = get_input("Path to recommendation file")
    
    if not rec_file or not os.path.exists(rec_file):
        print(f"Error: Valid recommendation file path required.")
        sys.exit(1)

    plans = parse_recommendation_file(rec_file)
    
    print("\nAvailable Plans:")
    plan_names = list(plans.keys())
    for idx, name in enumerate(plan_names, 1):
        print(f"{idx}. {name}")
    
    choice = get_input(f"Select a plan (1-{len(plan_names)})")
    try:
        selected_plan_name = plan_names[int(choice) - 1]
    except (ValueError, IndexError):
        print("Invalid selection.")
        sys.exit(1)
    
    selected_plan = plans[selected_plan_name]
    
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

    for disk in selected_plan:
        disk_folder_name = f"{base_name}-Disk{disk['number']}-{disk['capacity']}"
        disk_path = os.path.join(dest_dir, disk_folder_name)
        
        print(f"\nProcessing {disk_folder_name}...")
        
        for src_path in disk.get('files', []):
            rel_path = strip_mnt_prefix(src_path)
            # Ensure rel_path doesn't start with / for os.path.join to work as expected
            if rel_path.startswith('/'):
                rel_path = rel_path.lstrip('/')
                
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
