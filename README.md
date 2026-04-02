# bd-archival-prep-windows

A collection of utilities designed to optimize the preparation of data for cold storage, with a specific focus on staging files for high-capacity recordable Blu-ray media.

## Scripts

### `report-file-durations`

| Platform | Script | Purpose | Dependency check |
|---|---|---|---|
| Unix | `scripts/unix/report-file-durations.sh` | Recursively scan from the invocation directory, extract durations, and write duration + possible-duplicate reports. | `command -v ffprobe` |
| Windows PowerShell | `scripts/windows/report-file-durations.ps1` | Same behavior on Windows/PowerShell. | `Get-Command ffprobe` |

### Behavior

- Recursively enumerates files from the directory where the script is invoked.
- Uses `ffprobe` (FFmpeg) to read media duration.
- Normalizes duration to the nearest second.
- **Skips non-numeric values** (including `N/A`) so non-timed files are not misreported as `0`.
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
