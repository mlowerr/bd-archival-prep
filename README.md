# bd-archival-prep

Cross-platform scripts for preparing large directories for optical archival workflows.

## At a glance

| Need | Script (Unix) | Script (Windows PowerShell) | Main output(s) |
|---|---|---|---|
| Pack top-level folders onto 50 GB / 100 GB marketed Blu-ray media (46.4 GiB / 93.1 GiB usable) | `scripts/unix/folder-size-recommendations.sh` | `scripts/windows/folder-size-recommendations.ps1` | `folder-sizes.txt`, `blu-ray-recommendations.txt` |
| Pack individual files onto 50 GB / 100 GB marketed Blu-ray media (46.4 GiB / 93.1 GiB usable) | `scripts/unix/file-size-recommendations.sh` | `scripts/windows/file-size-recommendations.ps1` | `file-sizes.txt`, `blu-ray-file-recommendations.txt` |
| Find filename-stem collisions (`name.ext1` vs `name.ext2`) | `scripts/unix/report-basename-collisions.sh` | `scripts/windows/report-basename-collisions.ps1` | `basename-collisions.txt` |
| Report durations + flag potential duplicates by equal duration | `scripts/unix/report-file-durations.sh` | `scripts/windows/report-file-durations.ps1` | `file-durations.txt`, `possible-duplicates-by-duration.txt` |

All outputs are written to `.archival-prep/` by default.

## What this repo contains

This repo provides four script sets, each with Unix and Windows PowerShell versions:

1. **Blu-ray folder packing recommendations** (first-level folder packing).
2. **Blu-ray file packing recommendations** (recursive per-file packing).
3. **Basename collision report** (same filename stem across files).
4. **File duration reports** (all probed durations + possible duplicates by duration).

By default, all scripts run against the **current working directory** (the directory where you invoke the script) and write output files under:

- `.archival-prep/`

You can optionally override both the scan target and output location:

- Unix: `--target-dir <DIR>` and `--output-dir <DIR>` (or `--log-dir <DIR>` alias).
- PowerShell: `-TargetDir <DIR>` and `-OutputDir <DIR>`.
- Duration scripts also support worker limits:
  - Unix: `--jobs <N>` (default: `3`)
  - PowerShell: `-Jobs <int>` (default: `3`)

## Quick start

Run from the directory you want to analyze:

### Unix/macOS

```bash
/path/to/repo/scripts/unix/folder-size-recommendations.sh
/path/to/repo/scripts/unix/file-size-recommendations.sh
/path/to/repo/scripts/unix/report-basename-collisions.sh
/path/to/repo/scripts/unix/report-file-durations.sh

# Optional override example:
/path/to/repo/scripts/unix/report-file-durations.sh --target-dir /data/media --output-dir /tmp/archival-reports --jobs 6
```

### Windows PowerShell

```powershell
& "C:\path\to\repo\scripts\windows\folder-size-recommendations.ps1"
& "C:\path\to\repo\scripts\windows\file-size-recommendations.ps1"
& "C:\path\to\repo\scripts\windows\report-basename-collisions.ps1"
& "C:\path\to\repo\scripts\windows\report-file-durations.ps1"

# Optional override example:
& "C:\path\to\repo\scripts\windows\report-file-durations.ps1" -TargetDir "D:\Media" -OutputDir "D:\Reports\archival-prep" -Jobs 6
```

## CLI options

### Unix scripts

- `--target-dir <DIR>`: directory to scan (defaults to current working directory).
- `--output-dir <DIR>`: report output location (defaults to `<target>/.archival-prep`).
- `--log-dir <DIR>`: alias of `--output-dir`.
- `--jobs <N>` (duration script): max concurrent `ffprobe` workers (defaults to `3`, must be `>= 1`).
- `--help`: print script usage.

### PowerShell scripts

- `-TargetDir <DIR>`: directory to scan (defaults to current location).
- `-OutputDir <DIR>`: report output location (defaults to `<target>\.archival-prep`).
- `-Jobs <int>` (duration script): max concurrent `ffprobe` workers (defaults to `3`, must be `>= 1`).

## Script sets

### 1) Blu-ray packing recommendations

**Scripts**
- `scripts/unix/folder-size-recommendations.sh`
- `scripts/windows/folder-size-recommendations.ps1`

**Outputs**
- `.archival-prep/folder-sizes.txt`
- `.archival-prep/blu-ray-recommendations.txt`
- `.archival-prep/folder-sizes.tsv` (candidate folder data, TSV: `path<TAB>size_bytes`)

**Behavior**
- Scans only first-level directories under the target directory.
- Excludes `.archival-prep` from candidates.
- Writes `folder-sizes.tsv` in **bytes** on both Unix and Windows.
- Writes `folder-sizes.txt` in the same deterministic order as `folder-sizes.tsv` (size descending, then path ascending).
- Builds complete packing plans (all candidate directories assigned) for:
  - **Mixed disk sizes** (both `46.4 GiB` and `93.1 GiB` usable capacities allowed (marketed as 50 GB and 100 GB)).
  - **50 GB only** (`46.4 GiB` usable capacity only).
  - **100 GB only** (`93.1 GiB` usable capacity only).
- Precomputes oversized directories (`> 93.1 GiB`) and lists them in a dedicated `=== OVERSIZED ===` section in the recommendation report.
- Excludes oversized directories from all packable plan calculations.
- If every candidate directory is oversized, each plan section reports that no packable items remain.
- Optimizes for minimum total disk count first, then minimum total unused space.
- Overwrites outputs each run.

**Recommendation report format**

```text
=== OPTIMAL MIXED DISK PLAN (50 GB marketed / 46.4 GiB + 100 GB marketed / 93.1 GiB) ===
Combination: [#] x 100 GB marketed (93.1 GiB) + [#] x 50 GB marketed (46.4 GiB)
Total disks: [count]
Disk counts by size (marketed): 100GB=[#], 50GB=[#]
...

=== OPTIMAL 50 GB-ONLY DISK PLAN (46.4 GiB usable) ===
...

=== OPTIMAL 100 GB-ONLY DISK PLAN (93.1 GiB usable) ===
...
```

### 2) Blu-ray file packing recommendations

**Scripts**
- `scripts/unix/file-size-recommendations.sh`
- `scripts/windows/file-size-recommendations.ps1`

**Outputs**
- `.archival-prep/file-sizes.txt`
- `.archival-prep/blu-ray-file-recommendations.txt`
- `.archival-prep/file-sizes.tsv` (candidate file data, TSV: `path<TAB>size_bytes`)

**Behavior**
- Recursively scans files under the target directory.
- Excludes `.archival-prep` from candidates when output is inside the target directory.
- Writes `file-sizes.tsv` in **bytes** on both Unix and Windows.
- Writes `file-sizes.txt` in the same deterministic order as `file-sizes.tsv` (size descending, then path ascending).
- Builds complete packing plans (all candidate files assigned) for:
  - **Mixed disk sizes** (both `46.4 GiB` and `93.1 GiB` usable capacities allowed (marketed as 50 GB and 100 GB)).
  - **50 GB only** (`46.4 GiB` usable capacity only).
  - **100 GB only** (`93.1 GiB` usable capacity only).
- Precomputes oversized files (`> 93.1 GiB`) and lists them in a dedicated `=== OVERSIZED ===` section in the recommendation report.
- Excludes oversized files from all packable plan calculations.
- If every candidate file is oversized, each plan section reports that no packable items remain.
- Optimizes for minimum total disk count first, then minimum total unused space.
- Overwrites outputs each run.

### 3) Basename collision report

**Scripts**
- `scripts/unix/report-basename-collisions.sh`
- `scripts/windows/report-basename-collisions.ps1`

**Output**
- `.archival-prep/basename-collisions.txt`

**Behavior**
- Recursively scans files under the target directory.
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

### 4) File duration reports

**Scripts**
- `scripts/unix/report-file-durations.sh`
- `scripts/windows/report-file-durations.ps1`

**Dependency**
- `ffprobe` (from FFmpeg) must be on `PATH`.

**Outputs**
- `.archival-prep/file-durations.txt`
- `.archival-prep/possible-duplicates-by-duration.txt`

**Behavior**
- Recursively scans files under the target directory.
- Excludes `.archival-prep` from scanning to avoid probing generated report files.
- Probes each file once with `ffprobe` to read duration.
- Uses bounded parallel workers for `ffprobe` calls (`--jobs` / `-Jobs`, default `3`).
- Classifies each file as either:
  - numeric duration (normalized to nearest second), or
  - no readable duration (`ffprobe` failure, empty output, `N/A`, or non-numeric duration output).
- Writes numeric-duration rows in the main section of `file-durations.txt`.
- Appends a `=== FILES WITH NO READABLE DURATION ===` section listing files without readable durations.
- Keeps duplicate grouping numeric-only (only normalized numeric durations are considered).
- Sorts final records before writing reports to preserve deterministic output.
- Overwrites outputs each run.

**Output formats**
- `file-durations.txt`: `[full path] | [duration]`
- `possible-duplicates-by-duration.txt` groups:
  - `POSSIBLE DUPLICATE [#] - Duration: [duration]`
  - matching full paths
  - only groups with 2+ files


## Report metadata headers

Every generated output file now begins with metadata headers containing:

1. the script that created the output
2. the report date (UTC)
3. what location was reported on

## Size units and ordering conventions

- Candidate TSVs (`folder-sizes.tsv`, `file-sizes.tsv`) use raw **bytes** (`size_bytes`) across both platforms.
- Human-readable size reports (`folder-sizes.txt`, `file-sizes.txt`) show **GiB** (binary units, `1 GiB = 1024^3 bytes`) rounded to 3 decimals.
- `blu-ray-*.txt` recommendation reports also use GiB for displayed totals/capacities.
- Candidate and human-readable size report bodies are both sorted deterministically by:
  1. size descending
  2. full path ascending (tie-breaker)

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
2. Run `folder-size-recommendations` for top-level folder packing options.
3. Run `file-size-recommendations` for per-file packing options.
4. Run `report-basename-collisions` to find likely filename-stem collisions.
5. Run `report-file-durations` to find possible duration-based duplicates.
6. Review `.archival-prep/` outputs before staging/burning.

## Notes

- Scripts create `.archival-prep/` automatically when needed.
- Size report ordering is deterministic and aligned with candidate TSV ordering.
- Scripts are read-only with respect to your source media/content.

## Troubleshooting

- **`ffprobe` not found**: install FFmpeg and verify with `ffprobe -version`.
- **Most files appear under `=== FILES WITH NO READABLE DURATION ===`**: this is expected for files that are not timed media or where `ffprobe` cannot produce a numeric duration (`N/A`, empty output, probe failure, or non-numeric output).
- **No duplicate groups found**: duplicate grouping only uses numeric normalized durations; files in the no-readable-duration section are excluded.
- **Permission errors writing reports**: set an explicit writable output path (`--output-dir` / `-OutputDir`).
