$ErrorActionPreference = 'Stop'

$ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
if (-not $ffprobe) {
    Write-Error @"
ffprobe was not found in PATH.
Install FFmpeg (which includes ffprobe), then re-run this script.
Example (winget): winget install Gyan.FFmpeg
"@
    exit 1
}

$startDir = (Get-Location).Path
$outDir = Join-Path $startDir '.archival-prep'
New-Item -Path $outDir -ItemType Directory -Force | Out-Null

$fileDurationsPath = Join-Path $outDir 'file-durations.txt'
$duplicatesPath = Join-Path $outDir 'possible-duplicates-by-duration.txt'

$records = New-Object System.Collections.Generic.List[object]
$outDirNormalized = ([System.IO.Path]::GetFullPath($outDir)).TrimEnd('\', '/')
$outDirPrefix = "$outDirNormalized\"

if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}

Get-ChildItem -Path $startDir -File -Recurse |
    Where-Object {
        $filePathNormalized = ([System.IO.Path]::GetFullPath($_.FullName)).Replace('/', '\')
        -not $filePathNormalized.StartsWith($outDirPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    } |
    Sort-Object FullName |
    ForEach-Object {
    $file = $_.FullName
    $durationOutput = & $ffprobe.Source -v error -show_entries format=duration -of 'default=noprint_wrappers=1:nokey=1' -- "$file" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return
    }
    if ($null -eq $durationOutput) {
        return
    }

    $durationRaw = "$durationOutput".Trim()

    if ([string]::IsNullOrWhiteSpace($durationRaw)) {
        return
    }
    if ($durationRaw -eq 'N/A') {
        return
    }

    $parsed = 0.0
    if (-not [double]::TryParse($durationRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return
    }
    if ([double]::IsNaN($parsed) -or [double]::IsInfinity($parsed) -or $parsed -lt 0) {
        return
    }

    $normalized = [int][Math]::Round($parsed, 0, [System.MidpointRounding]::AwayFromZero)
    $records.Add([PSCustomObject]@{
        FullPath = $file
        Duration = $normalized
    })
}

$records |
    Sort-Object FullPath |
    ForEach-Object { "{0} | {1}" -f $_.FullPath, $_.Duration } |
    Set-Content -Path $fileDurationsPath -Encoding UTF8

$sb = New-Object System.Text.StringBuilder
$groupIndex = 0

$records |
    Sort-Object Duration, FullPath |
    Group-Object Duration |
    Where-Object { $_.Count -ge 2 } |
    ForEach-Object {
        $groupIndex++
        [void]$sb.AppendLine(("POSSIBLE DUPLICATE [{0}] - Duration: {1}" -f $groupIndex, $_.Name))
        $_.Group | Sort-Object FullPath | ForEach-Object {
            [void]$sb.AppendLine($_.FullPath)
        }
        [void]$sb.AppendLine('')
    }

$sb.ToString().TrimEnd() | Set-Content -Path $duplicatesPath -Encoding UTF8

Write-Host "Wrote: $fileDurationsPath"
Write-Host "Wrote: $duplicatesPath"
