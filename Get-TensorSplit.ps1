[CmdletBinding(DefaultParameterSetName = 'Size')]
param(
    [Parameter(Mandatory)]
    [string[]]$Device,

    [Parameter(Mandatory)]
    [double[]]$FreeMiB,

    [Parameter(Mandatory)]
    [double[]]$ReserveMiB,

    [Parameter(Mandatory, ParameterSetName = 'Size')]
    [ValidateRange(0.01, 4096)]
    [double]$ModelGiB,

    [Parameter(Mandatory, ParameterSetName = 'Path')]
    [string[]]$ModelPath,

    [double[]]$RelativeSpeed,

    [ValidateSet('Fastest', 'Balanced', 'Capacity')]
    [string]$PlacementMode = 'Fastest',

    [ValidateRange(1, 100)]
    [double]$OffloadPercent = 100,

    [ValidateRange(0, 20)]
    [double]$WeightOverheadPercent = 4
)

$ErrorActionPreference = 'Stop'
$invariant = [Globalization.CultureInfo]::InvariantCulture

function Get-ModelFiles {
    param([string[]]$Path)

    $resolved = [Collections.Generic.List[string]]::new()
    foreach ($entry in $Path) {
        if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
            throw "Model file not found: $entry"
        }
        $item = Get-Item -LiteralPath $entry
        if ($item.Name -match '^(.*)-[0-9]{5}-of-([0-9]{5})\.gguf$') {
            $prefix = $matches[1]
            $countText = $matches[2]
            $count = [int]$countText
            $shards = @(Get-ChildItem -LiteralPath $item.DirectoryName -File | Where-Object {
                $_.Name -match ('^{0}-[0-9]{{5}}-of-{1}\.gguf$' -f [regex]::Escape($prefix), $countText)
            } | Sort-Object Name)
            if ($shards.Count -ne $count) {
                throw "Expected $count GGUF shards beside $entry, found $($shards.Count)."
            }
            foreach ($shard in $shards) {
                if (-not $resolved.Contains($shard.FullName)) { $resolved.Add($shard.FullName) }
            }
        } elseif (-not $resolved.Contains($item.FullName)) {
            $resolved.Add($item.FullName)
        }
    }
    return $resolved.ToArray()
}

if ($Device.Count -eq 0) { throw 'At least one device is required.' }
if ($Device.Count -ne $FreeMiB.Count -or $Device.Count -ne $ReserveMiB.Count) {
    throw 'Device, FreeMiB, and ReserveMiB must have identical lengths.'
}
if (($Device | Sort-Object -Unique).Count -ne $Device.Count) {
    throw 'Device names must be unique and in llama.cpp --list-devices order.'
}
if (-not $RelativeSpeed) {
    $RelativeSpeed = @(1..$Device.Count | ForEach-Object { 1.0 })
}
if ($RelativeSpeed.Count -ne $Device.Count) {
    throw 'RelativeSpeed must be omitted or have the same length as Device.'
}
if ($RelativeSpeed | Where-Object { $_ -le 0 }) {
    throw 'Every RelativeSpeed value must be greater than zero.'
}

$usable = @()
for ($i = 0; $i -lt $Device.Count; $i++) {
    if ($FreeMiB[$i] -le 0 -or $ReserveMiB[$i] -lt 0) {
        throw 'FreeMiB must be positive and ReserveMiB must be non-negative.'
    }
    $value = [math]::Floor($FreeMiB[$i] - $ReserveMiB[$i])
    if ($value -le 0) { throw "No usable memory remains on $($Device[$i])." }
    $usable += [double]$value
}

$modelFiles = @()
$effectiveModelGiB = $ModelGiB
if ($PSCmdlet.ParameterSetName -eq 'Path') {
    $modelFiles = @(Get-ModelFiles $ModelPath)
    $modelBytes = ($modelFiles | ForEach-Object { (Get-Item -LiteralPath $_).Length } | Measure-Object -Sum).Sum
    $effectiveModelGiB = $modelBytes / 1GB
}

$offloadedWeightMiB = $effectiveModelGiB * 1024 * ($OffloadPercent / 100)
$requiredMiB = $offloadedWeightMiB * (1 + $WeightOverheadPercent / 100)
$availableMiB = ($usable | Measure-Object -Sum).Sum
if ($availableMiB -lt $requiredMiB) {
    throw ('Insufficient target capacity: need approximately {0:N0} MiB, have {1:N0} MiB after reserves.' -f `
        $requiredMiB, $availableMiB)
}

$allocation = @(1..$Device.Count | ForEach-Object { 0.0 })
switch ($PlacementMode) {
    'Capacity' {
        for ($i = 0; $i -lt $Device.Count; $i++) {
            $allocation[$i] = $requiredMiB * $usable[$i] / $availableMiB
        }
    }
    'Fastest' {
        $remaining = $requiredMiB
        $rankedEntries = @(for ($i = 0; $i -lt $Device.Count; $i++) {
            [pscustomobject]@{ Index = $i; Speed = $RelativeSpeed[$i]; Capacity = $usable[$i] }
        })
        $ranked = @($rankedEntries | Sort-Object `
            @{ Expression = 'Speed'; Descending = $true }, `
            @{ Expression = 'Index'; Descending = $false })
        foreach ($entry in $ranked) {
            if ($remaining -le 0.001) { break }
            $take = [math]::Min($entry.Capacity, $remaining)
            $allocation[$entry.Index] = $take
            $remaining -= $take
        }
    }
    'Balanced' {
        $remaining = $requiredMiB
        $active = [Collections.Generic.List[int]]::new()
        for ($i = 0; $i -lt $Device.Count; $i++) { $active.Add($i) }
        while ($remaining -gt 0.001 -and $active.Count -gt 0) {
            $speedSum = 0.0
            foreach ($index in $active) { $speedSum += $RelativeSpeed[$index] }
            $saturated = [Collections.Generic.List[int]]::new()
            foreach ($index in @($active)) {
                $ideal = $remaining * $RelativeSpeed[$index] / $speedSum
                $room = $usable[$index] - $allocation[$index]
                if ($ideal -gt $room + 0.001) {
                    $saturated.Add($index)
                }
            }
            if ($saturated.Count -eq 0) {
                foreach ($index in $active) {
                    $allocation[$index] += $remaining * $RelativeSpeed[$index] / $speedSum
                }
                $remaining = 0
            } else {
                foreach ($index in $saturated) {
                    $room = $usable[$index] - $allocation[$index]
                    $allocation[$index] += $room
                    $remaining -= $room
                    [void]$active.Remove($index)
                }
            }
        }
    }
}

$selected = @(for ($i = 0; $i -lt $Device.Count; $i++) {
    if ($allocation[$i] -gt 0.5) {
        [pscustomobject]@{
            Device = $Device[$i]
            FreeMiB = [math]::Round($FreeMiB[$i], 1)
            ReserveMiB = [math]::Round($ReserveMiB[$i], 1)
            UsableMiB = [math]::Round($usable[$i], 1)
            RelativeSpeed = [math]::Round($RelativeSpeed[$i], 3)
            AssignedMiB = [math]::Round($allocation[$i], 1)
            RemainingHeadroomMiB = [math]::Round($usable[$i] - $allocation[$i], 1)
        }
    }
})

$splitValues = @($selected | ForEach-Object { $_.AssignedMiB.ToString('0.0', $invariant) })
[ordered]@{
    PlacementMode = $PlacementMode
    DeviceList = ($selected.Device -join ',')
    TensorSplit = ($splitValues -join ',')
    ModelFiles = $modelFiles
    ModelFileGiB = [math]::Round($effectiveModelGiB, 3)
    OffloadPercent = $OffloadPercent
    EstimatedHostWeightMiB = [math]::Ceiling($effectiveModelGiB * 1024 * (1 - $OffloadPercent / 100))
    WeightOverheadPercent = $WeightOverheadPercent
    EstimatedRequiredMiB = [math]::Ceiling($requiredMiB)
    TotalUsableMiB = [math]::Floor($availableMiB)
    UnusedUsableMiB = [math]::Floor($availableMiB - $requiredMiB)
    Devices = $selected
} | ConvertTo-Json -Depth 8
