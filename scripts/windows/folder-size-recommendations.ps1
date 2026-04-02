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
$limits = @(46.4, 93.1)
$topK = 3

function Get-BestSubsets {
    param(
        [array]$Entries,
        [double]$Limit,
        [int]$Take
    )

    $sizes = @($Entries | ForEach-Object { [long]$_.SizeBytes })
    $suffix = New-Object long[] ($sizes.Count + 1)
    for ($i = $sizes.Count - 1; $i -ge 0; $i--) {
        $suffix[$i] = $suffix[$i + 1] + $sizes[$i]
    }
    $limitBytes = $Limit * 1GB

    $script:results = [System.Collections.Generic.List[object]]::new()
    $script:seen = [System.Collections.Generic.HashSet[string]]::new()

    function Add-Result {
        param([long]$UsedBytes, [int[]]$Picks, [int]$Take)

        $pickKey = if ($Picks.Count -gt 0) { ($Picks -join ',') } else { '-' }
        $key = '{0}|{1}' -f $pickKey, $UsedBytes
        if (-not $script:seen.Add($key)) { return }

        $script:results.Add([PSCustomObject]@{ UsedBytes = $UsedBytes; Picks = @($Picks) })
        $ordered = @($script:results | Sort-Object -Property UsedBytes -Descending)
        if ($ordered.Count -gt $Take) {
            $ordered = $ordered[0..($Take - 1)]
        }

        $trimmed = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in $ordered) { $trimmed.Add($entry) }
        $script:results = $trimmed
    }

    function Dive {
        param([int]$Index, [long]$UsedBytes, [int[]]$Picks, [array]$Entries, [long[]]$Suffix, [double]$LimitBytes, [int]$Take)

        if ($UsedBytes -gt ($LimitBytes + 1e-6)) { return }
        if ($Index -ge $Entries.Count) {
            Add-Result -UsedBytes $UsedBytes -Picks $Picks -Take $Take
            return
        }

        $floor = -1
        if ($script:results.Count -ge $Take) {
            $floor = (@($script:results | Sort-Object -Property UsedBytes)[0]).UsedBytes
        }

        if (($UsedBytes + $Suffix[$Index]) -lt $floor) { return }

        Dive -Index ($Index + 1) -UsedBytes ($UsedBytes + [long]$Entries[$Index].SizeBytes) -Picks (@($Picks + $Index)) -Entries $Entries -Suffix $Suffix -LimitBytes $LimitBytes -Take $Take
        Dive -Index ($Index + 1) -UsedBytes $UsedBytes -Picks $Picks -Entries $Entries -Suffix $Suffix -LimitBytes $LimitBytes -Take $Take
    }

    Dive -Index 0 -UsedBytes 0 -Picks @() -Entries $Entries -Suffix $suffix -LimitBytes $limitBytes -Take $Take
    return @($script:results | Sort-Object -Property UsedBytes -Descending)
}

foreach ($limit in $limits) {
    $recs = Get-BestSubsets -Entries $items -Limit ([double]$limit) -Take $topK
    if (-not $recs -or $recs.Count -eq 0) {
        Add-Content -Path $recommendationsFile -Value ("[{0:N1} GB] Blu Ray Disk [1 of recommendation] | Size used: 0.000 GB | Unused space: {1:N3} GB" -f $limit, $limit)
        Add-Content -Path $recommendationsFile -Value ""
        continue
    }

    $idx = 1
    foreach ($rec in $recs) {
        $usedGb = [double]$rec.UsedBytes / 1GB
        $unused = [double]$limit - $usedGb
        Add-Content -Path $recommendationsFile -Value (
            "[{0:N1} GB] Blu Ray Disk [{1} of recommendation] | Size used: {2:N3} GB | Unused space: {3:N3} GB" -f $limit, $idx, $usedGb, $unused
        )

        foreach ($pick in $rec.Picks) {
            Add-Content -Path $recommendationsFile -Value $items[$pick].Path
        }

        Add-Content -Path $recommendationsFile -Value ""
        $idx++
    }
}

Write-Output "Wrote: $folderSizesFile"
Write-Output "Wrote: $recommendationsFile"
