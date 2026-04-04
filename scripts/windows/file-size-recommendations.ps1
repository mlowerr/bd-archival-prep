[CmdletBinding()]
param(
    [string]$TargetDir = (Get-Location).Path,
    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'
$outputDirProvided = $PSBoundParameters.ContainsKey('OutputDir')

$invocationDir = (Resolve-Path -LiteralPath $TargetDir).Path
if (-not $outputDirProvided) {
    $OutputDir = Join-Path $invocationDir '.archival-prep'
}
if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}
$outputDir = (Resolve-Path -LiteralPath $OutputDir).Path

$fileSizesFile = Join-Path $outputDir 'file-sizes.txt'
$recommendationsFile = Join-Path $outputDir 'blu-ray-file-recommendations.txt'
$candidatesFile = Join-Path $outputDir 'file-sizes.tsv'

$scriptName = Split-Path -Leaf $PSCommandPath
$reportDateUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

$items = @()
$allFiles = Get-ChildItem -LiteralPath $invocationDir -Recurse -File -Force
if ($outputDir.StartsWith($invocationDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    $allFiles = $allFiles | Where-Object {
        -not ($_.FullName -eq $outputDir -or $_.FullName.StartsWith($outputDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase))
    }
}

foreach ($file in $allFiles) {
    $sizeBytes = [long]$file.Length
    $items += [PSCustomObject]@{
        Path = $file.FullName
        SizeBytes = $sizeBytes
    }
}

$items = $items | Sort-Object -Property @{ Expression = { $_.SizeBytes }; Descending = $true }, @{ Expression = { $_.Path }; Descending = $false }

$fileLines = New-Object System.Collections.Generic.List[string]
$fileLines.Add("# Script: $scriptName")
$fileLines.Add("# Report date (UTC): $reportDateUtc")
$fileLines.Add("# Target directory: $invocationDir")
$fileLines.Add('# Subject: recursive file sizes in GiB (binary units)')
$fileLines.Add('')
$items | ForEach-Object {
    $fileLines.Add(("{0} | {1:N3} GiB" -f $_.Path, ([double]$_.SizeBytes / 1GB)))
}
Set-Content -Path $fileSizesFile -Value $fileLines -Encoding UTF8

$candidateLines = New-Object System.Collections.Generic.List[string]
$candidateLines.Add("# Script: $scriptName")
$candidateLines.Add("# Report date (UTC): $reportDateUtc")
$candidateLines.Add("# Target directory: $invocationDir")
$candidateLines.Add('# Subject: recursive file size candidates in bytes (TSV: path<TAB>size_bytes)')
$candidateLines.Add('')
$items | ForEach-Object {
    $candidateLines.Add(("{0}`t{1}" -f $_.Path, $_.SizeBytes))
}
Set-Content -Path $candidatesFile -Value $candidateLines -Encoding UTF8

$capacity50Bytes = [long]([Math]::Round(46.4 * 1GB))
$capacity100Bytes = [long]([Math]::Round(93.1 * 1GB))
$oversizedItems = @($items | Where-Object { [long]$_.SizeBytes -gt $capacity100Bytes })
$packableItems = @($items | Where-Object { [long]$_.SizeBytes -le $capacity100Bytes })

function Get-TryPack {
    param(
        [array]$Entries,
        [long[]]$CapacitiesBytes
    )

    $sizes = @($Entries | ForEach-Object { [long]$_.SizeBytes })
    $suffix = New-Object long[] ($sizes.Count + 1)
    for ($i = $sizes.Count - 1; $i -ge 0; $i--) {
        $suffix[$i] = $suffix[$i + 1] + $sizes[$i]
    }

    $bins = @()
    foreach ($cap in $CapacitiesBytes) {
        $bins += [PSCustomObject]@{
            CapacityBytes = [long]$cap
            UsedBytes = [long]0
            Picks = [System.Collections.Generic.List[int]]::new()
        }
    }

    $failed = [System.Collections.Generic.HashSet[string]]::new()
    $script:packed = $false

    function Dive-Pack {
        param([int]$Index)

        if ($script:packed) { return }
        if ($Index -ge $Entries.Count) {
            $script:packed = $true
            return
        }

        $freeSpaces = @()
        $totalFree = [long]0
        foreach ($bin in $bins) {
            $free = [long]$bin.CapacityBytes - [long]$bin.UsedBytes
            $freeSpaces += $free
            $totalFree += $free
        }
        $state = '{0}|{1}' -f $Index, (($freeSpaces | Sort-Object -Descending) -join ',')
        if ($failed.Contains($state)) { return }
        if ($totalFree -lt $suffix[$Index]) {
            $null = $failed.Add($state)
            return
        }

        $needed = [long]$Entries[$Index].SizeBytes
        $seenFree = [System.Collections.Generic.HashSet[long]]::new()

        for ($i = 0; $i -lt $bins.Count; $i++) {
            $bin = $bins[$i]
            $free = [long]$bin.CapacityBytes - [long]$bin.UsedBytes
            if ($free -lt $needed) { continue }
            if (-not $seenFree.Add($free)) { continue }

            $bin.UsedBytes += $needed
            $null = $bin.Picks.Add($Index)
            Dive-Pack -Index ($Index + 1)
            if ($script:packed) { return }
            $bin.UsedBytes -= $needed
            $bin.Picks.RemoveAt($bin.Picks.Count - 1)
        }

        $null = $failed.Add($state)
    }

    Dive-Pack -Index 0
    if (-not $script:packed) {
        return $null
    }

    $packedBins = @()
    foreach ($bin in $bins) {
        $packedBins += [PSCustomObject]@{
            CapacityBytes = [long]$bin.CapacityBytes
            UsedBytes = [long]$bin.UsedBytes
            Picks = @($bin.Picks)
        }
    }
    return $packedBins
}

function Get-OptimalMixedPlan {
    param([array]$Entries)

    if ($Entries.Count -eq 0) {
        return [PSCustomObject]@{ Bins = @(); Count100 = 0; Count50 = 0; CapacityBytes = 0L }
    }

    $maxItem = ($Entries | Measure-Object -Property SizeBytes -Maximum).Maximum
    if ([long]$maxItem -gt $capacity100Bytes) { return $null }

    $totalBytes = [long](($Entries | Measure-Object -Property SizeBytes -Sum).Sum)
    $minDisks = [Math]::Max(1, [int][Math]::Ceiling($totalBytes / [double]$capacity100Bytes))
    $maxDisks = [int][Math]::Ceiling($totalBytes / [double]$capacity50Bytes)

    for ($diskCount = $minDisks; $diskCount -le $maxDisks; $diskCount++) {
        $pairs = @()
        for ($count100 = 0; $count100 -le $diskCount; $count100++) {
            $count50 = $diskCount - $count100
            $capacity = ([long]$count100 * $capacity100Bytes) + ([long]$count50 * $capacity50Bytes)
            if ($capacity -lt $totalBytes) { continue }
            $pairs += [PSCustomObject]@{
                Count100 = $count100
                Count50 = $count50
                CapacityBytes = [long]$capacity
            }
        }
        $pairs = $pairs | Sort-Object -Property CapacityBytes, Count100

        foreach ($pair in $pairs) {
            $caps = @()
            for ($i = 0; $i -lt $pair.Count100; $i++) { $caps += $capacity100Bytes }
            for ($i = 0; $i -lt $pair.Count50; $i++) { $caps += $capacity50Bytes }

            $packedBins = Get-TryPack -Entries $Entries -CapacitiesBytes $caps
            if ($packedBins) {
                return [PSCustomObject]@{
                    Bins = $packedBins
                    Count100 = $pair.Count100
                    Count50 = $pair.Count50
                    CapacityBytes = [long]$pair.CapacityBytes
                }
            }
        }
    }

    return $null
}

function Get-Optimal50OnlyPlan {
    param([array]$Entries)

    if ($Entries.Count -eq 0) {
        return [PSCustomObject]@{ Bins = @(); Count100 = 0; Count50 = 0; CapacityBytes = 0L }
    }

    $maxItem = ($Entries | Measure-Object -Property SizeBytes -Maximum).Maximum
    if ([long]$maxItem -gt $capacity50Bytes) { return $null }

    $totalBytes = [long](($Entries | Measure-Object -Property SizeBytes -Sum).Sum)
    $startCount = [Math]::Max(1, [int][Math]::Ceiling($totalBytes / [double]$capacity50Bytes))
    for ($count50 = $startCount; $count50 -le $Entries.Count; $count50++) {
        $caps = @()
        for ($i = 0; $i -lt $count50; $i++) { $caps += $capacity50Bytes }
        $packedBins = Get-TryPack -Entries $Entries -CapacitiesBytes $caps
        if ($packedBins) {
            return [PSCustomObject]@{
                Bins = $packedBins
                Count100 = 0
                Count50 = $count50
                CapacityBytes = [long]($count50 * $capacity50Bytes)
            }
        }
    }
    return $null
}

function Get-Optimal100OnlyPlan {
    param([array]$Entries)

    if ($Entries.Count -eq 0) {
        return [PSCustomObject]@{ Bins = @(); Count100 = 0; Count50 = 0; CapacityBytes = 0L }
    }

    $maxItem = ($Entries | Measure-Object -Property SizeBytes -Maximum).Maximum
    if ([long]$maxItem -gt $capacity100Bytes) { return $null }

    $totalBytes = [long](($Entries | Measure-Object -Property SizeBytes -Sum).Sum)
    $startCount = [Math]::Max(1, [int][Math]::Ceiling($totalBytes / [double]$capacity100Bytes))
    for ($count100 = $startCount; $count100 -le $Entries.Count; $count100++) {
        $caps = @()
        for ($i = 0; $i -lt $count100; $i++) { $caps += $capacity100Bytes }
        $packedBins = Get-TryPack -Entries $Entries -CapacitiesBytes $caps
        if ($packedBins) {
            return [PSCustomObject]@{
                Bins = $packedBins
                Count100 = $count100
                Count50 = 0
                CapacityBytes = [long]($count100 * $capacity100Bytes)
            }
        }
    }
    return $null
}

function Write-PlanSection {
    param(
        [string]$Header,
        [object]$Plan,
        [array]$Entries,
        [System.Collections.Generic.List[string]]$Lines
    )

    $Lines.Add(("=== {0} ===" -f $Header))

    if (-not $Plan) {
        $Lines.Add('No feasible plan remains for packable items.')
        $Lines.Add('')
        return
    }

    $totalBytes = [long](($Entries | Measure-Object -Property SizeBytes -Sum).Sum)
    $totalDisks = $Plan.Count100 + $Plan.Count50
    $unusedBytes = [long]$Plan.CapacityBytes - $totalBytes

    $Lines.Add(("Combination: {0} x 100 GB marketed (93.1 GiB) + {1} x 50 GB marketed (46.4 GiB)" -f $Plan.Count100, $Plan.Count50))
    $Lines.Add(("Total disks: {0}" -f $totalDisks))
    $Lines.Add(("Disk counts by size (marketed): 100GB={0}, 50GB={1}" -f $Plan.Count100, $Plan.Count50))
    $Lines.Add(("Total data size: {0:N3} GiB" -f ($totalBytes / 1GB)))
    $Lines.Add(("Total writable capacity: {0:N3} GiB" -f ($Plan.CapacityBytes / 1GB)))
    $Lines.Add(("Total unused space: {0:N3} GiB" -f ($unusedBytes / 1GB)))
    $Lines.Add('')

    $diskIndex = 1
    foreach ($bin in $Plan.Bins) {
        $capacityGb = [double]$bin.CapacityBytes / 1GB
        $usedGb = [double]$bin.UsedBytes / 1GB
        $unusedGb = $capacityGb - $usedGb
        $Lines.Add(
            ("Disk [{0} of {1}] [{2:N1} GiB] | Size used: {3:N3} GiB | Unused space: {4:N3} GiB" -f $diskIndex, $totalDisks, $capacityGb, $usedGb, $unusedGb)
        )
        foreach ($pick in $bin.Picks) {
            $Lines.Add($Entries[$pick].Path)
        }
        $Lines.Add('')
        $diskIndex++
    }
}

if ($packableItems.Count -eq 0 -and $oversizedItems.Count -gt 0) {
    $mixedPlan = $null
    $only50Plan = $null
    $only100Plan = $null
}
else {
    $mixedPlan = Get-OptimalMixedPlan -Entries $packableItems
    $only50Plan = Get-Optimal50OnlyPlan -Entries $packableItems
    $only100Plan = Get-Optimal100OnlyPlan -Entries $packableItems
}

$recommendationLines = New-Object System.Collections.Generic.List[string]
$recommendationLines.Add("# Script: $scriptName")
$recommendationLines.Add("# Report date (UTC): $reportDateUtc")
$recommendationLines.Add("# Target directory: $invocationDir")
$recommendationLines.Add('# Subject: optimal Blu-ray file packing recommendations (marketed GB labels with binary GiB capacities)')
$recommendationLines.Add('')
$recommendationLines.Add('=== OVERSIZED ===')
if ($oversizedItems.Count -eq 0) {
    $recommendationLines.Add('None.')
}
else {
    foreach ($entry in $oversizedItems) {
        $recommendationLines.Add(("{0} | {1:N3} GiB" -f $entry.Path, ([double]$entry.SizeBytes / 1GB)))
    }
}
$recommendationLines.Add('')

Write-PlanSection -Header 'OPTIMAL MIXED DISK PLAN (50 GB marketed / 46.4 GiB + 100 GB marketed / 93.1 GiB)' -Plan $mixedPlan -Entries $packableItems -Lines $recommendationLines
Write-PlanSection -Header 'OPTIMAL 50 GB-ONLY DISK PLAN (46.4 GiB usable)' -Plan $only50Plan -Entries $packableItems -Lines $recommendationLines
Write-PlanSection -Header 'OPTIMAL 100 GB-ONLY DISK PLAN (93.1 GiB usable)' -Plan $only100Plan -Entries $packableItems -Lines $recommendationLines

Set-Content -Path $recommendationsFile -Value $recommendationLines -Encoding UTF8

Write-Output "Wrote: $fileSizesFile"
Write-Output "Wrote: $recommendationsFile"
Write-Output "Wrote: $candidatesFile"
