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

$fileSizesFile = Join-Path $outputDir 'file-sizes.txt'
$recommendationsFile = Join-Path $outputDir 'blu-ray-file-recommendations.txt'
$candidatesFile = Join-Path $outputDir 'file-sizes.tsv'

$items = @()
$allFiles = Get-ChildItem -LiteralPath $invocationDir -Recurse -File -Force
if ($outputDir.StartsWith($invocationDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    $allFiles = $allFiles | Where-Object {
        -not ($_.FullName -eq $outputDir -or $_.FullName.StartsWith($outputDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase))
    }
}

foreach ($file in $allFiles) {
    $items += [PSCustomObject]@{
        Path = $file.FullName
        SizeBytes = [long]$file.Length
    }
}

$items = $items | Sort-Object -Property @{ Expression = { $_.SizeBytes }; Descending = $true }, @{ Expression = { $_.Path }; Descending = $false }

Write-SizeReportFiles -Items $items -ReadablePath $fileSizesFile -CandidatesPath $candidatesFile -ScriptName $scriptName -ReportDateUtc $reportDateUtc -TargetDirectory $invocationDir -ReadableSubject 'recursive file sizes in GiB (binary units)' -CandidateSubject 'recursive file size candidates in bytes (TSV: path<TAB>size_bytes)'

$context = New-BluRayPackingContext -Items $items
Write-BluRayRecommendationFile -Context $context -RecommendationsFile $recommendationsFile -ScriptName $scriptName -ReportDateUtc $reportDateUtc -TargetDirectory $invocationDir -Subject 'optimal Blu-ray file packing recommendations (marketed GB labels with binary GiB capacities)'

Write-Output "Wrote: $fileSizesFile"
Write-Output "Wrote: $recommendationsFile"
Write-Output "Wrote: $candidatesFile"
