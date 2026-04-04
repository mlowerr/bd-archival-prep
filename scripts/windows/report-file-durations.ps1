<#
.SYNOPSIS
Reports video durations and possible duplicates by equal normalized duration.

.PARAMETER TargetDir
Directory to scan recursively.

.PARAMETER OutputDir
Directory where reports are written.

.PARAMETER Jobs
Number of concurrent ffprobe workers. Default is 3. Set to 1 to run sequentially.
#>

[CmdletBinding()]
param(
    [string]$TargetDir = (Get-Location).Path,
    [string]$OutputDir,
    [ValidateRange(1, 256)]
    [int]$Jobs = 3
)

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
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}
$outDir = (Resolve-Path -LiteralPath $OutputDir).Path

$fileDurationsPath = Join-Path $outDir 'file-durations.txt'
$duplicatesPath = Join-Path $outDir 'possible-duplicates-by-duration.txt'

$scriptName = Split-Path -Leaf $PSCommandPath
$reportDateUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

$records = New-Object System.Collections.Generic.List[object]
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

function Test-IsVideoFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FFprobePath,
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FFprobePath
    $psi.Arguments = "-v error -select_streams v:0 -show_entries stream=codec_type -of default=noprint_wrappers=1:nokey=1 -- `"$FilePath`""
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    if (-not $process.Start()) {
        return $false
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $process.WaitForExit()
    $stdoutTask.Wait()
    $stderrTask.Wait()

    if ($process.ExitCode -ne 0) {
        return $false
    }

    return ($stdoutTask.Result.Trim() -eq 'video')
}

function Get-DurationRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FFprobePath,
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string]$OutPrefix
    )

    $filePathNormalized = ([System.IO.Path]::GetFullPath($FilePath)).Replace('/', '\\')
    if ($filePathNormalized.StartsWith($OutPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    if (-not (Test-IsVideoFile -FFprobePath $FFprobePath -FilePath $FilePath)) {
        return $null
    }

    $durationOutput = Get-FFprobeDurationRaw -FFprobePath $FFprobePath -FilePath $FilePath
    if ($null -eq $durationOutput) {
        return $null
    }

    $durationRaw = "$durationOutput".Trim()
    if ([string]::IsNullOrWhiteSpace($durationRaw) -or $durationRaw -eq 'N/A') {
        return $null
    }

    $parsed = 0.0
    if (-not [double]::TryParse($durationRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $null
    }
    if ([double]::IsNaN($parsed) -or [double]::IsInfinity($parsed) -or $parsed -lt 0) {
        return $null
    }

    $normalized = [int][Math]::Round($parsed, 0, [System.MidpointRounding]::AwayFromZero)
    return [PSCustomObject]@{
        FullPath = $FilePath
        Duration = $normalized
    }
}

$allFiles = Get-ChildItem -Path $startDir -File -Recurse | Sort-Object FullName

if ($Jobs -eq 1) {
    foreach ($item in $allFiles) {
        $record = Get-DurationRecord -FFprobePath $ffprobe.Source -FilePath $item.FullName -OutPrefix $outDirPrefix
        if ($null -ne $record) {
            $records.Add($record)
        }
    }
}
else {
    $jobQueue = New-Object System.Collections.Generic.List[object]

    foreach ($item in $allFiles) {
        while (($jobQueue | Where-Object { $_.State -eq 'Running' }).Count -ge $Jobs) {
            $finished = Wait-Job -Job $jobQueue -Any
            if ($null -ne $finished) {
                $result = Receive-Job -Job $finished
                if ($null -ne $result) {
                    $records.Add($result)
                }
                Remove-Job -Job $finished
                $jobQueue.Remove($finished) | Out-Null
            }
        }

        $job = Start-Job -ScriptBlock {
            param($ffprobePath, $filePath, $outPrefix)

            function Invoke-FFprobe {
                param(
                    [string]$ProbePath,
                    [string]$ProbeArgs
                )

                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $ProbePath
                $psi.Arguments = $ProbeArgs
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

            $normalizedPath = ([System.IO.Path]::GetFullPath($filePath)).Replace('/', '\\')
            if ($normalizedPath.StartsWith($outPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                return
            }

            $codecType = Invoke-FFprobe -ProbePath $ffprobePath -ProbeArgs "-v error -select_streams v:0 -show_entries stream=codec_type -of default=noprint_wrappers=1:nokey=1 -- `"$filePath`""
            if ($null -eq $codecType -or $codecType.Trim() -ne 'video') {
                return
            }

            $durationRaw = Invoke-FFprobe -ProbePath $ffprobePath -ProbeArgs "-v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- `"$filePath`""
            if ($null -eq $durationRaw) {
                return
            }

            $durationRaw = $durationRaw.Trim()
            if ([string]::IsNullOrWhiteSpace($durationRaw) -or $durationRaw -eq 'N/A') {
                return
            }

            $parsed = 0.0
            if (-not [double]::TryParse($durationRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                return
            }
            if ([double]::IsNaN($parsed) -or [double]::IsInfinity($parsed) -or $parsed -lt 0) {
                return
            }

            [PSCustomObject]@{
                FullPath = $filePath
                Duration = [int][Math]::Round($parsed, 0, [System.MidpointRounding]::AwayFromZero)
            }
        } -ArgumentList $ffprobe.Source, $item.FullName, $outDirPrefix

        $jobQueue.Add($job)
    }

    foreach ($job in $jobQueue) {
        Wait-Job -Job $job | Out-Null
        $result = Receive-Job -Job $job
        if ($null -ne $result) {
            $records.Add($result)
        }
        Remove-Job -Job $job
    }
}

$durationLines = New-Object System.Collections.Generic.List[string]
$durationLines.Add("# Script: $scriptName")
$durationLines.Add("# Report date (UTC): $reportDateUtc")
$durationLines.Add("# Reporting on: $startDir")
$durationLines.Add('# Subject: video file durations from ffprobe (seconds)')
$durationLines.Add('')
$records |
    Sort-Object FullPath |
    ForEach-Object { $durationLines.Add(("{0} | {1}" -f $_.FullPath, $_.Duration)) }
Set-Content -Path $fileDurationsPath -Value $durationLines -Encoding UTF8

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

$sb.ToString().TrimEnd() | Set-Content -Path $duplicatesPath -Encoding UTF8

Write-Host "Wrote: $fileDurationsPath"
Write-Host "Wrote: $duplicatesPath"
