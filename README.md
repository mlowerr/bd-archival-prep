# bd-archival-prep-windows

A collection of utilities designed to optimize the preparation of data for cold storage, with a specific focus on staging files for high-capacity recordable Blu-ray media.

## Duration reporting scripts

This repository now includes cross-platform scripts that scan the **current invocation directory** recursively, extract media durations, and write deterministic reports to `.archival-prep/`.

- Unix: `scripts/unix/report-file-durations.sh`
- Windows PowerShell: `scripts/windows/report-file-durations.ps1`

### Output files (overwritten on every run)

Both scripts produce:

1. `.archival-prep/file-durations.txt`
   - Format: `[full path] | [duration]`
   - Sorted deterministically by full path.
2. `.archival-prep/possible-duplicates-by-duration.txt`
   - Groups only durations with **2+ files**.
   - Group format:
     - `POSSIBLE DUPLICATE [#] - Duration: [duration]`
     - followed by each matching full path.
   - Durations are normalized to the nearest second.

## Dependencies and checks

### Required tool: `ffprobe`

Both scripts use `ffprobe` (from FFmpeg) for duration extraction.

- Unix script behavior:
  - Checks `ffprobe` availability via `command -v ffprobe`.
  - Fails with an actionable install message if missing.
- PowerShell script behavior:
  - Checks `ffprobe` availability via `Get-Command ffprobe`.
  - If missing, exits gracefully with install guidance.

### Installation notes

- macOS (Homebrew):
  - `brew install ffmpeg`
- Ubuntu/Debian:
  - `sudo apt-get update && sudo apt-get install -y ffmpeg`
- Windows (winget):
  - `winget install Gyan.FFmpeg`

After installation, confirm:

- Unix/macOS: `ffprobe -version`
- PowerShell: `ffprobe -version`

## Usage

From the directory you want to analyze:

- Unix/macOS:
  - `bash /path/to/repo/scripts/unix/report-file-durations.sh`
- Windows PowerShell:
  - `powershell -ExecutionPolicy Bypass -File C:\path\to\repo\scripts\windows\report-file-durations.ps1`

The scripts only include files where a duration can be extracted.
## Basename collision reports

Generate a report of files that share the same basename (filename with only the last extension removed, such as `name.part.ext` -> `name.part`) from the current directory tree.

### Unix shell

```bash
# Run from the directory you want to scan.
/path/to/repo/scripts/unix/report-basename-collisions.sh

# Then inspect the output report.
cat .archival-prep/basename-collisions.txt
```

### PowerShell

```powershell
# Run from the directory you want to scan.
& "C:\path\to\repo\scripts\windows\report-basename-collisions.ps1"

# Then inspect the output report.
Get-Content .archival-prep\basename-collisions.txt
```
# bd-archival-prep

Utilities to analyze first-level folders in a working directory and generate packing recommendations for archival Blu-ray media.

## What the scripts do

Both scripts:

1. Use the invocation directory as the scan root.
2. Ensure `<invocation_dir>/.archival-prep` exists.
3. Overwrite outputs on every run.
4. Enumerate only first-level directories under the invocation directory.
5. Compute each candidate folder's total size and emit full path + size in GB.
6. Compute recommendations for:
   - 46.4 GB usable (50 GB Blu-ray)
   - 93.1 GB usable (100 GB Blu-ray)
7. Use subset-search with pruning to maximize used space without exceeding the target.
8. Write outputs to:
   - `.archival-prep/folder-sizes.txt`
   - `.archival-prep/blu-ray-recommendations.txt`

## Scripts

- Unix shell: `scripts/unix/folder-size-recommendations.sh`
- PowerShell: `scripts/windows/folder-size-recommendations.ps1`

## Usage

### Unix / Linux / macOS (bash)

From the directory you want to analyze:

```bash
/path/to/repo/scripts/unix/folder-size-recommendations.sh
```

Or from repo root:

```bash
./scripts/unix/folder-size-recommendations.sh
```

### Windows PowerShell

From the directory you want to analyze:

```powershell
& "C:\path\to\repo\scripts\windows\folder-size-recommendations.ps1"
```

Or from repo root:

```powershell
.\scripts\windows\folder-size-recommendations.ps1
```

## Output format

Recommendations are emitted in this exact header format:

```text
[Size in GB] Blu Ray Disk [# of recommendation] | Size used: [Sum of GB used] | Unused space: [amount + unit]
```

Each header is followed by one line per included folder (full path).

## Assumptions

- "GB" values are computed as GiB-style conversion from bytes/kilobytes (`1024^3` bytes).
- Folder sizes include nested files and directories for each first-level directory.
- `.archival-prep` is excluded from candidates to avoid feedback loops.
- Scripts emit up to 3 best recommendations per media size target.
- If no folders fit, scripts still emit a recommendation line with `Size used: 0.000 GB`.
