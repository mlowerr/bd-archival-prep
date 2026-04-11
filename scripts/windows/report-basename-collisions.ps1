[CmdletBinding()]
param(
    [string]$TargetDir = (Get-Location).ProviderPath,
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $PSCommandPath
. (Join-Path $scriptRoot 'lib/Common.ps1')

$outputDirProvided = $PSBoundParameters.ContainsKey('OutputDir')
$envInfo = Initialize-ReportEnvironment -TargetDir $TargetDir -OutputDir $OutputDir -OutputDirProvided $outputDirProvided -ScriptPath $PSCommandPath
$startDir = $envInfo.TargetDir
$outDir = $envInfo.OutputDir
$scriptName = $envInfo.ScriptName
$reportDateUtc = $envInfo.ReportDateUtc
$outFile = Join-Path -Path $outDir -ChildPath 'basename-collisions.txt'

$groups = @{}

Get-ChildItem -LiteralPath $startDir -File -Recurse -Force | ForEach-Object {
    $fullPath = $_.FullName
    if ($fullPath -eq $outFile -or (Test-IsPathUnder -ParentPath $outDir -ChildPath $fullPath)) {
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

$output = New-MetadataHeaderLines -ScriptName $scriptName -ReportDateUtc $reportDateUtc -LocationLabel 'Reporting on' -LocationValue $startDir -Subject 'basename collisions (same filename stem with 2+ files)'
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

Set-Content -LiteralPath $outFile -Value $output -Encoding UTF8
Write-Output "Wrote basename collision report to: $outFile"
