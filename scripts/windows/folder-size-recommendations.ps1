$ErrorActionPreference = 'Stop'

$invocationDir = (Get-Location).Path
$outputDir = Join-Path $invocationDir '.archival-prep'
$folderSizesFile = Join-Path $outputDir 'folder-sizes.txt'
$recommendationsFile = Join-Path $outputDir 'blu-ray-recommendations.txt'

if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

Set-Content -Path $folderSizesFile -Value $null
Set-Content -Path $recommendationsFile -Value $null

$items = @()
$directories = Get-ChildItem -LiteralPath $invocationDir -Directory | Where-Object { $_.Name -ne '.archival-prep' }

foreach ($dir in $directories) {
    $sum = (Get-ChildItem -LiteralPath $dir.FullName -Recurse -Force -File | Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { $sum = 0 }

    $sizeGb = [Math]::Round($sum / 1GB, 3)
    $items += [PSCustomObject]@{
        Path = $dir.FullName
        SizeBytes = [long]$sum
    }

    Add-Content -Path $folderSizesFile -Value ("{0} | {1:N3} GB" -f $dir.FullName, $sizeGb)
}

$items = $items | Sort-Object -Property SizeBytes -Descending
$capacity50Bytes = [long]([Math]::Round(46.4 * 1GB))
$capacity100Bytes = [long]([Math]::Round(93.1 * 1GB))

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
        if ($totalFree -lt $suffix[$Index]) { return }
        $state = '{0}|{1}' -f $Index, (($freeSpaces | Sort-Object -Descending) -join ',')
        if ($failed.Contains($state)) { return }

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
        [string]$RecommendationsFile
    )

    Add-Content -Path $RecommendationsFile -Value ("=== {0} ===" -f $Header)

    if (-not $Plan) {
        Add-Content -Path $RecommendationsFile -Value "No feasible plan found."
        Add-Content -Path $RecommendationsFile -Value ""
        return
    }

    $totalBytes = [long](($Entries | Measure-Object -Property SizeBytes -Sum).Sum)
    $totalDisks = $Plan.Count100 + $Plan.Count50
    $unusedBytes = [long]$Plan.CapacityBytes - $totalBytes

    Add-Content -Path $RecommendationsFile -Value ("Combination: {0} x 93.1 GB + {1} x 46.4 GB" -f $Plan.Count100, $Plan.Count50)
    Add-Content -Path $RecommendationsFile -Value ("Total disks: {0}" -f $totalDisks)
    Add-Content -Path $RecommendationsFile -Value ("Disk counts by size: 100GB={0}, 50GB={1}" -f $Plan.Count100, $Plan.Count50)
    Add-Content -Path $RecommendationsFile -Value ("Total data size: {0:N3} GB" -f ($totalBytes / 1GB))
    Add-Content -Path $RecommendationsFile -Value ("Total writable capacity: {0:N3} GB" -f ($Plan.CapacityBytes / 1GB))
    Add-Content -Path $RecommendationsFile -Value ("Total unused space: {0:N3} GB" -f ($unusedBytes / 1GB))
    Add-Content -Path $RecommendationsFile -Value ""

    $diskIndex = 1
    foreach ($bin in $Plan.Bins) {
        $capacityGb = [double]$bin.CapacityBytes / 1GB
        $usedGb = [double]$bin.UsedBytes / 1GB
        $unusedGb = $capacityGb - $usedGb
        Add-Content -Path $RecommendationsFile -Value (
            "Disk [{0} of {1}] [{2:N1} GB] | Size used: {3:N3} GB | Unused space: {4:N3} GB" -f $diskIndex, $totalDisks, $capacityGb, $usedGb, $unusedGb
        )
        foreach ($pick in $bin.Picks) {
            Add-Content -Path $RecommendationsFile -Value $Entries[$pick].Path
        }
        Add-Content -Path $RecommendationsFile -Value ""
        $diskIndex++
    }
}

$mixedPlan = Get-OptimalMixedPlan -Entries $items
$only50Plan = Get-Optimal50OnlyPlan -Entries $items
$only100Plan = Get-Optimal100OnlyPlan -Entries $items

Write-PlanSection -Header "OPTIMAL MIXED DISK PLAN (50GB + 100GB)" -Plan $mixedPlan -Entries $items -RecommendationsFile $recommendationsFile
Write-PlanSection -Header "OPTIMAL 50GB-ONLY DISK PLAN" -Plan $only50Plan -Entries $items -RecommendationsFile $recommendationsFile
Write-PlanSection -Header "OPTIMAL 100GB-ONLY DISK PLAN" -Plan $only100Plan -Entries $items -RecommendationsFile $recommendationsFile

Write-Output "Wrote: $folderSizesFile"
Write-Output "Wrote: $recommendationsFile"
