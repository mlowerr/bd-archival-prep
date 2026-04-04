[CmdletBinding()]
param(
    [string]$TargetDir = (Get-Location).Path,
    [string]$OutputDir,
    [ValidateRange(1, [int]::MaxValue)]
    [int]$Jobs = 3
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

$candidateFiles = Get-ChildItem -LiteralPath $startDir -File -Recurse -Force |
    Sort-Object FullName |
    Where-Object {
        $filePathNormalized = ([System.IO.Path]::GetFullPath($_.FullName)).Replace('/', '\\')
        -not $filePathNormalized.StartsWith($outDirPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    } |
    Select-Object -ExpandProperty FullName

function Add-DurationResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$RecordList,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$UnreadableList
    )

    if ($null -eq $Result) {
        return
    }

    if ($Result.IsReadableDuration) {
        $RecordList.Add([PSCustomObject]@{
            FullPath = [string]$Result.FullPath
            Duration = [int]$Result.Duration
        })
    } else {
        $UnreadableList.Add([string]$Result.FullPath)
    }
}

function Invoke-DurationScanWithLegacyJobs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FFprobePath,
        [Parameter(Mandatory = $true)]
        [string[]]$Files,
        [Parameter(Mandatory = $true)]
        [int]$Throttle,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$RecordList,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$UnreadableList
    )

    $pendingFiles = New-Object System.Collections.Generic.Queue[string]
    $Files | ForEach-Object { $pendingFiles.Enqueue($_) }
    $runningJobs = New-Object System.Collections.Generic.List[System.Management.Automation.Job]

    function Start-DurationJob {
        param(
            [Parameter(Mandatory = $true)]
            [string]$FFprobePath,
            [Parameter(Mandatory = $true)]
            [string]$FilePath
        )

        Start-Job -ScriptBlock {
            param($ffprobePathArg, $filePathArg)

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $ffprobePathArg
            $psi.Arguments = "-v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- `\"$filePathArg`\""
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true

            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $psi

            if (-not $process.Start()) {
                return [PSCustomObject]@{
                    FullPath = $filePathArg
                    IsReadableDuration = $false
                    Duration = $null
                }
            }

            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()

            $process.WaitForExit()
            $stdoutTask.Wait()
            $stderrTask.Wait()

            if ($process.ExitCode -ne 0) {
                return [PSCustomObject]@{
                    FullPath = $filePathArg
                    IsReadableDuration = $false
                    Duration = $null
                }
            }

            $durationRaw = "$($stdoutTask.Result)".Trim()
            if ([string]::IsNullOrWhiteSpace($durationRaw) -or $durationRaw -eq 'N/A') {
                return [PSCustomObject]@{
                    FullPath = $filePathArg
                    IsReadableDuration = $false
                    Duration = $null
                }
            }

            $parsed = 0.0
            if ([double]::TryParse($durationRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and -not [double]::IsNaN($parsed) -and -not [double]::IsInfinity($parsed) -and $parsed -ge 0) {
                $normalized = [int][Math]::Round($parsed, 0, [System.MidpointRounding]::AwayFromZero)
                return [PSCustomObject]@{
                    FullPath = $filePathArg
                    IsReadableDuration = $true
                    Duration = $normalized
                }
            }

            return [PSCustomObject]@{
                FullPath = $filePathArg
                IsReadableDuration = $false
                Duration = $null
            }
        } -ArgumentList $FFprobePath, $FilePath
    }

    function Receive-CompletedJobResults {
        param(
            [Parameter(Mandatory = $true)]
            [System.Collections.Generic.List[System.Management.Automation.Job]]$JobList,
            [switch]$WaitForAny
        )

        if ($JobList.Count -eq 0) {
            return
        }

        $completed = if ($WaitForAny) {
            @(Wait-Job -Job $JobList -Any)
        } else {
            @(Wait-Job -Job $JobList)
        }

        foreach ($job in $completed) {
            $results = @(Receive-Job -Job $job)
            foreach ($result in $results) {
                Add-DurationResult -Result $result -RecordList $RecordList -UnreadableList $UnreadableList
            }
            Remove-Job -Job $job -Force
            [void]$JobList.Remove($job)
        }
    }

    while ($pendingFiles.Count -gt 0 -or $runningJobs.Count -gt 0) {
        while ($pendingFiles.Count -gt 0 -and $runningJobs.Count -lt $Throttle) {
            $nextFile = $pendingFiles.Dequeue()
            $runningJobs.Add((Start-DurationJob -FFprobePath $FFprobePath -FilePath $nextFile))
        }

        Receive-CompletedJobResults -JobList $runningJobs -WaitForAny
    }
}

$runspacePool = $null
$tasks = New-Object System.Collections.Generic.List[object]
$usedLegacyFallback = $false

$durationProbeScript = {
    param($ffprobePathArg, $filePathArg)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ffprobePathArg
    $psi.Arguments = "-v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- `\"$filePathArg`\""
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    if (-not $process.Start()) {
        return [PSCustomObject]@{
            FullPath = $filePathArg
            IsReadableDuration = $false
            Duration = $null
        }
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $process.WaitForExit()
    $stdoutTask.Wait()
    $stderrTask.Wait()

    if ($process.ExitCode -ne 0) {
        return [PSCustomObject]@{
            FullPath = $filePathArg
            IsReadableDuration = $false
            Duration = $null
        }
    }

    $durationRaw = "$($stdoutTask.Result)".Trim()
    if ([string]::IsNullOrWhiteSpace($durationRaw) -or $durationRaw -eq 'N/A') {
        return [PSCustomObject]@{
            FullPath = $filePathArg
            IsReadableDuration = $false
            Duration = $null
        }
    }

    $parsed = 0.0
    if ([double]::TryParse($durationRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and -not [double]::IsNaN($parsed) -and -not [double]::IsInfinity($parsed) -and $parsed -ge 0) {
        $normalized = [int][Math]::Round($parsed, 0, [System.MidpointRounding]::AwayFromZero)
        return [PSCustomObject]@{
            FullPath = $filePathArg
            IsReadableDuration = $true
            Duration = $normalized
        }
    }

    return [PSCustomObject]@{
        FullPath = $filePathArg
        IsReadableDuration = $false
        Duration = $null
    }
}

try {
    $runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $Jobs)
    $runspacePool.Open()

    foreach ($filePath in $candidateFiles) {
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $runspacePool
        [void]$ps.AddScript($durationProbeScript)
        [void]$ps.AddArgument($ffprobe.Source)
        [void]$ps.AddArgument($filePath)

        $handle = $ps.BeginInvoke()
        $tasks.Add([PSCustomObject]@{
            PowerShell = $ps
            Handle = $handle
        })
    }

    while ($tasks.Count -gt 0) {
        $completedThisPass = $false

        for ($i = $tasks.Count - 1; $i -ge 0; $i--) {
            $task = $tasks[$i]
            if (-not $task.Handle.IsCompleted) {
                continue
            }

            $completedThisPass = $true
            $results = @($task.PowerShell.EndInvoke($task.Handle))
            foreach ($result in $results) {
                Add-DurationResult -Result $result -RecordList $records -UnreadableList $unreadableFiles
            }
            $task.PowerShell.Dispose()
            $tasks.RemoveAt($i)
        }

        if (-not $completedThisPass) {
            Start-Sleep -Milliseconds 25
        }
    }
} catch {
    $usedLegacyFallback = $true

    foreach ($task in $tasks) {
        if ($null -ne $task.PowerShell) {
            $task.PowerShell.Dispose()
        }
    }
    $tasks.Clear()

    if ($null -ne $runspacePool) {
        $runspacePool.Close()
        $runspacePool.Dispose()
        $runspacePool = $null
    }

    Invoke-DurationScanWithLegacyJobs -FFprobePath $ffprobe.Source -Files $candidateFiles -Throttle $Jobs -RecordList $records -UnreadableList $unreadableFiles
} finally {
    foreach ($task in $tasks) {
        if ($null -ne $task.PowerShell) {
            $task.PowerShell.Dispose()
        }
    }

    if ($null -ne $runspacePool) {
        $runspacePool.Close()
        $runspacePool.Dispose()
    }
}

if ($usedLegacyFallback) {
    Write-Warning 'Runspace pool mode was unavailable; fell back to Start-Job worker mode.'
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
