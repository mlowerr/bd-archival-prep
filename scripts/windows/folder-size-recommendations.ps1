[CmdletBinding()]
param(
    [string]$TargetDir = (Get-Location).Path,
    [string]$OutputDir
)

Set-StrictMode -Version Latest
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

$folderSizesFile = Join-Path $outputDir 'folder-sizes.txt'
$recommendationsFile = Join-Path $outputDir 'blu-ray-recommendations.txt'
$candidatesFile = Join-Path $outputDir 'folder-sizes.tsv'

$scriptName = Split-Path -Leaf $PSCommandPath
$reportDateUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

$items = @()
$directories = Get-ChildItem -LiteralPath $invocationDir -Directory | Where-Object {
    (Resolve-Path -LiteralPath $_.FullName).Path -ne $outputDir
}

foreach ($dir in $directories) {
    $dirPathWithSep = $dir.FullName.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $files = Get-ChildItem -LiteralPath $dir.FullName -Recurse -Force -File
    if ($outputDir.StartsWith($dirPathWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
        $files = $files | Where-Object {
            -not ($_.FullName -eq $outputDir -or $_.FullName.StartsWith($outputDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase))
        }
    }
    $sum = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { $sum = 0 }

    $items += [PSCustomObject]@{
        Path = $dir.FullName
        SizeBytes = [long]$sum
    }
}

$items = $items | Sort-Object -Property @{ Expression = { $_.SizeBytes }; Descending = $true }, @{ Expression = { $_.Path }; Descending = $false }

$folderLines = New-Object System.Collections.Generic.List[string]
$folderLines.Add("# Script: $scriptName")
$folderLines.Add("# Report date (UTC): $reportDateUtc")
$folderLines.Add("# Target directory: $invocationDir")
$folderLines.Add('# Subject: first-level folder sizes in GiB (binary units)')
$folderLines.Add('')
$items | ForEach-Object {
    $folderLines.Add(("{0} | {1:N3} GiB" -f $_.Path, ([double]$_.SizeBytes / 1GB)))
}
Set-Content -Path $folderSizesFile -Value $folderLines -Encoding UTF8

$candidateLines = New-Object System.Collections.Generic.List[string]
$candidateLines.Add("# Script: $scriptName")
$candidateLines.Add("# Report date (UTC): $reportDateUtc")
$candidateLines.Add("# Target directory: $invocationDir")
$candidateLines.Add('# Subject: first-level folder size candidates in bytes (TSV: path<TAB>size_bytes)')
$candidateLines.Add('')
$items | ForEach-Object {
    $candidateLines.Add(("{0}`t{1}" -f $_.Path, $_.SizeBytes))
}
Set-Content -Path $candidatesFile -Value $candidateLines -Encoding UTF8

$capacity50Bytes = [long]([Math]::Round(46.4 * 1GB))
$capacity100Bytes = [long]([Math]::Round(93.1 * 1GB))
$mediumWorkloadMinItems = 50
$mediumWorkloadMaxItems = 500
$mediumDfsStateBudget = 250000
$script:packFallbackUsed = $false
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

    function Invoke-BestFitFallbackPack {
        param(
            [long[]]$ItemSizes,
            [array]$InitialBins
        )

        $script:packFallbackUsed = $true
        $workingBins = @()
        foreach ($bin in $InitialBins) {
            $workingBins += [PSCustomObject]@{
                CapacityBytes = [long]$bin.CapacityBytes
                UsedBytes = [long]$bin.UsedBytes
                Picks = [System.Collections.Generic.List[int]]::new()
            }
            foreach ($existingPick in $bin.Picks) {
                $null = $workingBins[-1].Picks.Add([int]$existingPick)
            }
        }

        foreach ($itemIndex in 0..($ItemSizes.Count - 1)) {
            $needed = [long]$ItemSizes[$itemIndex]
            $bestBin = $null
            $bestFreeAfter = $null
            for ($i = 0; $i -lt $workingBins.Count; $i++) {
                $free = [long]$workingBins[$i].CapacityBytes - [long]$workingBins[$i].UsedBytes
                if ($free -lt $needed) { continue }
                $freeAfter = $free - $needed
                if ($null -eq $bestBin -or $freeAfter -lt $bestFreeAfter -or ($freeAfter -eq $bestFreeAfter -and $i -lt $bestBin)) {
                    $bestBin = $i
                    $bestFreeAfter = $freeAfter
                }
            }

            if ($null -eq $bestBin) {
                return $null
            }

            $workingBins[$bestBin].UsedBytes += $needed
            $null = $workingBins[$bestBin].Picks.Add($itemIndex)
        }

        return @($workingBins | ForEach-Object {
            [PSCustomObject]@{
                CapacityBytes = [long]$_.CapacityBytes
                UsedBytes = [long]$_.UsedBytes
                Picks = @($_.Picks)
            }
        })
    }

    if ($sizes.Count -gt $mediumWorkloadMaxItems) {
        $fallbackBins = Invoke-BestFitFallbackPack -ItemSizes $sizes -InitialBins $bins
        if ($null -eq $fallbackBins) {
            return $null
        }
        $bins = $fallbackBins
    }
    else {
        $failed = [System.Collections.Generic.HashSet[string]]::new()
        $stack = [System.Collections.Generic.Stack[object]]::new()
        $statesVisited = 0
        $stack.Push([PSCustomObject]@{
            Index = 0
            Bins = $bins
        })
        $solutionBins = $null

        while ($stack.Count -gt 0) {
            $statesVisited++
            if ($statesVisited -gt $mediumDfsStateBudget) {
                $bins = @()
                foreach ($cap in $CapacitiesBytes) {
                    $bins += [PSCustomObject]@{
                        CapacityBytes = [long]$cap
                        UsedBytes = [long]0
                        Picks = [System.Collections.Generic.List[int]]::new()
                    }
                }
                $fallbackBins = Invoke-BestFitFallbackPack -ItemSizes $sizes -InitialBins $bins
                if ($null -eq $fallbackBins) {
                    return $null
                }
                $solutionBins = $fallbackBins
                break
            }

            $frame = $stack.Pop()
            $index = [int]$frame.Index
            $currentBins = $frame.Bins

            if ($index -ge $Entries.Count) {
                $solutionBins = $currentBins
                break
            }

            $freeSpaces = @()
            $totalFree = [long]0
            foreach ($bin in $currentBins) {
                $free = [long]$bin.CapacityBytes - [long]$bin.UsedBytes
                $freeSpaces += $free
                $totalFree += $free
            }

            $state = '{0}|{1}' -f $index, (($freeSpaces | Sort-Object -Descending) -join ',')
            if ($failed.Contains($state)) { continue }
            if ($totalFree -lt $suffix[$index]) {
                $null = $failed.Add($state)
                continue
            }

            $needed = [long]$Entries[$index].SizeBytes
            $candidates = New-Object System.Collections.Generic.List[object]
            $seenFree = [System.Collections.Generic.HashSet[long]]::new()

            for ($i = 0; $i -lt $currentBins.Count; $i++) {
                $free = [long]$currentBins[$i].CapacityBytes - [long]$currentBins[$i].UsedBytes
                if ($free -lt $needed) { continue }
                if (-not $seenFree.Add($free)) { continue }
                $candidates.Add([PSCustomObject]@{ BinIndex = $i })
            }

            if ($candidates.Count -eq 0) {
                $null = $failed.Add($state)
                continue
            }

            for ($candidateIndex = $candidates.Count - 1; $candidateIndex -ge 0; $candidateIndex--) {
                $pickIndex = [int]$candidates[$candidateIndex].BinIndex
                $nextBins = @()
                foreach ($bin in $currentBins) {
                    $nextBins += [PSCustomObject]@{
                        CapacityBytes = [long]$bin.CapacityBytes
                        UsedBytes = [long]$bin.UsedBytes
                        Picks = [System.Collections.Generic.List[int]]::new()
                    }
                    foreach ($existingPick in $bin.Picks) {
                        $null = $nextBins[-1].Picks.Add([int]$existingPick)
                    }
                }

                $nextBins[$pickIndex].UsedBytes += $needed
                $null = $nextBins[$pickIndex].Picks.Add($index)

                $stack.Push([PSCustomObject]@{
                    Index = $index + 1
                    Bins = $nextBins
                })
            }
        }

        if (-not $solutionBins) {
            return $null
        }

        $bins = $solutionBins
    }

    $totalPicks = [int](($bins | ForEach-Object { $_.Picks.Count } | Measure-Object -Sum).Sum)
    if ($totalPicks -ne $Entries.Count) {
        throw "Internal pack sanity check failed: picks count $totalPicks does not match entries count $($Entries.Count)."
    }

    return @($bins | ForEach-Object {
        [PSCustomObject]@{
            CapacityBytes = [long]$_.CapacityBytes
            UsedBytes = [long]$_.UsedBytes
            Picks = @($_.Picks)
        }
    })
}

function Get-OptimalMixedPlan {
    param([array]$Entries)

    if ($Entries.Count -eq 0) {
        if ($oversizedItems.Count -gt 0) { return $null }
        return [PSCustomObject]@{ Bins = @(); Count100 = 0; Count50 = 0; CapacityBytes = 0L }
    }

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
        if ($oversizedItems.Count -gt 0) { return $null }
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
        if ($oversizedItems.Count -gt 0) { return $null }
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
        [int]$AllEntriesCount,
        [int]$OversizedCount,
        [System.Collections.Generic.List[string]]$Lines
    )

    $Lines.Add(("=== {0} ===" -f $Header))

    if (-not $Plan) {
        if ($Entries.Count -eq 0 -and $OversizedCount -gt 0 -and $AllEntriesCount -eq $OversizedCount) {
            $Lines.Add('All items are oversized (> 93.1 GiB); no packable items remain.')
            $Lines.Add('')
            return
        }
        if ($OversizedCount -gt 0) {
            $Lines.Add('No feasible plan found for packable items.')
            $Lines.Add('')
            return
        }
        $Lines.Add('No feasible plan found.')
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
    if ($script:packFallbackUsed) {
        $Lines.Add(("Packing strategy: best-fit fallback used (exact DFS target range: {0}-{1} items, budget {2} explored states)." -f $mediumWorkloadMinItems, $mediumWorkloadMaxItems, $mediumDfsStateBudget))
        $Lines.Add('')
    }

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

$mixedPlan = Get-OptimalMixedPlan -Entries $packableItems
$only50Plan = Get-Optimal50OnlyPlan -Entries $packableItems
$only100Plan = Get-Optimal100OnlyPlan -Entries $packableItems

$recommendationLines = New-Object System.Collections.Generic.List[string]
$recommendationLines.Add("# Script: $scriptName")
$recommendationLines.Add("# Report date (UTC): $reportDateUtc")
$recommendationLines.Add("# Target directory: $invocationDir")
$recommendationLines.Add('# Subject: optimal Blu-ray folder packing recommendations (marketed GB labels with binary GiB capacities)')
$recommendationLines.Add('')
$recommendationLines.Add('=== OVERSIZED ===')
if ($oversizedItems.Count -gt 0) {
    foreach ($item in $oversizedItems) {
        $recommendationLines.Add(("{0} | {1:N3} GiB" -f $item.Path, ([double]$item.SizeBytes / 1GB)))
    }
}
else {
    $recommendationLines.Add('None.')
}
$recommendationLines.Add('')

Write-PlanSection -Header 'OPTIMAL MIXED DISK PLAN (50 GB marketed / 46.4 GiB + 100 GB marketed / 93.1 GiB)' -Plan $mixedPlan -Entries $packableItems -AllEntriesCount $items.Count -OversizedCount $oversizedItems.Count -Lines $recommendationLines
Write-PlanSection -Header 'OPTIMAL 50 GB-ONLY DISK PLAN (46.4 GiB usable)' -Plan $only50Plan -Entries $packableItems -AllEntriesCount $items.Count -OversizedCount $oversizedItems.Count -Lines $recommendationLines
Write-PlanSection -Header 'OPTIMAL 100 GB-ONLY DISK PLAN (93.1 GiB usable)' -Plan $only100Plan -Entries $packableItems -AllEntriesCount $items.Count -OversizedCount $oversizedItems.Count -Lines $recommendationLines

Set-Content -Path $recommendationsFile -Value $recommendationLines -Encoding UTF8

Write-Output "Wrote: $folderSizesFile"
Write-Output "Wrote: $recommendationsFile"
Write-Output "Wrote: $candidatesFile"
