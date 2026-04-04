[CmdletBinding()]
param(
    [string]$TargetDir = (Get-Location).Path,
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$outputDirProvided = $PSBoundParameters.ContainsKey('OutputDir')

$ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
if (-not $ffprobe) {
    Write-Error @"
ffprobe was not found in PATH.
Install FFmpeg (which includes ffprobe), then re-run this script.
Example (winget): winget install Gyan.FFmpeg
"@
    exit 1
}

$startDir = (Resolve-Path -LiteralPath $TargetDir).Path
if (-not $outputDirProvided) {
    $OutputDir = Join-Path $startDir '.archival-prep'
}
if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -LiteralPath $OutputDir -ItemType Directory -Force | Out-Null
}
$outDir = (Resolve-Path -LiteralPath $OutputDir).Path

$fileDurationsPath = Join-Path $outDir 'file-durations.txt'
$duplicatesPath = Join-Path $outDir 'possible-duplicates-by-duration.txt'

$scriptName = Split-Path -Leaf $PSCommandPath
$reportDateUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

$records = New-Object System.Collections.Generic.List[object]
$unreadableFiles = New-Object System.Collections.Generic.List[string]
$outDirNormalized = ([System.IO.Path]::GetFullPath($outDir)).TrimEnd('\\', '/')
$outDirPrefix = "$outDirNormalized\"

function Get-FFprobeDurationRaw {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FFprobePath,
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FFprobePath
    $psi.Arguments = "-v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- `"$FilePath`""
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    if (-not $process.Start()) {
        return $null
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $process.WaitForExit()
    $stdoutTask.Wait()
    $stderrTask.Wait()

    if ($process.ExitCode -ne 0) {
        return $null
    }

    return $stdoutTask.Result
}

Get-ChildItem -LiteralPath $startDir -File -Recurse -Force |
    Sort-Object FullName |
    Where-Object {
        $filePathNormalized = ([System.IO.Path]::GetFullPath($_.FullName)).Replace('/', '\\')
        -not $filePathNormalized.StartsWith($outDirPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    } |
    ForEach-Object {
        $file = $_.FullName
        $durationOutput = Get-FFprobeDurationRaw -FFprobePath $ffprobe.Source -FilePath $file

        $durationRaw = if ($null -eq $durationOutput) { '' } else { "$durationOutput".Trim() }

        if (-not [string]::IsNullOrWhiteSpace($durationRaw) -and $durationRaw -ne 'N/A') {
            $parsed = 0.0
            if ([double]::TryParse($durationRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and -not [double]::IsNaN($parsed) -and -not [double]::IsInfinity($parsed) -and $parsed -ge 0) {
                $normalized = [int][Math]::Round($parsed, 0, [System.MidpointRounding]::AwayFromZero)
                $records.Add([PSCustomObject]@{
                    FullPath = $file
                    Duration = $normalized
                })
                return
            }
        }

        $unreadableFiles.Add($file)
    }

$durationLines = New-Object System.Collections.Generic.List[string]
$durationLines.Add("# Script: $scriptName")
$durationLines.Add("# Report date (UTC): $reportDateUtc")
$durationLines.Add("# Reporting on: $startDir")
$durationLines.Add('# Subject: file durations from ffprobe (seconds)')
$durationLines.Add('')
$records |
    Sort-Object FullPath |
    ForEach-Object { $durationLines.Add(("{0} | {1}" -f $_.FullPath, $_.Duration)) }
$durationLines.Add('')
$durationLines.Add('=== FILES WITH NO READABLE DURATION ===')
$unreadableFiles |
    Sort-Object |
    ForEach-Object { $durationLines.Add($_) }
Set-Content -LiteralPath $fileDurationsPath -Value $durationLines -Encoding UTF8

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# Script: $scriptName")
[void]$sb.AppendLine("# Report date (UTC): $reportDateUtc")
[void]$sb.AppendLine("# Reporting on: $startDir")
[void]$sb.AppendLine('# Subject: possible duplicates grouped by identical normalized duration')
[void]$sb.AppendLine('')

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

$sb.ToString().TrimEnd() | Set-Content -LiteralPath $duplicatesPath -Encoding UTF8

Write-Output "Wrote: $fileDurationsPath"
Write-Output "Wrote: $duplicatesPath"
