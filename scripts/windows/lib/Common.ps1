[CmdletBinding()]
param()

function Initialize-ReportEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDir,
        [string]$OutputDir,
        [Parameter(Mandatory = $true)]
        [bool]$OutputDirProvided,
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    $resolvedTargetDir = (Resolve-Path -LiteralPath $TargetDir).Path
    if (-not $OutputDirProvided) {
        $OutputDir = Join-Path $resolvedTargetDir '.archival-prep'
    }
    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -LiteralPath $OutputDir -ItemType Directory -Force | Out-Null
    }

    [PSCustomObject]@{
        TargetDir = $resolvedTargetDir
        OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
        ScriptName = Split-Path -Leaf $ScriptPath
        ReportDateUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
}

function Test-IsPathUnder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParentPath,
        [Parameter(Mandatory = $true)]
        [string]$ChildPath
    )

    $parentFullPath = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($ParentPath))
    $childFullPath = [System.IO.Path]::GetFullPath($ChildPath)
    $parentPrefix = Join-Path -Path $parentFullPath -ChildPath ''

    return $childFullPath.StartsWith($parentPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function New-MetadataHeaderLines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,
        [Parameter(Mandatory = $true)]
        [string]$ReportDateUtc,
        [Parameter(Mandatory = $true)]
        [string]$LocationLabel,
        [Parameter(Mandatory = $true)]
        [string]$LocationValue,
        [Parameter(Mandatory = $true)]
        [string]$Subject
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Script: $ScriptName")
    $lines.Add("# Report date (UTC): $ReportDateUtc")
    $lines.Add(("# {0}: {1}" -f $LocationLabel, $LocationValue))
    $lines.Add(("# Subject: {0}" -f $Subject))
    $lines.Add('')
    return $lines
}

function Write-SizeReportFiles {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Items,
        [Parameter(Mandatory = $true)]
        [string]$ReadablePath,
        [Parameter(Mandatory = $true)]
        [string]$CandidatesPath,
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,
        [Parameter(Mandatory = $true)]
        [string]$ReportDateUtc,
        [Parameter(Mandatory = $true)]
        [string]$TargetDirectory,
        [Parameter(Mandatory = $true)]
        [string]$ReadableSubject,
        [Parameter(Mandatory = $true)]
        [string]$CandidateSubject
    )

    $readableLines = New-MetadataHeaderLines -ScriptName $ScriptName -ReportDateUtc $ReportDateUtc -LocationLabel 'Target directory' -LocationValue $TargetDirectory -Subject $ReadableSubject
    $Items | ForEach-Object {
        $readableLines.Add(("{0} | {1:N3} GiB" -f $_.Path, ([double]$_.SizeBytes / 1GB)))
    }
    Set-Content -LiteralPath $ReadablePath -Value $readableLines -Encoding UTF8

    $candidateLines = New-MetadataHeaderLines -ScriptName $ScriptName -ReportDateUtc $ReportDateUtc -LocationLabel 'Target directory' -LocationValue $TargetDirectory -Subject $CandidateSubject
    $Items | ForEach-Object {
        $candidateLines.Add(("{0}`t{1}" -f $_.Path, $_.SizeBytes))
    }
    Set-Content -LiteralPath $CandidatesPath -Value $candidateLines -Encoding UTF8
}
