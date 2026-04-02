#!/usr/bin/env bash
set -euo pipefail

start_dir="${PWD}"
out_dir="${start_dir}/.archival-prep"
out_file="${out_dir}/basename-collisions.txt"

mkdir -p -- "${out_dir}"

# Track every discovered file path by basename (minus the final extension segment).
declare -A grouped_paths=()
declare -A grouped_counts=()

while IFS= read -r -d '' file_path; do
  if [[ "${file_path}" == "${out_file}" ]]; then
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
done < <(find "${start_dir}" -type f -print0)

{
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
