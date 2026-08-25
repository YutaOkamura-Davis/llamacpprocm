[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Server,

    [Parameter(Mandatory)]
    [string]$Model,

    [string[]]$Rpc = @(),
    [string]$DeviceList,
    [string]$TensorSplit,

    [string]$DraftModel,
    [ValidateSet('draft-dflash', 'draft-dspark', 'draft-mtp', 'draft-simple', 'draft-eagle3')]
    [string]$SpecType = 'draft-dflash',
    [string]$DraftDevice = 'CUDA0',
    [ValidateRange(1, 16)]
    [int]$DraftTokens = 4,
    [ValidateRange(-1, 1)]
    [double]$DraftPMin = -1,
    [ValidatePattern('^(auto|all|\d+)$')]
    [string]$DraftGpuLayers = 'all',

    [ValidatePattern('^(auto|all|\d+)$')]
    [string]$GpuLayers = 'all',
    [ValidateSet('on', 'off')]
    [string]$Fit = 'off',
    [string]$FitTargetMiB,
    [ValidateSet('auto', 'none', 'mmap', 'mlock', 'mmap+mlock', 'dio')]
    [string]$LoadMode = 'dio',

    [ValidateRange(4096, 1048576)]
    [int]$ContextSize = 32768,
    [ValidateRange(1, 32)]
    [int]$ParallelSlots = 1,
    [ValidateRange(32, 65536)]
    [int]$BatchSize = 2048,
    [ValidateRange(32, 65536)]
    [int]$UBatchSize = 256,
    [ValidateRange(0, 256)]
    [int]$Threads = 0,
    [ValidateRange(0, 256)]
    [int]$ThreadsBatch = 0,

    [ValidateSet('on', 'off', 'auto')]
    [string]$FlashAttention = 'on',
    [ValidateSet('f32', 'f16', 'bf16', 'q8_0', 'q4_0', 'q4_1', 'iq4_nl', 'q5_0', 'q5_1')]
    [string]$CacheTypeK = 'q8_0',
    [ValidateSet('f32', 'f16', 'bf16', 'q8_0', 'q4_0', 'q4_1', 'iq4_nl', 'q5_0', 'q5_1')]
    [string]$CacheTypeV = 'q8_0',
    [ValidateSet('f32', 'f16', 'bf16', 'q8_0', 'q4_0', 'q4_1', 'iq4_nl', 'q5_0', 'q5_1')]
    [string]$DraftCacheTypeK = 'f16',
    [ValidateSet('f32', 'f16', 'bf16', 'q8_0', 'q4_0', 'q4_1', 'iq4_nl', 'q5_0', 'q5_1')]
    [string]$DraftCacheTypeV = 'f16',
    [ValidateRange(-1, 1048576)]
    [int]$CacheRamMiB = 0,

    [string]$HostAddress = '127.0.0.1',
    [ValidateRange(1, 65535)]
    [int]$Port = 8080,
    [string]$ApiKeyFile,
    [ValidateRange(100, 60000)]
    [int]$RpcTimeoutMilliseconds = 3000,

    [switch]$NoKvUnified,
    [switch]$NoPromptCache,
    [switch]$NoJinja,
    [switch]$ReasoningPreserve,
    [switch]$Metrics,
    [switch]$FitPrint,
    [switch]$AllowUnauthenticatedHttp,
    [switch]$SkipRpcCheck,
    [switch]$DryRun,
    [string[]]$ExtraArgument = @()
)

$ErrorActionPreference = 'Stop'

function Split-RpcEndpoint {
    param([string]$Endpoint)

    if ($Endpoint -match '^\[([^\]]+)\]:([0-9]+)$' -or $Endpoint -match '^([^:]+):([0-9]+)$') {
        $portValue = [int]$matches[2]
        if ($portValue -lt 1 -or $portValue -gt 65535) { throw "Invalid RPC port in $Endpoint" }
        return [pscustomobject]@{ Host = $matches[1]; Port = $portValue; Endpoint = $Endpoint }
    }
    throw "Invalid RPC endpoint '$Endpoint'. Use host:port or [IPv6]:port."
}

function Test-TcpEndpoint {
    param([string]$ComputerName, [int]$TcpPort, [int]$TimeoutMilliseconds)

    $client = [Net.Sockets.TcpClient]::new()
    try {
        $result = $client.BeginConnect($ComputerName, $TcpPort, $null, $null)
        if (-not $result.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) { return $false }
        $client.EndConnect($result)
        return $true
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function ConvertTo-CommandText {
    param([string]$Executable, [string[]]$ArgumentList)

    $display = [Collections.Generic.List[string]]::new()
    $redactNext = $false
    foreach ($argument in $ArgumentList) {
        $value = if ($redactNext) { '<redacted>' } else { [string]$argument }
        $redactNext = $argument -in @('--api-key', '--hf-token')
        if ($value -match '[\s"]') { $value = '"' + ($value -replace '"', '\"') + '"' }
        $display.Add($value)
    }
    return ('"{0}" {1}' -f $Executable, ($display -join ' ')).Trim()
}

if (-not (Test-Path -LiteralPath $Server -PathType Leaf)) { throw "Server executable not found: $Server" }
if (-not (Test-Path -LiteralPath $Model -PathType Leaf)) { throw "Model not found: $Model" }
if ($DraftModel -and -not (Test-Path -LiteralPath $DraftModel -PathType Leaf)) {
    throw "Draft model not found: $DraftModel"
}
if (($DeviceList -and -not $TensorSplit) -or ($TensorSplit -and -not $DeviceList)) {
    throw 'DeviceList and TensorSplit must be supplied together.'
}

if ($DeviceList) {
    $devices = @($DeviceList -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $splits = @($TensorSplit -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($devices.Count -ne $splits.Count) {
        throw 'DeviceList and TensorSplit must contain the same number of entries.'
    }
    foreach ($value in $splits) {
        $parsed = 0.0
        if (-not [double]::TryParse($value, [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -or $parsed -lt 0) {
            throw "Invalid TensorSplit value: $value"
        }
    }
    $DeviceList = $devices -join ','
    $TensorSplit = $splits -join ','
    if (-not $Rpc -and ($devices | Where-Object { $_ -match '^RPC[0-9]+$' })) {
        throw 'DeviceList contains RPC devices but no Rpc endpoint was supplied.'
    }
}

$rpcEndpoints = @($Rpc | ForEach-Object { Split-RpcEndpoint $_ })
if (($rpcEndpoints.Endpoint | Sort-Object -Unique).Count -ne $rpcEndpoints.Count) {
    throw 'RPC endpoints must be unique.'
}
if ($rpcEndpoints -and -not $SkipRpcCheck -and -not $DryRun) {
    $failed = @($rpcEndpoints | Where-Object {
        -not (Test-TcpEndpoint $_.Host $_.Port $RpcTimeoutMilliseconds)
    })
    if ($failed) {
        throw "RPC preflight failed: $($failed.Endpoint -join ', ')"
    }
}

$quantizedTypes = @('q8_0', 'q4_0', 'q4_1', 'iq4_nl', 'q5_0', 'q5_1')
if (($CacheTypeV -in $quantizedTypes -or ($DraftModel -and $DraftCacheTypeV -in $quantizedTypes)) -and
    $FlashAttention -ne 'on') {
    throw 'Quantized V cache requires -FlashAttention on. Use f16/bf16 V cache to select auto or off.'
}
if ($UBatchSize -gt $BatchSize) { throw 'UBatchSize cannot exceed BatchSize.' }

if ($Threads -eq 0) {
    $coreCount = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
    if (-not $coreCount) { $coreCount = [Environment]::ProcessorCount }
    $Threads = [math]::Max(1, [int]$coreCount)
}
if ($ThreadsBatch -eq 0) { $ThreadsBatch = $Threads }

$loopbackNames = @('127.0.0.1', '::1', 'localhost')
if ($HostAddress -notin $loopbackNames -and -not $ApiKeyFile -and -not $AllowUnauthenticatedHttp) {
    throw 'A non-loopback HTTP bind requires ApiKeyFile or -AllowUnauthenticatedHttp.'
}
if ($ApiKeyFile -and -not (Test-Path -LiteralPath $ApiKeyFile -PathType Leaf)) {
    throw "API key file not found: $ApiKeyFile"
}

$arguments = @(
    '-m', $Model,
    '--split-mode', 'layer',
    '--n-gpu-layers', $GpuLayers,
    '--fit', $Fit,
    '--load-mode', $LoadMode,
    '--ctx-size', $ContextSize,
    '--parallel', $ParallelSlots,
    '--batch-size', $BatchSize,
    '--ubatch-size', $UBatchSize,
    '--threads', $Threads,
    '--threads-batch', $ThreadsBatch,
    '--flash-attn', $FlashAttention,
    '--cache-type-k', $CacheTypeK,
    '--cache-type-v', $CacheTypeV,
    '--cache-ram', $CacheRamMiB,
    '--host', $HostAddress,
    '--port', $Port
)

if ($rpcEndpoints) { $arguments += @('--rpc', ($rpcEndpoints.Endpoint -join ',')) }
if ($DeviceList) {
    $arguments += @('--device', $DeviceList, '--tensor-split', $TensorSplit)
}
if ($FitTargetMiB) { $arguments += @('--fit-target', $FitTargetMiB) }
if ($FitPrint) { $arguments += @('--fit-print', 'on') }
if ($NoKvUnified) { $arguments += '--no-kv-unified' } else { $arguments += '--kv-unified' }
if ($NoPromptCache) { $arguments += '--no-cache-prompt' } else { $arguments += '--cache-prompt' }
if ($CacheRamMiB -eq 0) { $arguments += '--no-cache-idle-slots' }
if ($NoJinja) { $arguments += '--no-jinja' } else { $arguments += '--jinja' }
if ($ReasoningPreserve) { $arguments += '--reasoning-preserve' }
if ($Metrics) { $arguments += '--metrics' }
if ($ApiKeyFile) { $arguments += @('--api-key-file', (Resolve-Path -LiteralPath $ApiKeyFile).Path) }

if ($DraftModel) {
    $arguments += @(
        '--spec-draft-model', $DraftModel,
        '--spec-type', $SpecType,
        '--spec-draft-device', $DraftDevice,
        '--spec-draft-ngl', $DraftGpuLayers,
        '--spec-draft-n-max', $DraftTokens,
        '--spec-draft-type-k', $DraftCacheTypeK,
        '--spec-draft-type-v', $DraftCacheTypeV
    )
    if ($DraftPMin -ge 0) { $arguments += @('--spec-draft-p-min', $DraftPMin) }
}

$arguments += $ExtraArgument
$commandText = ConvertTo-CommandText $Server $arguments
Write-Host "Launching: $commandText"
if ($rpcEndpoints) {
    Write-Warning 'RPC is unauthenticated and unencrypted. Keep every worker on peer-firewalled private links.'
}
if ($Fit -eq 'on' -and $DeviceList) {
    Write-Warning 'Fit is enabled with an explicit placement. Verify startup logs because fit cannot freely replace every pinned value.'
}
if ($DraftModel -and $ParallelSlots -gt 1) {
    Write-Warning 'DFlash2/Vulkan currently has multi-slot performance and stability reports. Qualify with ParallelSlots 1 first.'
}
if ($DraftModel -and $DraftTokens -gt 4 -and $ContextSize -ge 32768) {
    Write-Warning 'Published Strix Halo results favored four draft tokens at 32K. Treat this wider draft as a benchmark challenger.'
}
if ($DryRun) { return }

& $Server @arguments
exit $LASTEXITCODE
