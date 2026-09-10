#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
APPLY_SCRIPT="${PROJECT_ROOT}/scripts/unix/apply-disk-plan.py"

# Create a temporary test directory
TEST_DIR=$(mktemp -d)
trap 'rm -rf "${TEST_DIR}"' EXIT

cd "${TEST_DIR}"

# Create mock source files using absolute paths for the purpose of the script
# In the test, we'll simulate the root being TEST_DIR
mkdir -p "${TEST_DIR}/mnt/d/Pearl Jam"
mkdir -p "${TEST_DIR}/mnt/d/Grateful Dead"
mkdir -p "${TEST_DIR}/mnt/z/Phish"

touch "${TEST_DIR}/mnt/d/Pearl Jam/2024-05-10-Seattle.mp4"
touch "${TEST_DIR}/mnt/d/Grateful Dead/1977-05-08-Cornell.mkv"
touch "${TEST_DIR}/mnt/z/Phish/2023-12-31-MSG.mov"

# Create mock recommendation file with paths relative to TEST_DIR
cat <<EOF > recommendations.txt
# Target directory: ${TEST_DIR}

=== OPTIMAL MIXED DISK PLAN (50 GB marketed / 46.5 GiB + 100 GB marketed / 93.1 GiB) ===
Disk [1 of 1] [93.1 GiB] | Size used: 93.085 GiB | Unused space: 0.015 GiB
${TEST_DIR}/mnt/d/Pearl Jam/2024-05-10-Seattle.mp4
${TEST_DIR}/mnt/d/Grateful Dead/1977-05-08-Cornell.mkv
${TEST_DIR}/mnt/z/Phish/2023-12-31-MSG.mov

=== OPTIMAL 50 GB-ONLY DISK PLAN (46.5 GiB usable) ===
Disk [1 of 2] [46.5 GiB] | Size used: 40.000 GiB | Unused space: 6.500 GiB
${TEST_DIR}/mnt/d/Pearl Jam/2024-05-10-Seattle.mp4
Disk [2 of 2] [46.5 GiB] | Size used: 10.000 GiB | Unused space: 36.500 GiB
${TEST_DIR}/mnt/d/Grateful Dead/1977-05-08-Cornell.mkv

=== OPTIMAL 100 GB-ONLY DISK PLAN (93.1 GiB usable) ===
Disk [1 of 1] [93.1 GiB] | Size used: 20.000 GiB | Unused space: 73.100 GiB
EOF

assert_contains() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" == *"$needle"* ]] || { echo "Expected output to contain: $needle" >&2; exit 1; }
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" != *"$needle"* ]] || { echo "Expected output not to contain: $needle" >&2; exit 1; }
}

echo "--- Testing optional plan and base-name inputs ---"
output=$(printf "output\n" | python3 "${APPLY_SCRIPT}" --recommendations recommendations.txt --disk-size mixed --base-name TEST --dry-run)
assert_not_contains "$output" "Select a plan"
assert_not_contains "$output" "Base name for disks"

output=$(printf "output\n" | python3 "${APPLY_SCRIPT}" --recommendations recommendations.txt --disk-size 50 --base-name TEST --dry-run)
assert_contains "$output" "Applying plan: OPTIMAL 50 GB-ONLY DISK PLAN"

output=$(printf "output\n" | python3 "${APPLY_SCRIPT}" --recommendations recommendations.txt --disk-size 100 --base-name TEST --dry-run)
assert_contains "$output" "Applying plan: OPTIMAL 100 GB-ONLY DISK PLAN"

output=$(printf "TEST\noutput\n" | python3 "${APPLY_SCRIPT}" --recommendations recommendations.txt --disk-size 1 --dry-run)
assert_not_contains "$output" "Select a plan"
assert_contains "$output" "Base name for disks"

output=$(printf "1\noutput\n" | python3 "${APPLY_SCRIPT}" --recommendations recommendations.txt --base-name TEST --dry-run)
assert_contains "$output" "Select a plan"
assert_not_contains "$output" "Base name for disks"

output=$(printf "1\nTEST\noutput\n" | python3 "${APPLY_SCRIPT}" --recommendations recommendations.txt --dry-run)
assert_contains "$output" "Select a plan"
assert_contains "$output" "Base name for disks"

if output=$(printf "output\n" | python3 "${APPLY_SCRIPT}" --recommendations recommendations.txt --disk-size dvd --base-name TEST --dry-run 2>&1); then
    echo "FAILURE: invalid disk size should fail" >&2
    exit 1
fi
assert_contains "$output" "Disk size/plan value 'dvd' is invalid"
assert_contains "$output" "Accepted choices: 1 (OPTIMAL MIXED DISK PLAN"

output=$(printf "output\n" | python3 "${APPLY_SCRIPT}" --recommendations recommendations.txt --disk-size 1 --base-name "Archive Set #1" --dry-run)
assert_contains "$output" "Processing Archive Set #1-93.085GiB"
assert_not_contains "$output" "Archive Set #1-Disk1-"

output=$(printf "output\n" | python3 "${APPLY_SCRIPT}" --recommendations recommendations.txt --disk-size 1 --base-name TEST --include-disk-number --dry-run)
assert_contains "$output" "Processing TEST-Disk1-93.085GiB"

output=$(printf "output\n" | python3 "${APPLY_SCRIPT}" --recommendations recommendations.txt --disk-size 50 --base-name TEST --dry-run)
assert_contains "$output" "Processing TEST-Disk1-40.000GiB"

output=$(printf "output\n" | python3 "${APPLY_SCRIPT}" --recommendations recommendations.txt --disk-size 50 --base-name TEST --disk-number-with-total --dry-run)
assert_contains "$output" "Processing TEST-Disk1of2-40.000GiB"
assert_contains "$output" "Processing TEST-Disk2of2-10.000GiB"

output=$(printf "output\n" | python3 "${APPLY_SCRIPT}" --recommendations recommendations.txt --disk-size 1 --base-name TEST --disk-number-with-total --dry-run)
assert_contains "$output" "Processing TEST-Disk1of1-93.085GiB"

echo "--- Testing plan_and_move shell argument construction ---"
grep -Fq 'UNIX_SCRIPT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"' "${PROJECT_ROOT}/scripts/unix/lib/plan_and_move.sh"
grep -Fq 'apply_args+=(--disk-size "$2")' "${PROJECT_ROOT}/scripts/unix/lib/plan_and_move.sh"
grep -Fq 'apply_args+=(--base-name "$2")' "${PROJECT_ROOT}/scripts/unix/lib/plan_and_move.sh"
grep -Fq -- '--include-disk-number|--disk-number-with-total)' "${PROJECT_ROOT}/scripts/unix/lib/plan_and_move.sh"
grep -Fq '"${apply_args[@]}"' "${PROJECT_ROOT}/scripts/unix/lib/plan_and_move.sh"

echo "--- Testing conflicting driver naming options fail before report generation ---"
for driver in plan_and_move.sh plan_and_move_folders.sh; do
    conflict_dir="${TEST_DIR}/conflict-${driver}"
    mkdir "$conflict_dir"
    if output=$(cd "$conflict_dir" && "${PROJECT_ROOT}/scripts/unix/lib/${driver}" --include-disk-number --disk-number-with-total 2>&1); then
        echo "FAILURE: ${driver} should reject conflicting naming options" >&2
        exit 1
    fi
    assert_contains "$output" "cannot be used together"
    [[ ! -e "${conflict_dir}/.archival-prep" ]] || {
        echo "FAILURE: ${driver} generated reports before rejecting conflicting options" >&2
        exit 1
    }
done

echo "--- Testing folder-level plan application ---"
mkdir -p "${TEST_DIR}/folder-source/Alpha/nested" "${TEST_DIR}/folder-source/Beta"
touch "${TEST_DIR}/folder-source/Alpha/nested/one.mov" "${TEST_DIR}/folder-source/Beta/two.mov"
cat <<EOF > folder-recommendations.txt
# Target directory: ${TEST_DIR}/folder-source

=== OPTIMAL MIXED DISK PLAN (50 GB marketed / 46.5 GiB + 100 GB marketed / 93.1 GiB) ===
Disk [1 of 1] [93.1 GiB] | Size used: 1.000 GiB | Unused space: 92.100 GiB
${TEST_DIR}/folder-source/Alpha
${TEST_DIR}/folder-source/Beta
EOF
mkdir folder-output
python3 "${APPLY_SCRIPT}" --recommendations folder-recommendations.txt --destination folder-output --disk-size mixed --base-name FOLDERS --item-type folders
[[ -f folder-output/FOLDERS-1.000GiB/Alpha/nested/one.mov ]]
[[ -f folder-output/FOLDERS-1.000GiB/Beta/two.mov ]]
[[ ! -e "${TEST_DIR}/folder-source/Alpha" ]]
grep -Fq -- '--item-type folders' "${PROJECT_ROOT}/scripts/unix/lib/plan_and_move_folders.sh"
grep -Fq '"${UNIX_SCRIPT_DIR}/folder-size-recommendations.sh"' "${PROJECT_ROOT}/scripts/unix/lib/plan_and_move_folders.sh"

echo "--- Testing Real Move ---"
mkdir output
printf "output\n" | python3 "${APPLY_SCRIPT}" --recommendations recommendations.txt --disk-size mixed --base-name TEST

# Verify results
echo "--- Verifying Results ---"
if [ -f "output/TEST-93.085GiB/mnt/d/Pearl Jam/2024-05-10-Seattle.mp4" ]; then
    echo "SUCCESS: Pearl Jam/2024-05-10-Seattle.mp4 moved correctly"
else
    echo "FAILURE: Pearl Jam/2024-05-10-Seattle.mp4 NOT found"
    exit 1
fi

if [ -f "output/TEST-93.085GiB/mnt/d/Grateful Dead/1977-05-08-Cornell.mkv" ]; then
    echo "SUCCESS: Grateful Dead/1977-05-08-Cornell.mkv moved correctly"
else
    echo "FAILURE: Grateful Dead/1977-05-08-Cornell.mkv NOT found"
    exit 1
fi

if [ -f "output/TEST-93.085GiB/mnt/z/Phish/2023-12-31-MSG.mov" ]; then
    echo "SUCCESS: Phish/2023-12-31-MSG.mov moved correctly"
else
    echo "FAILURE: Phish/2023-12-31-MSG.mov NOT found"
    exit 1
fi

# Check that original files are gone
if [ ! -f "${TEST_DIR}/mnt/d/Pearl Jam/2024-05-10-Seattle.mp4" ]; then
    echo "SUCCESS: Original file removed"
else
    echo "FAILURE: Original file still exists: ${TEST_DIR}/mnt/d/Pearl Jam/2024-05-10-Seattle.mp4"
    exit 1
fi

echo "--- Testing Malformed File ---"
cat <<EOF > malformed.txt
Some random text that is not a plan
Disk [1 of 1] but missing header
/mnt/d/file.mp4
EOF
if python3 "${APPLY_SCRIPT}" --recommendations malformed.txt --destination output <<EOF
1
TEST
EOF
then
    echo "FAILURE: Script should have failed on malformed file"
    exit 1
else
    echo "SUCCESS: Script failed as expected on malformed file"
fi

echo "All tests passed!"
