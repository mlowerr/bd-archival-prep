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
=== OPTIMAL MIXED DISK PLAN (50 GB marketed / 46.4 GiB + 100 GB marketed / 93.1 GiB) ===
Disk [1 of 1] [93.1 GiB] | Size used: 93.085 GiB | Unused space: 0.015 GiB
${TEST_DIR}/mnt/d/Pearl Jam/2024-05-10-Seattle.mp4
${TEST_DIR}/mnt/d/Grateful Dead/1977-05-08-Cornell.mkv
${TEST_DIR}/mnt/z/Phish/2023-12-31-MSG.mov

=== OPTIMAL 50 GB-ONLY DISK PLAN (46.4 GiB usable) ===
Disk [1 of 2] [46.4 GiB] | Size used: 40.000 GiB | Unused space: 6.400 GiB
${TEST_DIR}/mnt/d/Pearl Jam/2024-05-10-Seattle.mp4
EOF

echo "--- Testing Dry Run ---"
# We need to simulate user input. 
# Plan 1, Base name: TEST, Destination: output
printf "1\nTEST\noutput\n" | python3 "${APPLY_SCRIPT}" --recommendations recommendations.txt --dry-run

echo "--- Testing Real Move ---"
mkdir output
printf "1\nTEST\noutput\n" | python3 "${APPLY_SCRIPT}" --recommendations recommendations.txt

# Verify results
echo "--- Verifying Results ---"
if [ -f "output/TEST-Disk1-93.085GiB/Pearl Jam/2024-05-10-Seattle.mp4" ]; then
    echo "SUCCESS: Pearl Jam/2024-05-10-Seattle.mp4 moved correctly"
else
    echo "FAILURE: Pearl Jam/2024-05-10-Seattle.mp4 NOT found"
    exit 1
fi

if [ -f "output/TEST-Disk1-93.085GiB/Grateful Dead/1977-05-08-Cornell.mkv" ]; then
    echo "SUCCESS: Grateful Dead/1977-05-08-Cornell.mkv moved correctly"
else
    echo "FAILURE: Grateful Dead/1977-05-08-Cornell.mkv NOT found"
    exit 1
fi

if [ -f "output/TEST-Disk1-93.085GiB/Phish/2023-12-31-MSG.mov" ]; then
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
