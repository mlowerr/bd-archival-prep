#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly PLAN_MIXED='=== OPTIMAL MIXED DISK PLAN (50 GB marketed / 46.4 GiB + 100 GB marketed / 93.1 GiB) ==='
readonly PLAN_50='=== OPTIMAL 50 GB-ONLY DISK PLAN (46.4 GiB usable) ==='
readonly PLAN_100='=== OPTIMAL 100 GB-ONLY DISK PLAN (93.1 GiB usable) ==='

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

expand_user_path() {
  local raw_path="$1"
  case "$raw_path" in
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOME" "${raw_path#\~/}"
      ;;
    *)
      printf '%s\n' "$raw_path"
      ;;
  esac
}

strip_trailing_slashes() {
  local path="$1"
  while [[ "$path" != "/" && "$path" == */ ]]; do
    path="${path%/}"
  done
  printf '%s\n' "$path"
}

resolve_existing_file_path() {
  local raw_path="$1"
  local expanded_path
  expanded_path="$(expand_user_path "$raw_path")"
  [[ -f "$expanded_path" ]] || return 1
  printf '%s/%s\n' "$(bd_resolve_dir "$(dirname -- "$expanded_path")")" "$(basename -- "$expanded_path")"
}

normalize_destination_root() {
  local raw_path="$1"
  local expanded_path

  expanded_path="$(expand_user_path "$raw_path")"
  expanded_path="$(strip_trailing_slashes "$expanded_path")"
  [[ -n "$expanded_path" ]] || return 1

  if [[ "$expanded_path" != /* ]]; then
    expanded_path="$(strip_trailing_slashes "$(pwd)/$expanded_path")"
  fi

  printf '%s\n' "$expanded_path"
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

usage() {
  cat <<'USAGE'
Usage: apply-blu-ray-file-recommendations.sh [--recommendations-file FILE] [--destination-root DIR] [--dry-run]

Options:
  --recommendations-file FILE   Path to blu-ray-file-recommendations.txt (prompted if omitted)
  --destination-root DIR        Directory where disk folders will be created (prompted if omitted)
  --dry-run                     Show what would happen without creating folders or moving files
  -h, --help                    Show this help
USAGE
}

validate_folder_name() {
  local folder_name="$1"
  [[ -n "$folder_name" ]] || return 1
  [[ "$folder_name" != "." && "$folder_name" != ".." ]] || return 1
  [[ "$folder_name" != *"/"* ]] || return 1
}

prompt_plan_choice() {
  local choice
  while true; do
    printf 'Select the plan to execute:\n'
    printf '  1. %s\n' "$PLAN_MIXED"
    printf '  2. %s\n' "$PLAN_50"
    printf '  3. %s\n' "$PLAN_100"
    read -r -p 'Enter choice [1-3]: ' choice || die "Unable to read the selected plan."
    choice="$(trim_whitespace "$choice")"
    case "$choice" in
      1)
        SELECTED_PLAN_HEADER="$PLAN_MIXED"
        return 0
        ;;
      2)
        SELECTED_PLAN_HEADER="$PLAN_50"
        return 0
        ;;
      3)
        SELECTED_PLAN_HEADER="$PLAN_100"
        return 0
        ;;
      *)
        printf 'Invalid choice. Enter 1, 2, or 3.\n' >&2
        ;;
    esac
  done
}

prompt_base_name() {
  local base_name
  while true; do
    read -r -p 'Enter the base name for each disk folder: ' base_name || die "Unable to read the disk base name."
    base_name="$(trim_whitespace "$base_name")"
    if validate_folder_name "$base_name"; then
      BASE_NAME="$base_name"
      return 0
    fi
    printf 'Enter a non-empty folder name without slashes.\n' >&2
  done
}

prompt_recommendations_file() {
  local input_path resolved_path
  while true; do
    read -r -p 'Enter the path to blu-ray-file-recommendations.txt: ' input_path || die "Unable to read the recommendations file path."
    input_path="$(trim_whitespace "$input_path")"
    resolved_path="$(resolve_existing_file_path "$input_path" 2>/dev/null || true)"
    if [[ -n "$resolved_path" ]]; then
      RECOMMENDATIONS_FILE="$resolved_path"
      return 0
    fi
    printf 'Enter a path to an existing recommendations file.\n' >&2
  done
}

prompt_destination_root() {
  local input_path normalized_path
  while true; do
    read -r -p 'Enter the directory where disk folders should be created: ' input_path || die "Unable to read the destination root."
    input_path="$(trim_whitespace "$input_path")"
    [[ -n "$input_path" ]] || {
      printf 'Enter a destination directory path.\n' >&2
      continue
    }

    normalized_path="$(normalize_destination_root "$input_path" 2>/dev/null || true)"
    if [[ -z "$normalized_path" ]]; then
      printf 'Enter a destination directory path.\n' >&2
      continue
    fi
    if [[ -e "$normalized_path" && ! -d "$normalized_path" ]]; then
      printf 'Destination root exists and is not a directory: %s\n' "$normalized_path" >&2
      continue
    fi

    DESTINATION_ROOT="$normalized_path"
    return 0
  done
}

source_path_to_relative() {
  local source_path="$1"
  local prefix="${SOURCE_ROOT%/}"
  local without_prefix drive_letter relative_path

  case "$source_path" in
    "$prefix"/*)
      without_prefix="${source_path#"$prefix"/}"
      ;;
    *)
      return 1
      ;;
  esac

  drive_letter="${without_prefix%%/*}"
  [[ "$drive_letter" =~ ^[[:alpha:]]$ ]] || return 1
  relative_path="${without_prefix#*/}"
  [[ -n "$relative_path" && "$relative_path" != "$without_prefix" ]] || return 1
  printf '%s\n' "$relative_path"
}

parse_recommendation_plan() {
  local report_path="$1"
  local selected_header="$2"
  local output_path="$3"
  local line current_disk_index="" current_size_used="" current_has_files=false current_disk_closed=false
  local section_found=false in_section=false expected_total="" last_disk_index=0 summary_total=""

  : > "$output_path"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == \#* ]] && continue

    if [[ "$line" == "$selected_header" ]]; then
      [[ "$section_found" == false ]] || die "Malformed selected plan in $report_path: duplicate plan header."
      section_found=true
      in_section=true
      continue
    fi

    if [[ "$line" == ===* ]]; then
      if [[ "$in_section" == true ]]; then
        break
      fi
      continue
    fi

    [[ "$in_section" == true ]] || continue

    if [[ -z "$line" ]]; then
      if [[ -n "$current_disk_index" && "$current_has_files" == false ]]; then
        die "Malformed selected plan in $report_path: disk $current_disk_index has no file entries."
      fi
      if [[ -n "$current_disk_index" && "$current_has_files" == true ]]; then
        current_disk_closed=true
      fi
      continue
    fi

    if [[ "$line" =~ ^(No\ feasible\ plan\ found|All\ items\ are\ oversized) ]]; then
      die "Selected plan in $report_path does not contain executable disk assignments."
    fi

    if [[ "$line" =~ ^Combination:\  ]] || [[ "$line" =~ ^Disk\ counts\ by\ size\ \(marketed\):\  ]] || [[ "$line" =~ ^Total\ data\ size:\  ]] || [[ "$line" =~ ^Total\ writable\ capacity:\  ]] || [[ "$line" =~ ^Total\ unused\ space:\  ]] || [[ "$line" =~ ^Packing\ strategy:\  ]]; then
      [[ -z "$current_disk_index" ]] || die "Malformed selected plan in $report_path: summary text appears after disk entries began."
      continue
    fi

    if [[ "$line" =~ ^Total\ disks:\ ([0-9]+)$ ]]; then
      [[ -z "$current_disk_index" ]] || die "Malformed selected plan in $report_path: total disks line appears after disk entries began."
      summary_total="${BASH_REMATCH[1]}"
      continue
    fi

    if [[ "$line" =~ ^Disk\ \[([0-9]+)\ of\ ([0-9]+)\]\ \[([0-9]+\.[0-9])\ GiB\]\ \|\ Size\ used:\ ([0-9]+\.[0-9]{3})\ GiB\ \|\ Unused\ space:\ ([0-9]+\.[0-9]{3})\ GiB$ ]]; then
      if [[ -n "$current_disk_index" && "$current_has_files" == false ]]; then
        die "Malformed selected plan in $report_path: disk $current_disk_index has no file entries."
      fi

      local disk_index="${BASH_REMATCH[1]}"
      local total_disks="${BASH_REMATCH[2]}"
      local size_used="${BASH_REMATCH[4]}"

      (( disk_index == last_disk_index + 1 )) || die "Malformed selected plan in $report_path: disk numbering is not sequential."
      if [[ -n "$expected_total" ]]; then
        [[ "$total_disks" == "$expected_total" ]] || die "Malformed selected plan in $report_path: disk totals do not agree."
      else
        expected_total="$total_disks"
      fi

      current_disk_index="$disk_index"
      current_size_used="$size_used"
      current_has_files=false
      current_disk_closed=false
      last_disk_index="$disk_index"
      continue
    fi

    if source_path_to_relative "$line" >/dev/null 2>&1; then
      [[ -n "$current_disk_index" ]] || die "Malformed selected plan in $report_path: file entry encountered before any disk header."
      [[ "$current_disk_closed" == false ]] || die "Malformed selected plan in $report_path: file entry appears after the disk block ended."
      current_has_files=true
      printf '%s\t%s\t%s\n' "$current_disk_index" "$current_size_used" "$line" >> "$output_path"
      continue
    fi

    die "Malformed selected plan in $report_path: unexpected line [$line]."
  done < "$report_path"

  [[ "$section_found" == true ]] || die "Selected plan header not found in $report_path."
  [[ "$last_disk_index" -gt 0 ]] || die "Selected plan in $report_path does not contain any disk assignments."
  if [[ -n "$current_disk_index" && "$current_has_files" == false ]]; then
    die "Malformed selected plan in $report_path: disk $current_disk_index has no file entries."
  fi
  [[ -z "$expected_total" || "$expected_total" == "$last_disk_index" ]] || die "Malformed selected plan in $report_path: disk count header does not match the disk entries."
  [[ -z "$summary_total" || "$summary_total" == "$last_disk_index" ]] || die "Malformed selected plan in $report_path: total disks summary does not match the disk entries."
}

folder_name_already_selected() {
  local candidate="$1"
  local current_disk_index="$2"
  local disk_index

  for disk_index in "${DISK_ORDER[@]}"; do
    [[ "$disk_index" == "$current_disk_index" ]] && continue
    [[ "${DISK_FOLDER_NAMES[$disk_index]-}" == "$candidate" ]] && return 0
  done

  return 1
}

pick_disk_folder_name() {
  local disk_index="$1"
  local default_name="$2"
  local candidate="$default_name"
  local candidate_path

  while true; do
    candidate_path="${DESTINATION_ROOT}/${candidate}"
    if [[ -e "$candidate_path" ]] || folder_name_already_selected "$candidate" "$disk_index"; then
      printf 'Destination folder already exists or is already selected: %s\n' "$candidate_path" >&2
      read -r -p "Enter a new folder name for Disk ${disk_index}: " candidate || die "Unable to read a replacement folder name."
      candidate="$(trim_whitespace "$candidate")"
      if ! validate_folder_name "$candidate"; then
        printf 'Enter a non-empty folder name without slashes.\n' >&2
        candidate="$default_name"
        continue
      fi
      continue
    fi

    DISK_FOLDER_NAMES[$disk_index]="$candidate"
    return 0
  done
}

load_disk_metadata() {
  local disk_index size_used source_path

  TOTAL_FILES=0
  DISK_ORDER=()

  while IFS=$'\t' read -r disk_index size_used source_path; do
    TOTAL_FILES=$((TOTAL_FILES + 1))
    if [[ -z "${DISK_USED_GIB[$disk_index]+x}" ]]; then
      DISK_USED_GIB[$disk_index]="$size_used"
      DISK_FILE_COUNTS[$disk_index]=0
      DISK_ORDER+=("$disk_index")
    fi
    DISK_FILE_COUNTS[$disk_index]=$((DISK_FILE_COUNTS[$disk_index] + 1))
  done < "$PLAN_DATA_FILE"

  [[ "${#DISK_ORDER[@]}" -gt 0 ]] || die "Selected plan does not contain any disk assignments."
}

choose_disk_folder_names() {
  local disk_index default_name

  for disk_index in "${DISK_ORDER[@]}"; do
    default_name="${BASE_NAME}-Disk${disk_index}-${DISK_USED_GIB[$disk_index]}GiB"
    pick_disk_folder_name "$disk_index" "$default_name"
  done
}

build_move_plan() {
  local disk_index size_used source_path relative_path destination_key
  declare -A seen_destinations=()

  : > "$MOVE_PLAN_FILE"

  while IFS=$'\t' read -r disk_index size_used source_path; do
    relative_path="$(source_path_to_relative "$source_path")" || die "Invalid source path in the selected plan: $source_path"
    destination_key="${DISK_FOLDER_NAMES[$disk_index]}/${relative_path}"

    [[ -z "${seen_destinations[$destination_key]+x}" ]] || die "Multiple source files map to the same destination path: ${DESTINATION_ROOT}/${destination_key}"
    seen_destinations[$destination_key]=1

    printf '%s\t%s\t%s\n' "$disk_index" "$source_path" "$relative_path" >> "$MOVE_PLAN_FILE"
  done < "$PLAN_DATA_FILE"
}

show_confirmation_summary() {
  local disk_index disk_dir

  printf '\nPlanned execution summary:\n'
  printf '  Plan: %s\n' "$SELECTED_PLAN_HEADER"
  printf '  Recommendations file: %s\n' "$RECOMMENDATIONS_FILE"
  printf '  Destination root: %s\n' "$DESTINATION_ROOT"
  printf '  Base name: %s\n' "$BASE_NAME"
  printf '  Mode: %s\n' "$([[ "$DRY_RUN" == true ]] && printf 'dry run' || printf 'move files')"
  printf '  Total disks: %s\n' "${#DISK_ORDER[@]}"
  printf '  Total files in plan: %s\n' "$TOTAL_FILES"
  printf '  Disk folders:\n'
  for disk_index in "${DISK_ORDER[@]}"; do
    disk_dir="${DESTINATION_ROOT}/${DISK_FOLDER_NAMES[$disk_index]}"
    printf '    Disk %s: %s (%s files)\n' "$disk_index" "$disk_dir" "${DISK_FILE_COUNTS[$disk_index]}"
  done
}

require_confirmation() {
  local confirmation
  read -r -p 'Type YES to continue: ' confirmation || die "Unable to read confirmation."
  [[ "$confirmation" == "YES" ]] || die "Aborted before moving any files."
}

prepare_disk_folders() {
  local disk_index disk_dir

  for disk_index in "${DISK_ORDER[@]}"; do
    DISK_READY[$disk_index]=0
  done

  if [[ "$DRY_RUN" == true ]]; then
    for disk_index in "${DISK_ORDER[@]}"; do
      disk_dir="${DESTINATION_ROOT}/${DISK_FOLDER_NAMES[$disk_index]}"
      printf 'DRY RUN: would create disk folder %s\n' "$disk_dir"
      DISK_READY[$disk_index]=1
    done
    return 0
  fi

  if ! mkdir -p -- "$DESTINATION_ROOT"; then
    warn "Unable to create destination root: $DESTINATION_ROOT"
    return 0
  fi
  DESTINATION_ROOT="$(bd_resolve_dir "$DESTINATION_ROOT")"

  for disk_index in "${DISK_ORDER[@]}"; do
    disk_dir="${DESTINATION_ROOT}/${DISK_FOLDER_NAMES[$disk_index]}"
    if [[ -e "$disk_dir" ]]; then
      warn "Destination folder became unavailable before processing began: $disk_dir"
      continue
    fi
    if ! mkdir -p -- "$disk_dir"; then
      warn "Unable to create destination disk folder: $disk_dir"
      continue
    fi
    DISK_READY[$disk_index]=1
  done
}

execute_move_plan() {
  local disk_index source_path relative_path disk_dir destination_path parent_dir

  SUCCESSFUL_FILES=0
  FAILED_FILES=0

  prepare_disk_folders

  while IFS=$'\t' read -r disk_index source_path relative_path; do
    disk_dir="${DESTINATION_ROOT}/${DISK_FOLDER_NAMES[$disk_index]}"
    destination_path="${disk_dir}/${relative_path}"
    parent_dir="$(dirname -- "$destination_path")"

    if [[ "${DISK_READY[$disk_index]-0}" != "1" ]]; then
      warn "Skipping $source_path because the destination disk folder is unavailable: $disk_dir"
      FAILED_FILES=$((FAILED_FILES + 1))
      continue
    fi

    if [[ ! -f "$source_path" ]]; then
      warn "Source file not found, skipping: $source_path"
      FAILED_FILES=$((FAILED_FILES + 1))
      continue
    fi

    if [[ -e "$destination_path" ]]; then
      warn "Destination file already exists, skipping: $destination_path"
      FAILED_FILES=$((FAILED_FILES + 1))
      continue
    fi

    if [[ "$DRY_RUN" == true ]]; then
      printf 'DRY RUN: would move %s -> %s\n' "$source_path" "$destination_path"
      SUCCESSFUL_FILES=$((SUCCESSFUL_FILES + 1))
      continue
    fi

    if ! mkdir -p -- "$parent_dir"; then
      warn "Unable to create destination parent directory for $source_path: $parent_dir"
      FAILED_FILES=$((FAILED_FILES + 1))
      continue
    fi

    if mv -- "$source_path" "$destination_path"; then
      SUCCESSFUL_FILES=$((SUCCESSFUL_FILES + 1))
    else
      warn "Failed to move $source_path to $destination_path"
      FAILED_FILES=$((FAILED_FILES + 1))
    fi
  done < "$MOVE_PLAN_FILE"
}

print_completion_summary() {
  if [[ "$DRY_RUN" == true ]]; then
    if [[ "$FAILED_FILES" -eq 0 ]]; then
      printf 'Dry run complete: %s file(s) would be moved into %s disk folder(s) under %s\n' "$SUCCESSFUL_FILES" "${#DISK_ORDER[@]}" "$DESTINATION_ROOT"
    else
      printf 'Dry run complete with warnings: %s file(s) would be moved into %s disk folder(s) under %s; %s file(s) would be skipped.\n' "$SUCCESSFUL_FILES" "${#DISK_ORDER[@]}" "$DESTINATION_ROOT" "$FAILED_FILES"
    fi
    return 0
  fi

  if [[ "$FAILED_FILES" -eq 0 ]]; then
    printf 'Moved %s files into %s disk folder(s) under %s\n' "$SUCCESSFUL_FILES" "${#DISK_ORDER[@]}" "$DESTINATION_ROOT"
  else
    printf 'Completed with warnings: moved %s file(s) into %s disk folder(s) under %s; %s file(s) were skipped or failed.\n' "$SUCCESSFUL_FILES" "${#DISK_ORDER[@]}" "$DESTINATION_ROOT" "$FAILED_FILES"
  fi
}

RECOMMENDATIONS_FILE=""
DESTINATION_ROOT=""
SELECTED_PLAN_HEADER=""
BASE_NAME=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recommendations-file)
      RECOMMENDATIONS_FILE="$2"
      shift 2
      ;;
    --destination-root)
      DESTINATION_ROOT="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
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

SOURCE_ROOT="$(expand_user_path "${BD_ARCHIVAL_SOURCE_ROOT:-/mnt}")"
PLAN_DATA_FILE="$(mktemp)"
MOVE_PLAN_FILE="$(mktemp)"
trap 'rm -f "${PLAN_DATA_FILE}" "${MOVE_PLAN_FILE}"' EXIT

declare -A DISK_USED_GIB=()
declare -A DISK_FILE_COUNTS=()
declare -A DISK_FOLDER_NAMES=()
declare -A DISK_READY=()
declare -a DISK_ORDER=()
TOTAL_FILES=0
SUCCESSFUL_FILES=0
FAILED_FILES=0

prompt_plan_choice
prompt_base_name

if [[ -n "$RECOMMENDATIONS_FILE" ]]; then
  raw_recommendations_file="$RECOMMENDATIONS_FILE"
  RECOMMENDATIONS_FILE="$(resolve_existing_file_path "$raw_recommendations_file" 2>/dev/null || true)"
  [[ -n "$RECOMMENDATIONS_FILE" ]] || die "Recommendations file does not exist: $raw_recommendations_file"
else
  prompt_recommendations_file
fi

if [[ -n "$DESTINATION_ROOT" ]]; then
  raw_destination_root="$DESTINATION_ROOT"
  DESTINATION_ROOT="$(normalize_destination_root "$raw_destination_root" 2>/dev/null || true)"
  [[ -n "$DESTINATION_ROOT" ]] || die "Destination root must not be empty."
  [[ ! -e "$DESTINATION_ROOT" || -d "$DESTINATION_ROOT" ]] || die "Destination root exists and is not a directory: $DESTINATION_ROOT"
else
  prompt_destination_root
fi

parse_recommendation_plan "$RECOMMENDATIONS_FILE" "$SELECTED_PLAN_HEADER" "$PLAN_DATA_FILE"
load_disk_metadata
choose_disk_folder_names
build_move_plan
show_confirmation_summary
require_confirmation
execute_move_plan
print_completion_summary
