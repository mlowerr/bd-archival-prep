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
