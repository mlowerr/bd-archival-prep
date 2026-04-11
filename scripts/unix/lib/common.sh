#!/usr/bin/env bash

bd_resolve_dir() {
  cd -- "$1" && pwd
}

bd_init_report_env() {
  local script_path="$1"
  local target_dir="$2"
  local output_dir="$3"
  local output_dir_set="$4"

  INVOCATION_DIR="$(bd_resolve_dir "$target_dir")"
  if [[ "$output_dir_set" == false ]]; then
    output_dir="${INVOCATION_DIR}/.archival-prep"
  fi

  mkdir -p -- "$output_dir"
  OUTPUT_DIR="$(bd_resolve_dir "$output_dir")"
  SCRIPT_NAME="$(basename "$script_path")"
  REPORT_DATE_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}

bd_is_path_within() {
  local parent_dir="$1"
  local child_path="$2"
  local resolved_parent="$(bd_resolve_dir "$parent_dir")"

  case "$child_path" in
    "$resolved_parent"|"$resolved_parent"/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bd_print_metadata_header() {
  local script_name="$1"
  local report_date_utc="$2"
  local location_label="$3"
  local location_value="$4"
  local subject_line="$5"

  printf '# Script: %s\n' "$script_name"
  printf '# Report date (UTC): %s\n' "$report_date_utc"
  printf '# %s: %s\n' "$location_label" "$location_value"
  printf '# Subject: %s\n\n' "$subject_line"
}

bd_write_size_reports_from_datafile() {
  local data_file="$1"
  local candidates_file="$2"
  local readable_file="$3"
  local script_name="$4"
  local report_date_utc="$5"
  local target_dir="$6"
  local candidate_subject="$7"
  local readable_subject="$8"

  {
    bd_print_metadata_header "$script_name" "$report_date_utc" "Target directory" "$target_dir" "$candidate_subject"
    cat "$data_file"
  } > "$candidates_file"

  {
    bd_print_metadata_header "$script_name" "$report_date_utc" "Target directory" "$target_dir" "$readable_subject"
    awk -F $'\t' '{ printf "%s | %.3f GiB\n", $1, $2/1073741824 }' "$data_file"
  } > "$readable_file"
}
