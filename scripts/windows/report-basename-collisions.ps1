[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$startDir = (Get-Location).ProviderPath
$outDir = Join-Path -Path $startDir -ChildPath '.archival-prep'
$outFile = Join-Path -Path $outDir -ChildPath 'basename-collisions.txt'

New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$groups = @{}

Get-ChildItem -Path $startDir -File -Recurse | ForEach-Object {
    $fullPath = $_.FullName
    if ($fullPath -eq $outFile) {
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
