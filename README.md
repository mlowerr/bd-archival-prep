# bd-archival-prep

Cross-platform scripts for preparing large directories for optical archival workflows.

## What this repo contains

This repo provides three script sets, each with Unix and Windows PowerShell versions:

1. **Blu-ray packing recommendations** (first-level folder packing).
2. **Basename collision report** (same filename stem across files).
3. **File duration reports** (all probed durations + possible duplicates by duration).

All scripts run against the **current working directory** (the directory where you invoke the script) and write output files under:

- `.archival-prep/`

## Quick start

Run from the directory you want to analyze:

### Unix/macOS

```bash
/path/to/repo/scripts/unix/folder-size-recommendations.sh
/path/to/repo/scripts/unix/report-basename-collisions.sh
/path/to/repo/scripts/unix/report-file-durations.sh
```

### Windows PowerShell

```powershell
& "C:\path\to\repo\scripts\windows\folder-size-recommendations.ps1"
& "C:\path\to\repo\scripts\windows\report-basename-collisions.ps1"
& "C:\path\to\repo\scripts\windows\report-file-durations.ps1"
```

## Script sets

### 1) Blu-ray packing recommendations

**Scripts**
- `scripts/unix/folder-size-recommendations.sh`
- `scripts/windows/folder-size-recommendations.ps1`

**Outputs**
- `.archival-prep/folder-sizes.txt`
- `.archival-prep/blu-ray-recommendations.txt`
- `.archival-prep/folder-sizes.tsv` (Unix script intermediate candidate data)

**Behavior**
- Scans only first-level directories under the invocation directory.
- Excludes `.archival-prep` from candidates.
- Builds complete packing plans (all candidate directories assigned) for:
  - **Mixed disk sizes** (both `46.4 GB` and `93.1 GB` usable capacities allowed).
  - **50 GB only** (`46.4 GB` usable capacity only).
  - **100 GB only** (`93.1 GB` usable capacity only).
- Optimizes for minimum total disk count first, then minimum total unused space.
- Overwrites outputs each run.

**Recommendation report format**

```text
=== OPTIMAL MIXED DISK PLAN (50GB + 100GB) ===
Combination: [#] x 93.1 GB + [#] x 46.4 GB
Total disks: [count]
Disk counts by size: 100GB=[#], 50GB=[#]
...

=== OPTIMAL 50GB-ONLY DISK PLAN ===
...

=== OPTIMAL 100GB-ONLY DISK PLAN ===
...
```

### 2) Basename collision report

**Scripts**
- `scripts/unix/report-basename-collisions.sh`
- `scripts/windows/report-basename-collisions.ps1`

**Output**
- `.archival-prep/basename-collisions.txt`

**Behavior**
- Recursively scans files under the invocation directory.
- Groups by basename (`filename` without the final extension).
  - Example: `video.sample.mp4` and `video.sample.mkv` both map to `video.sample`.
- Emits only groups with 2+ files.
- Overwrites output each run.

**Group format**

```text
[basename]
/full/path/to/file1.ext
/full/path/to/file2.ext
```

### 3) File duration reports

**Scripts**
- `scripts/unix/report-file-durations.sh`
- `scripts/windows/report-file-durations.ps1`

**Dependency**
- `ffprobe` (from FFmpeg) must be on `PATH`.

**Outputs**
- `.archival-prep/file-durations.txt`
- `.archival-prep/possible-duplicates-by-duration.txt`

**Behavior**
- Recursively scans files under the invocation directory.
- Excludes `.archival-prep` from scanning to avoid probing generated report files.
- Uses `ffprobe` to read duration.
- Normalizes duration to nearest second.
- Skips files with unreadable/non-timed durations (including empty probe output and `N/A`).
- Overwrites outputs each run.

**Output formats**
- `file-durations.txt`: `[full path] | [duration]`
- `possible-duplicates-by-duration.txt` groups:
  - `POSSIBLE DUPLICATE [#] - Duration: [duration]`
  - matching full paths
  - only groups with 2+ files

## Dependencies

### Required only for duration scripts: FFmpeg (`ffprobe`)

Install examples:
- macOS (Homebrew): `brew install ffmpeg`
- Ubuntu/Debian: `sudo apt-get update && sudo apt-get install -y ffmpeg`
- Windows (winget): `winget install Gyan.FFmpeg`

Verify:
- Unix/macOS: `ffprobe -version`
- PowerShell: `ffprobe -version`

## Typical workflow

1. `cd` into the directory you want to prepare.
2. Run `folder-size-recommendations` and choose a packing option.
3. Run `report-basename-collisions` to find likely filename-stem collisions.
4. Run `report-file-durations` to find possible duration-based duplicates.
5. Review `.archival-prep/` outputs before staging/burning.

## Notes

- Scripts create `.archival-prep/` automatically when needed.
- Reports are deterministic where sorting is applied in script logic.
- Scripts are read-only with respect to your source media/content.
