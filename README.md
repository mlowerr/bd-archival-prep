# bd-archival-prep-windows

A collection of utilities designed to optimize the preparation of data for cold storage, with a specific focus on staging files for high-capacity recordable Blu-ray media.

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
