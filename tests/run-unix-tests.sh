#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
TEST_COUNT=0

cleanup() {
  rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

new_workspace() {
  mktemp -d "${TMP_ROOT}/workspace.XXXXXX"
}

assert_file_exists() {
  local path="$1"
  [[ -f "$path" ]] || fail "Expected file to exist: $path"
}

assert_contains() {
  local path="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" "$path"; then
    echo "--- $path ---" >&2
    sed -n '1,220p' "$path" >&2 || true
    fail "Expected to find [$needle] in $path"
  fi
}

assert_not_contains() {
  local path="$1"
  local needle="$2"
  if grep -Fq -- "$needle" "$path"; then
    echo "--- $path ---" >&2
    sed -n '1,220p' "$path" >&2 || true
    fail "Did not expect to find [$needle] in $path"
  fi
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local context="${3:-values differ}"
  if [[ "$expected" != "$actual" ]]; then
    echo "--- expected ---" >&2
    printf '%s\n' "$expected" >&2
    echo "--- actual ---" >&2
    printf '%s\n' "$actual" >&2
    fail "$context"
  fi
}

body_without_metadata() {
  local path="$1"
  grep -v '^#' "$path" | sed '/^$/d'
}

run_test() {
  local name="$1"
  shift
  TEST_COUNT=$((TEST_COUNT + 1))
  echo "==> [$TEST_COUNT] $name"
  "$@"
  pass "$name"
}

test_file_size_recommendations() {
  local ws target out candidates readable recommendations expected actual
  ws="$(new_workspace)"
  target="$ws/target"
  mkdir -p "$target/sub" "$target/.archival-prep"

  truncate -s 1024 "$target/a.bin"
  truncate -s 2048 "$target/b.bin"
  truncate -s 1024 "$target/sub/c.bin"
  printf 'ignore me' > "$target/.archival-prep/preexisting.txt"

  "$REPO_ROOT/scripts/unix/file-size-recommendations.sh" --target-dir "$target" >/dev/null

  out="$target/.archival-prep"
  candidates="$out/file-sizes.tsv"
  readable="$out/file-sizes.txt"
  recommendations="$out/blu-ray-file-recommendations.txt"

  assert_file_exists "$candidates"
  assert_file_exists "$readable"
  assert_file_exists "$recommendations"

  assert_contains "$candidates" "# Script: file-size-recommendations.sh"
  assert_contains "$candidates" "# Target directory: $target"
  assert_not_contains "$candidates" "$target/.archival-prep/preexisting.txt"
  assert_not_contains "$candidates" "$candidates"

  expected="$target/b.bin	2048
$target/a.bin	1024
$target/sub/c.bin	1024"
  actual="$(body_without_metadata "$candidates")"
  assert_equals "$expected" "$actual" "file-size-recommendations.tsv body mismatch"

  assert_contains "$readable" "$target/b.bin | 0.000 GiB"
  assert_contains "$recommendations" "=== OVERSIZED ==="
  assert_contains "$recommendations" "=== OPTIMAL MIXED DISK PLAN"
  assert_contains "$recommendations" "=== OPTIMAL 50 GB-ONLY DISK PLAN"
  assert_contains "$recommendations" "=== OPTIMAL 100 GB-ONLY DISK PLAN"
}

test_folder_size_recommendations() {
  local ws target out candidates readable recommendations alpha_size beta_size expected actual
  ws="$(new_workspace)"
  target="$ws/target"
  mkdir -p "$target/alpha" "$target/beta" "$target/.archival-prep"

  truncate -s 1024 "$target/alpha/a.bin"
  truncate -s 2048 "$target/beta/b.bin"
  printf 'ignore me' > "$target/.archival-prep/preexisting.txt"

  "$REPO_ROOT/scripts/unix/folder-size-recommendations.sh" --target-dir "$target" >/dev/null

  out="$target/.archival-prep"
  candidates="$out/folder-sizes.tsv"
  readable="$out/folder-sizes.txt"
  recommendations="$out/blu-ray-recommendations.txt"

  assert_file_exists "$candidates"
  assert_file_exists "$readable"
  assert_file_exists "$recommendations"

  assert_contains "$candidates" "# Script: folder-size-recommendations.sh"
  assert_contains "$candidates" "# Target directory: $target"
  assert_not_contains "$candidates" "$target/.archival-prep"

  alpha_size="$(du -sb "$target/alpha" | awk 'NR==1 {print $1}')"
  beta_size="$(du -sb "$target/beta" | awk 'NR==1 {print $1}')"
  expected="$target/beta	$beta_size
$target/alpha	$alpha_size"
  actual="$(body_without_metadata "$candidates")"
  assert_equals "$expected" "$actual" "folder-size-recommendations.tsv body mismatch"

  assert_contains "$recommendations" "=== OVERSIZED ==="
  assert_contains "$recommendations" "=== OPTIMAL MIXED DISK PLAN"
  assert_contains "$recommendations" "Disk counts by size (marketed):"
}

test_report_basename_collisions() {
  local ws target out report
  ws="$(new_workspace)"
  target="$ws/target"
  mkdir -p "$target/one" "$target/two" "$target/.archival-prep"

  : > "$target/one/shared.mp4"
  : > "$target/two/shared.mkv"
  : > "$target/one/noext"
  : > "$target/two/noext"
  : > "$target/one/lonely.txt"
  : > "$target/.archival-prep/generated.txt"

  "$REPO_ROOT/scripts/unix/report-basename-collisions.sh" --target-dir "$target" >/dev/null

  out="$target/.archival-prep"
  report="$out/basename-collisions.txt"
  assert_file_exists "$report"

  assert_contains "$report" "# Script: report-basename-collisions.sh"
  assert_contains "$report" "# Reporting on: $target"
  assert_contains "$report" "[noext]"
  assert_contains "$report" "$target/one/noext"
  assert_contains "$report" "$target/two/noext"
  assert_contains "$report" "[shared]"
  assert_contains "$report" "$target/one/shared.mp4"
  assert_contains "$report" "$target/two/shared.mkv"
  assert_not_contains "$report" "lonely"
  assert_not_contains "$report" "$target/.archival-prep/generated.txt"

  local groups
  groups="$(grep '^\[' "$report")"
  assert_equals $'[noext]\n[shared]' "$groups" "basename collision groups should be sorted by basename"
}

test_report_file_durations() {
  local ws target fakebin out durations duplicates expected_numeric actual_numeric expected_missing actual_missing
  ws="$(new_workspace)"
  target="$ws/target"
  fakebin="$ws/fakebin"
  mkdir -p "$target/media" "$target/.archival-prep" "$fakebin"

  cat > "$fakebin/ffprobe" <<'EOF'
#!/usr/bin/env bash
file_path="${@: -1}"
case "$(basename "$file_path")" in
  dup-a.mp4) printf '12.4\n' ;;
  dup-b.mkv) printf '12.49\n' ;;
  round-up.mov) printf '10.5\n' ;;
  bad.mp4) printf 'N/A\n' ;;
  empty.mp4) printf '' ;;
  fail.mp4) exit 1 ;;
  *) printf '1\n' ;;
esac
EOF
  chmod +x "$fakebin/ffprobe"

  : > "$target/media/dup-a.mp4"
  : > "$target/media/dup-b.mkv"
  : > "$target/media/round-up.mov"
  : > "$target/media/bad.mp4"
  : > "$target/media/empty.mp4"
  : > "$target/media/fail.mp4"
  : > "$target/.archival-prep/skip.mp4"

  PATH="$fakebin:$PATH" "$REPO_ROOT/scripts/unix/report-file-durations.sh" --target-dir "$target" --jobs 2 >/dev/null

  out="$target/.archival-prep"
  durations="$out/file-durations.txt"
  duplicates="$out/possible-duplicates-by-duration.txt"

  assert_file_exists "$durations"
  assert_file_exists "$duplicates"

  assert_contains "$durations" "# Script: report-file-durations.sh"
  assert_contains "$durations" "# Reporting on: $target"
  assert_contains "$durations" "=== FILES WITH NO READABLE DURATION ==="
  assert_not_contains "$durations" "$target/.archival-prep/skip.mp4"

  expected_numeric="$target/media/dup-a.mp4 | 12
$target/media/dup-b.mkv | 12
$target/media/round-up.mov | 11"
  actual_numeric="$(awk '
    /^=== FILES WITH NO READABLE DURATION ===$/ {exit}
    /^#/ || /^$/ {next}
    {print}
  ' "$durations")"
  assert_equals "$expected_numeric" "$actual_numeric" "numeric duration rows mismatch"

  expected_missing="$target/media/bad.mp4
$target/media/empty.mp4
$target/media/fail.mp4"
  actual_missing="$(awk '
    /^=== FILES WITH NO READABLE DURATION ===$/ {found=1; next}
    found && !/^$/ {print}
  ' "$durations")"
  assert_equals "$expected_missing" "$actual_missing" "missing duration rows mismatch"

  assert_contains "$duplicates" "POSSIBLE DUPLICATE [1] - Duration: 12"
  assert_contains "$duplicates" "$target/media/dup-a.mp4"
  assert_contains "$duplicates" "$target/media/dup-b.mkv"
  assert_not_contains "$duplicates" "round-up.mov"
}

run_test "file-size-recommendations.sh generates deterministic reports" test_file_size_recommendations
run_test "folder-size-recommendations.sh generates deterministic reports" test_folder_size_recommendations
run_test "report-basename-collisions.sh reports sorted collision groups" test_report_basename_collisions
run_test "report-file-durations.sh handles numeric and unreadable durations" test_report_file_durations

echo "All ${TEST_COUNT} Unix script tests passed."
