[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$LlamaBench,

    [Parameter(Mandatory)]
    [string]$Model,

    [string[]]$Rpc = @(),
    [string]$DeviceList,
    [string]$TensorSplit,

    [ValidateRange(0, 999)]
    [int]$GpuLayers = 999,
    [ValidateSet('auto', 'none', 'mmap', 'mlock', 'mmap+mlock', 'dio')]
    [string]$LoadMode = 'dio',
    [ValidateSet('on', 'off', 'auto')]
    [string]$FlashAttention = 'on',
    [ValidateSet('f32', 'f16', 'bf16', 'q8_0', 'q4_0', 'q4_1', 'iq4_nl', 'q5_0', 'q5_1')]
    [string]$CacheTypeK = 'q8_0',
    [ValidateSet('f32', 'f16', 'bf16', 'q8_0', 'q4_0', 'q4_1', 'iq4_nl', 'q5_0', 'q5_1')]
    [string]$CacheTypeV = 'q8_0',

    [ValidateRange(16, 131072)]
    [int]$PromptTokens = 512,
    [ValidateRange(16, 8192)]
    [int]$GenerateTokens = 128,
    [ValidateRange(1, 20)]
    [int]$Repetitions = 3,
    [ValidateRange(32, 65536)]
    [int]$BatchSize = 2048,
    [ValidateRange(32, 65536)]
    [int[]]$UBatchSize = @(256),
    [ValidateRange(0, 1048576)]
    [int[]]$DepthTokens = @(0),
    [ValidateRange(0, 256)]
    [int]$Threads = 0,
    [ValidateSet('md', 'json', 'jsonl', 'csv')]
    [string]$OutputFormat = 'md',
    [string]$OutputPath,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function ConvertTo-CommandText {
    param([string]$Executable, [string[]]$ArgumentList)

    $quoted = @($ArgumentList | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    })
    return ('"{0}" {1}' -f $Executable, ($quoted -join ' ')).Trim()
}

if (-not (Test-Path -LiteralPath $LlamaBench -PathType Leaf)) { throw "llama-bench not found: $LlamaBench" }
if (-not (Test-Path -LiteralPath $Model -PathType Leaf)) { throw "Model not found: $Model" }
if (($DeviceList -and -not $TensorSplit) -or ($TensorSplit -and -not $DeviceList)) {
    throw 'DeviceList and TensorSplit must be supplied together.'
}
if ($UBatchSize | Where-Object { $_ -gt $BatchSize }) {
    throw 'Every UBatchSize must be less than or equal to BatchSize.'
}

if ($Threads -eq 0) {
    $coreCount = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
    if (-not $coreCount) { $coreCount = [Environment]::ProcessorCount }
    $Threads = [math]::Max(1, [int]$coreCount)
}

$arguments = @(
    '-m', $Model,
    '-p', $PromptTokens,
    '-n', $GenerateTokens,
    '-r', $Repetitions,
    '-b', $BatchSize,
    '-ub', ($UBatchSize -join ','),
    '-d', ($DepthTokens -join ','),
    '-t', $Threads,
    '-ngl', $GpuLayers,
    '-sm', 'layer',
    '-fa', $FlashAttention,
    '-ctk', $CacheTypeK,
    '-ctv', $CacheTypeV,
    '-lm', $LoadMode,
    '-o', $OutputFormat
)
if ($Rpc) { $arguments += @('-rpc', ($Rpc -join ',')) }
if ($DeviceList) {
    $devices = @($DeviceList -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $splits = @($TensorSplit -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($devices.Count -ne $splits.Count) {
        throw 'DeviceList and TensorSplit must contain the same number of entries.'
    }
    $arguments += @('-dev', ($devices -join '/'), '-ts', ($splits -join '/'))
}

$commandText = ConvertTo-CommandText $LlamaBench $arguments
Write-Host "Benchmarking: $commandText"
if ($DryRun) { return }

$global:LASTEXITCODE = 0
if ($OutputPath) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    & $LlamaBench @arguments | Tee-Object -FilePath $OutputPath
} else {
    & $LlamaBench @arguments
}
if ([int]$LASTEXITCODE -ne 0) { throw "llama-bench failed with exit code $LASTEXITCODE." }
