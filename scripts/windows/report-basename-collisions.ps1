[CmdletBinding()]
param(
    [string]$TargetDir = (Get-Location).ProviderPath,
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$outputDirProvided = $PSBoundParameters.ContainsKey('OutputDir')

$startDir = (Resolve-Path -LiteralPath $TargetDir).ProviderPath
if (-not $outputDirProvided) {
    $OutputDir = Join-Path -Path $startDir -ChildPath '.archival-prep'
}
if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
$outDir = (Resolve-Path -LiteralPath $OutputDir).ProviderPath
$outFile = Join-Path -Path $outDir -ChildPath 'basename-collisions.txt'

$scriptName = Split-Path -Leaf $PSCommandPath
$reportDateUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

$groups = @{}

Get-ChildItem -Path $startDir -File -Recurse | ForEach-Object {
    $fullPath = $_.FullName
    if ($fullPath -eq $outFile -or $fullPath.StartsWith((Join-Path $outDir ''), [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    $fileName = $_.Name
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    if ([string]::IsNullOrEmpty($baseName)) {
        $baseName = $fileName
    }

    if (-not $groups.ContainsKey($baseName)) {
        $groups[$baseName] = New-Object System.Collections.Generic.List[string]
    }

    $groups[$baseName].Add($fullPath)
}

$output = New-Object System.Collections.Generic.List[string]
$output.Add("# Script: $scriptName")
$output.Add("# Report date (UTC): $reportDateUtc")
$output.Add("# Reporting on: $startDir")
$output.Add('# Subject: basename collisions (same filename stem with 2+ files)')
$output.Add('')

$firstGroup = $true
$keys = $groups.Keys | Sort-Object
foreach ($key in $keys) {
    $paths = $groups[$key]
    if ($paths.Count -lt 2) {
        continue
    }

    if (-not $firstGroup) {
        $output.Add('')
    }
    $firstGroup = $false

    $output.Add("[$key]")
    foreach ($path in ($paths | Sort-Object)) {
        $output.Add($path)
    }
}

Set-Content -Path $outFile -Value $output -Encoding UTF8
Write-Output "Wrote basename collision report to: $outFile"
