[CmdletBinding()]
param(
    [string]$TargetDir = (Get-Location).Path,
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $PSCommandPath
. (Join-Path $scriptRoot 'lib/Common.ps1')
. (Join-Path $scriptRoot 'lib/BluRayPacking.ps1')

$outputDirProvided = $PSBoundParameters.ContainsKey('OutputDir')
$envInfo = Initialize-ReportEnvironment -TargetDir $TargetDir -OutputDir $OutputDir -OutputDirProvided $outputDirProvided -ScriptPath $PSCommandPath
$invocationDir = $envInfo.TargetDir
$outputDir = $envInfo.OutputDir
$scriptName = $envInfo.ScriptName
$reportDateUtc = $envInfo.ReportDateUtc

$folderSizesFile = Join-Path $outputDir 'folder-sizes.txt'
$recommendationsFile = Join-Path $outputDir 'blu-ray-recommendations.txt'
$candidatesFile = Join-Path $outputDir 'folder-sizes.tsv'

$items = @()
$directories = Get-ChildItem -LiteralPath $invocationDir -Directory | Where-Object {
    (Resolve-Path -LiteralPath $_.FullName).Path -ne $outputDir
}

foreach ($dir in $directories) {
    $dirPathWithSep = $dir.FullName.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $sum = [long]0
    Get-ChildItem -LiteralPath $dir.FullName -Recurse -Force -File |
        Where-Object {
            if (-not $outputDir.StartsWith($dirPathWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
            return -not ($_.FullName -eq $outputDir -or $_.FullName.StartsWith($outputDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase))
        } |
        ForEach-Object {
            $sum += [long]$_.Length
        }

    $items += [PSCustomObject]@{
        Path = $dir.FullName
        SizeBytes = [long]$sum
    }
}

$items = $items | Sort-Object -Property @{ Expression = { $_.SizeBytes }; Descending = $true }, @{ Expression = { $_.Path }; Descending = $false }

Write-SizeReportFiles -Items $items -ReadablePath $folderSizesFile -CandidatesPath $candidatesFile -ScriptName $scriptName -ReportDateUtc $reportDateUtc -TargetDirectory $invocationDir -ReadableSubject 'first-level folder sizes in GiB (binary units)' -CandidateSubject 'first-level folder size candidates in bytes (TSV: path<TAB>size_bytes)'

$context = New-BluRayPackingContext -Items $items
Write-BluRayRecommendationFile -Context $context -RecommendationsFile $recommendationsFile -ScriptName $scriptName -ReportDateUtc $reportDateUtc -TargetDirectory $invocationDir -Subject 'optimal Blu-ray folder packing recommendations (marketed GB labels with binary GiB capacities)'

Write-Output "Wrote: $folderSizesFile"
Write-Output "Wrote: $recommendationsFile"
Write-Output "Wrote: $candidatesFile"
