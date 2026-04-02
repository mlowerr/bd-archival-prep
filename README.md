# bd-archival-prep

Small cross-platform utilities for preparing large directories for optical archival workflows.

This repository currently includes two report types:

1. **Blu-ray packing recommendations** for first-level folders.
2. **Basename collision reports** across a full directory tree.

All scripts run against the **current working directory** (the directory you invoke them from), and write results to:

- `.archival-prep/`

---

## Quick start

### Run Blu-ray packing recommendations

- Unix/macOS:

```bash
/path/to/repo/scripts/unix/folder-size-recommendations.sh
```

- Windows PowerShell:

```powershell
& "C:\path\to\repo\scripts\windows\folder-size-recommendations.ps1"
```

Outputs:

- `.archival-prep/folder-sizes.txt`
- `.archival-prep/blu-ray-recommendations.txt`

### Run basename collision report

- Unix/macOS:

```bash
/path/to/repo/scripts/unix/report-basename-collisions.sh
```

- Windows PowerShell:

```powershell
& "C:\path\to\repo\scripts\windows\report-basename-collisions.ps1"
```

Output:

- `.archival-prep/basename-collisions.txt`

---

## Scripts included

### Blu-ray recommendation scripts

- `scripts/unix/folder-size-recommendations.sh`
- `scripts/windows/folder-size-recommendations.ps1`

These scripts:

1. Scan only first-level directories under the invocation directory.
2. Exclude `.archival-prep` from candidate folders.
3. Compute folder sizes and write `folder-sizes.txt`.
4. Compute up to 3 best-fit combinations for each target capacity:
   - **46.4 GB** usable (50 GB disc)
   - **93.1 GB** usable (100 GB disc)
5. Write recommendations to `blu-ray-recommendations.txt`.

Recommendation header format:

```text
[Size in GB] Blu Ray Disk [# of recommendation] | Size used: [Sum of GB used] | Unused space: [amount + unit]
```

### Basename collision scripts

- `scripts/unix/report-basename-collisions.sh`
- `scripts/windows/report-basename-collisions.ps1`

These scripts:

1. Recursively scan all files under the invocation directory.
2. Group files by basename (filename with the final extension removed).
   - Example: `video.sample.mp4` and `video.sample.mkv` both map to `video.sample`.
3. Emit only groups where 2 or more files share the same basename.
4. Write the grouped output to `basename-collisions.txt`.

Group format:

```text
[basename]
/full/path/to/file1.ext
/full/path/to/file2.ext
```

---

## Behavior and assumptions

- Scripts create `.archival-prep/` if it does not already exist.
- Output files are overwritten on each run.
- Report ordering is deterministic where sorting is applied (size/path/key sorting in script logic).
- Recommendation search uses exact measured folder sizes internally, then rounds to 3 decimals only in text output.

---

## Typical workflow

1. `cd` into the directory you want to prepare.
2. Run a folder-size recommendation script (Unix or PowerShell).
3. Review `.archival-prep/blu-ray-recommendations.txt` and pick a set.
4. Run the basename collision script to catch likely duplicate/alternate encodes.
5. Review `.archival-prep/basename-collisions.txt` before final burn/staging.

---

## Troubleshooting

- **No recommendation candidates appear:**
  - Ensure the working directory contains subdirectories (not just files).
- **Recommendations show `Size used: 0.000 GB`:**
  - Every folder may exceed the disc target.
- **Collision report is empty:**
  - No duplicated basenames were found.

---
### `report-file-durations`

| Platform | Script | Purpose | Dependency check |
|---|---|---|---|
| Unix | `scripts/unix/report-file-durations.sh` | Recursively scan from the invocation directory, extract durations, and write duration + possible-duplicate reports. | `command -v ffprobe` |
| Windows PowerShell | `scripts/windows/report-file-durations.ps1` | Same behavior on Windows/PowerShell. | `Get-Command ffprobe` |

### Behavior

- Recursively enumerates files from the directory where the script is invoked.
- Uses `ffprobe` (FFmpeg) to read media duration.
- Normalizes duration to the nearest second.
- **Skips unreadable/non-extractable durations** (including empty probe output and `N/A`) so non-timed files are not misreported as `0`.
- Overwrites both output files every run in `.archival-prep/`:
  1. `file-durations.txt` in format `[full path] | [duration]`, sorted by full path.
  2. `possible-duplicates-by-duration.txt`, grouped as:
     - `POSSIBLE DUPLICATE [#] - Duration: [duration]`
     - matching full paths
     - only includes groups with 2+ matching normalized durations.

## Dependencies

### Required: FFmpeg (`ffprobe`)

Both scripts require `ffprobe` to be present on `PATH`.

- Unix script exits with an actionable error if `ffprobe` is unavailable.
- PowerShell script exits gracefully with installation guidance if `ffprobe` is unavailable.

### Install

- macOS (Homebrew): `brew install ffmpeg`
- Ubuntu/Debian: `sudo apt-get update && sudo apt-get install -y ffmpeg`
- Windows (winget): `winget install Gyan.FFmpeg`

Verify installation:

- Unix/macOS: `ffprobe -version`
- PowerShell: `ffprobe -version`

## Usage

Run from the folder you want to analyze:

- Unix/macOS: `bash /path/to/repo/scripts/unix/report-file-durations.sh`
- Windows PowerShell: `powershell -ExecutionPolicy Bypass -File C:\path\to\repo\scripts\windows\report-file-durations.ps1`
## Notes

- The tools are intentionally file-system based and do not modify your media/content.
- If you need to archive from another location, `cd` there first, then run scripts by absolute path.
