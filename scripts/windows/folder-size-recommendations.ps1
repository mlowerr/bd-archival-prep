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
        Size = $sizeGb
    }

    Add-Content -Path $folderSizesFile -Value ("{0} | {1:N3} GB" -f $dir.FullName, $sizeGb)
}

$items = $items | Sort-Object -Property Size -Descending
$limits = @(46.4, 93.1)
$topK = 3

function Get-BestSubsets {
    param(
        [array]$Entries,
        [double]$Limit,
        [int]$Take
    )

    $sizes = @($Entries | ForEach-Object { [double]$_.Size })
    $suffix = New-Object double[] ($sizes.Count + 1)
    for ($i = $sizes.Count - 1; $i -ge 0; $i--) {
        $suffix[$i] = $suffix[$i + 1] + $sizes[$i]
    }

    $script:results = [System.Collections.Generic.List[object]]::new()
    $script:seen = [System.Collections.Generic.HashSet[string]]::new()

    function Add-Result {
        param([double]$Used, [long]$Mask, [int]$Take)

        $key = '{0}|{1}' -f $Mask, ([Math]::Round($Used, 6))
        if (-not $script:seen.Add($key)) { return }

        $script:results.Add([PSCustomObject]@{ Used = $Used; Mask = $Mask })
        $ordered = @($script:results | Sort-Object -Property Used -Descending)
        if ($ordered.Count -gt $Take) {
            $ordered = $ordered[0..($Take - 1)]
        }

        $trimmed = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in $ordered) { $trimmed.Add($entry) }
        $script:results = $trimmed
    }

    function Dive {
        param([int]$Index, [double]$Used, [long]$Mask, [array]$Entries, [double[]]$Suffix, [double]$Limit, [int]$Take)

        if ($Used -gt ($Limit + 1e-9)) { return }
        if ($Index -ge $Entries.Count) {
            Add-Result -Used $Used -Mask $Mask -Take $Take
            return
        }

        $floor = -1.0
        if ($script:results.Count -ge $Take) {
            $floor = (@($script:results | Sort-Object -Property Used)[0]).Used
        }

        if (($Used + $Suffix[$Index]) -lt ($floor - 1e-9)) { return }

        Dive -Index ($Index + 1) -Used ($Used + [double]$Entries[$Index].Size) -Mask ($Mask -bor (1 -shl $Index)) -Entries $Entries -Suffix $Suffix -Limit $Limit -Take $Take
        Dive -Index ($Index + 1) -Used $Used -Mask $Mask -Entries $Entries -Suffix $Suffix -Limit $Limit -Take $Take
    }

    Dive -Index 0 -Used 0.0 -Mask 0 -Entries $Entries -Suffix $suffix -Limit $Limit -Take $Take
    return @($script:results | Sort-Object -Property Used -Descending)
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
        $unused = [double]$limit - [double]$rec.Used
        Add-Content -Path $recommendationsFile -Value (
            "[{0:N1} GB] Blu Ray Disk [{1} of recommendation] | Size used: {2:N3} GB | Unused space: {3:N3} GB" -f $limit, $idx, $rec.Used, $unused
        )

        for ($bit = 0; $bit -lt $items.Count; $bit++) {
            if (($rec.Mask -band (1 -shl $bit)) -ne 0) {
                Add-Content -Path $recommendationsFile -Value $items[$bit].Path
            }
        }

        Add-Content -Path $recommendationsFile -Value ""
        $idx++
    }
}

Write-Output "Wrote: $folderSizesFile"
Write-Output "Wrote: $recommendationsFile"
