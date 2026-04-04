#!/usr/bin/env bash
set -euo pipefail

start_dir="${PWD}"
out_dir=""
out_dir_set=false

usage() {
  cat <<'USAGE'
Usage: report-basename-collisions.sh [--target-dir DIR] [--output-dir DIR]

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
      start_dir="$2"
      shift 2
      ;;
    --output-dir|--log-dir)
      out_dir="$2"
      out_dir_set=true
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

start_dir="$(cd -- "$start_dir" && pwd)"
if [[ "${out_dir_set}" == false ]]; then
  out_dir="${start_dir}/.archival-prep"
fi
mkdir -p -- "${out_dir}"
out_dir="$(cd -- "${out_dir}" && pwd)"
out_file="${out_dir}/basename-collisions.txt"

script_name="$(basename "$0")"
report_date_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Track every discovered file path by basename (minus the final extension segment).
declare -A grouped_paths=()
declare -A grouped_counts=()

while IFS= read -r -d '' file_path; do
  if [[ "${file_path}" == "${out_file}" || "${file_path}" == "${out_dir}/"* ]]; then
    continue
  fi

  file_name="${file_path##*/}"
  base_name="${file_name%.*}"

  # If there is no extension, keep the entire filename as the basename key.
  if [[ "${file_name}" == "${base_name}" || -z "${base_name}" ]]; then
    base_name="${file_name}"
  fi

  grouped_paths["${base_name}"]+="${file_path}"$'\n'
  grouped_counts["${base_name}"]=$(( ${grouped_counts["${base_name}"]:-0} + 1 ))
done < <(find "${start_dir}" \( -path "${out_dir}" -o -path "${out_dir}/*" \) -prune -o -type f -print0)

{
  printf '# Script: %s\n' "${script_name}"
  printf '# Report date (UTC): %s\n' "${report_date_utc}"
  printf '# Reporting on: %s\n' "${start_dir}"
  printf '# Subject: basename collisions (same filename stem with 2+ files)\n\n'

  mapfile -t keys < <(printf '%s\n' "${!grouped_counts[@]}" | LC_ALL=C sort)

  first_group=true
  for key in "${keys[@]}"; do
    if (( grouped_counts["${key}"] < 2 )); then
      continue
    fi

    if [[ "${first_group}" == false ]]; then
      printf '\n'
    fi
    first_group=false

    printf '[%s]\n' "${key}"

    mapfile -t paths < <(printf '%s' "${grouped_paths["${key}"]}" | sed '/^$/d' | LC_ALL=C sort)
    for path in "${paths[@]}"; do
      printf '%s\n' "${path}"
    done
  done
} > "${out_file}"

echo "Wrote basename collision report to: ${out_file}"
