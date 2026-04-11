[CmdletBinding()]
param()

function New-BluRayPackingContext {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Items
    )

    $capacity50Bytes = [long]([Math]::Round(46.4 * 1GB))
    $capacity100Bytes = [long]([Math]::Round(93.1 * 1GB))
    $mediumWorkloadMinItems = 50
    $mediumWorkloadMaxItems = 500
    $mediumDfsStateBudget = 250000

    [PSCustomObject]@{
        Items = @($Items)
        OversizedItems = @($Items | Where-Object { [long]$_.SizeBytes -gt $capacity100Bytes })
        PackableItems = @($Items | Where-Object { [long]$_.SizeBytes -le $capacity100Bytes })
        Capacity50Bytes = $capacity50Bytes
        Capacity100Bytes = $capacity100Bytes
        MediumWorkloadMinItems = $mediumWorkloadMinItems
        MediumWorkloadMaxItems = $mediumWorkloadMaxItems
        MediumDfsStateBudget = $mediumDfsStateBudget
    }
}

function Get-TryPack {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Entries,
        [Parameter(Mandatory = $true)]
        [long[]]$CapacitiesBytes,
        [Parameter(Mandatory = $true)]
        [int]$MediumWorkloadMinItems,
        [Parameter(Mandatory = $true)]
        [int]$MediumWorkloadMaxItems,
        [Parameter(Mandatory = $true)]
        [int]$MediumDfsStateBudget
    )

    $usedFallback = $false
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

        if ($ItemSizes.Count -eq 0) {
            return [PSCustomObject]@{
                Success = $true
                Bins = @($workingBins | ForEach-Object {
                    [PSCustomObject]@{
                        CapacityBytes = [long]$_.CapacityBytes
                        UsedBytes = [long]$_.UsedBytes
                        Picks = @($_.Picks)
                    }
                })
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
                return [PSCustomObject]@{
                    Success = $false
                    Bins = @()
                }
            }

            $workingBins[$bestBin].UsedBytes += $needed
            $null = $workingBins[$bestBin].Picks.Add($itemIndex)
        }

        return [PSCustomObject]@{
            Success = $true
            Bins = @($workingBins | ForEach-Object {
                [PSCustomObject]@{
                    CapacityBytes = [long]$_.CapacityBytes
                    UsedBytes = [long]$_.UsedBytes
                    Picks = @($_.Picks)
                }
            })
        }
    }

    if ($sizes.Count -gt $MediumWorkloadMaxItems) {
        $usedFallback = $false
        $fallbackResult = Invoke-BestFitFallbackPack -ItemSizes $sizes -InitialBins $bins
        if (-not $fallbackResult.Success) {
            return $null
        }
        $usedFallback = $true
        $bins = $fallbackResult.Bins
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
            if ($MediumWorkloadMinItems -le $sizes.Count -and $sizes.Count -le $MediumWorkloadMaxItems -and $statesVisited -gt $MediumDfsStateBudget) {
                $bins = @()
                foreach ($cap in $CapacitiesBytes) {
                    $bins += [PSCustomObject]@{
                        CapacityBytes = [long]$cap
                        UsedBytes = [long]0
                        Picks = [System.Collections.Generic.List[int]]::new()
                    }
                }
                $usedFallback = $false
                $fallbackResult = Invoke-BestFitFallbackPack -ItemSizes $sizes -InitialBins $bins
                if (-not $fallbackResult.Success) {
                    return $null
                }
                $usedFallback = $true
                $solutionBins = $fallbackResult.Bins
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

    if ($bins.Count -gt 0) {
        $assignedCount = [int](($bins | ForEach-Object { $_.Picks.Count } | Measure-Object -Sum).Sum)
        if ($assignedCount -ne $Entries.Count) {
            return $null
        }
    }
    elseif ($Entries.Count -ne 0) {
        return $null
    }

    return [PSCustomObject]@{
        Bins = @($bins | ForEach-Object {
            [PSCustomObject]@{
                CapacityBytes = [long]$_.CapacityBytes
                UsedBytes = [long]$_.UsedBytes
                Picks = @($_.Picks)
            }
        })
        UsedFallback = [bool]$usedFallback
    }
}

function Get-OptimalMixedPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context
    )

    $entries = $Context.PackableItems
    if ($entries.Count -eq 0) {
        if ($Context.OversizedItems.Count -gt 0) { return $null }
        return [PSCustomObject]@{ Bins = @(); Count100 = 0; Count50 = 0; CapacityBytes = 0L; UsedFallback = $false }
    }

    $totalBytes = [long](($entries | Measure-Object -Property SizeBytes -Sum).Sum)
    $minDisks = [Math]::Max(1, [int][Math]::Ceiling($totalBytes / [double]$Context.Capacity100Bytes))
    $maxDisks = [int][Math]::Ceiling($totalBytes / [double]$Context.Capacity50Bytes)

    for ($diskCount = $minDisks; $diskCount -le $maxDisks; $diskCount++) {
        $pairs = @()
        for ($count100 = 0; $count100 -le $diskCount; $count100++) {
            $count50 = $diskCount - $count100
            $capacity = ([long]$count100 * $Context.Capacity100Bytes) + ([long]$count50 * $Context.Capacity50Bytes)
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
            for ($i = 0; $i -lt $pair.Count100; $i++) { $caps += $Context.Capacity100Bytes }
            for ($i = 0; $i -lt $pair.Count50; $i++) { $caps += $Context.Capacity50Bytes }

            $packResult = Get-TryPack -Entries $entries -CapacitiesBytes $caps -MediumWorkloadMinItems $Context.MediumWorkloadMinItems -MediumWorkloadMaxItems $Context.MediumWorkloadMaxItems -MediumDfsStateBudget $Context.MediumDfsStateBudget
            if ($null -ne $packResult) {
                return [PSCustomObject]@{
                    Bins = $packResult.Bins
                    Count100 = $pair.Count100
                    Count50 = $pair.Count50
                    CapacityBytes = [long]$pair.CapacityBytes
                    UsedFallback = [bool]$packResult.UsedFallback
                }
            }
        }
    }

    return $null
}

function Get-Optimal50OnlyPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context
    )

    $entries = $Context.PackableItems
    if ($entries.Count -eq 0) {
        if ($Context.OversizedItems.Count -gt 0) { return $null }
        return [PSCustomObject]@{ Bins = @(); Count100 = 0; Count50 = 0; CapacityBytes = 0L; UsedFallback = $false }
    }

    $maxItem = ($entries | Measure-Object -Property SizeBytes -Maximum).Maximum
    if ([long]$maxItem -gt $Context.Capacity50Bytes) { return $null }

    $totalBytes = [long](($entries | Measure-Object -Property SizeBytes -Sum).Sum)
    $startCount = [Math]::Max(1, [int][Math]::Ceiling($totalBytes / [double]$Context.Capacity50Bytes))
    for ($count50 = $startCount; $count50 -le $entries.Count; $count50++) {
        $caps = @()
        for ($i = 0; $i -lt $count50; $i++) { $caps += $Context.Capacity50Bytes }
        $packResult = Get-TryPack -Entries $entries -CapacitiesBytes $caps -MediumWorkloadMinItems $Context.MediumWorkloadMinItems -MediumWorkloadMaxItems $Context.MediumWorkloadMaxItems -MediumDfsStateBudget $Context.MediumDfsStateBudget
        if ($null -ne $packResult) {
            return [PSCustomObject]@{
                Bins = $packResult.Bins
                Count100 = 0
                Count50 = $count50
                CapacityBytes = [long]($count50 * $Context.Capacity50Bytes)
                UsedFallback = [bool]$packResult.UsedFallback
            }
        }
    }
    return $null
}

function Get-Optimal100OnlyPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context
    )

    $entries = $Context.PackableItems
    if ($entries.Count -eq 0) {
        if ($Context.OversizedItems.Count -gt 0) { return $null }
        return [PSCustomObject]@{ Bins = @(); Count100 = 0; Count50 = 0; CapacityBytes = 0L; UsedFallback = $false }
    }

    $maxItem = ($entries | Measure-Object -Property SizeBytes -Maximum).Maximum
    if ([long]$maxItem -gt $Context.Capacity100Bytes) { return $null }

    $totalBytes = [long](($entries | Measure-Object -Property SizeBytes -Sum).Sum)
    $startCount = [Math]::Max(1, [int][Math]::Ceiling($totalBytes / [double]$Context.Capacity100Bytes))
    for ($count100 = $startCount; $count100 -le $entries.Count; $count100++) {
        $caps = @()
        for ($i = 0; $i -lt $count100; $i++) { $caps += $Context.Capacity100Bytes }
        $packResult = Get-TryPack -Entries $entries -CapacitiesBytes $caps -MediumWorkloadMinItems $Context.MediumWorkloadMinItems -MediumWorkloadMaxItems $Context.MediumWorkloadMaxItems -MediumDfsStateBudget $Context.MediumDfsStateBudget
        if ($null -ne $packResult) {
            return [PSCustomObject]@{
                Bins = $packResult.Bins
                Count100 = $count100
                Count50 = 0
                CapacityBytes = [long]($count100 * $Context.Capacity100Bytes)
                UsedFallback = [bool]$packResult.UsedFallback
            }
        }
    }
    return $null
}

function Write-PlanSection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Header,
        [object]$Plan,
        [Parameter(Mandatory = $true)]
        [object]$Context,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$Lines
    )

    $entries = $Context.PackableItems
    $allEntriesCount = $Context.Items.Count
    $oversizedCount = $Context.OversizedItems.Count

    $Lines.Add(("=== {0} ===" -f $Header))

    if (-not $Plan) {
        if ($entries.Count -eq 0 -and $oversizedCount -gt 0 -and $allEntriesCount -eq $oversizedCount) {
            $Lines.Add('All items are oversized (> 93.1 GiB); no packable items remain.')
            $Lines.Add('')
            return
        }
        if ($oversizedCount -gt 0) {
            $Lines.Add('No feasible plan found for packable items.')
            $Lines.Add('')
            return
        }
        $Lines.Add('No feasible plan found.')
        $Lines.Add('')
        return
    }

    $totalBytes = [long](($entries | Measure-Object -Property SizeBytes -Sum).Sum)
    $totalDisks = $Plan.Count100 + $Plan.Count50
    $unusedBytes = [long]$Plan.CapacityBytes - $totalBytes

    $Lines.Add(("Combination: {0} x 100 GB marketed (93.1 GiB) + {1} x 50 GB marketed (46.4 GiB)" -f $Plan.Count100, $Plan.Count50))
    $Lines.Add(("Total disks: {0}" -f $totalDisks))
    $Lines.Add(("Disk counts by size (marketed): 100GB={0}, 50GB={1}" -f $Plan.Count100, $Plan.Count50))
    $Lines.Add(("Total data size: {0:N3} GiB" -f ($totalBytes / 1GB)))
    $Lines.Add(("Total writable capacity: {0:N3} GiB" -f ($Plan.CapacityBytes / 1GB)))
    $Lines.Add(("Total unused space: {0:N3} GiB" -f ($unusedBytes / 1GB)))
    $Lines.Add('')
    if ($Plan.UsedFallback) {
        $Lines.Add(("Packing strategy: best-fit fallback used (exact DFS target range: {0}-{1} items, budget {2} explored states)." -f $Context.MediumWorkloadMinItems, $Context.MediumWorkloadMaxItems, $Context.MediumDfsStateBudget))
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
            $Lines.Add($entries[$pick].Path)
        }
        $Lines.Add('')
        $diskIndex++
    }
}

function Write-BluRayRecommendationFile {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context,
        [Parameter(Mandatory = $true)]
        [string]$RecommendationsFile,
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,
        [Parameter(Mandatory = $true)]
        [string]$ReportDateUtc,
        [Parameter(Mandatory = $true)]
        [string]$TargetDirectory,
        [Parameter(Mandatory = $true)]
        [string]$Subject
    )

    $mixedPlan = Get-OptimalMixedPlan -Context $Context
    $only50Plan = Get-Optimal50OnlyPlan -Context $Context
    $only100Plan = Get-Optimal100OnlyPlan -Context $Context

    $recommendationLines = New-Object System.Collections.Generic.List[string]
    $recommendationLines.Add("# Script: $ScriptName")
    $recommendationLines.Add("# Report date (UTC): $ReportDateUtc")
    $recommendationLines.Add("# Target directory: $TargetDirectory")
    $recommendationLines.Add(("# Subject: {0}" -f $Subject))
    $recommendationLines.Add('')
    $recommendationLines.Add('=== OVERSIZED ===')
    if ($Context.OversizedItems.Count -gt 0) {
        foreach ($item in $Context.OversizedItems) {
            $recommendationLines.Add(("{0} | {1:N3} GiB" -f $item.Path, ([double]$item.SizeBytes / 1GB)))
        }
    }
    else {
        $recommendationLines.Add('None.')
    }
    $recommendationLines.Add('')

    Write-PlanSection -Header 'OPTIMAL MIXED DISK PLAN (50 GB marketed / 46.4 GiB + 100 GB marketed / 93.1 GiB)' -Plan $mixedPlan -Context $Context -Lines $recommendationLines
    Write-PlanSection -Header 'OPTIMAL 50 GB-ONLY DISK PLAN (46.4 GiB usable)' -Plan $only50Plan -Context $Context -Lines $recommendationLines
    Write-PlanSection -Header 'OPTIMAL 100 GB-ONLY DISK PLAN (93.1 GiB usable)' -Plan $only100Plan -Context $Context -Lines $recommendationLines

    Set-Content -LiteralPath $RecommendationsFile -Value $recommendationLines -Encoding UTF8
}
