[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Model,
    [string]$InstallDirectory = 'C:\llm-runtimes\vllm-windows-cuda',
    [ValidateSet('127.0.0.1', 'localhost', '::1')][string]$HostAddress = '127.0.0.1',
    [ValidateRange(1, 65535)][int]$Port = 8000,
    [ValidateRange(128, 1048576)][int]$MaxModelLength = 8192,
    [ValidateRange(0.10, 0.95)][double]$GpuMemoryUtilization = 0.82,
    [ValidateRange(1, 256)][int]$MaxNumSeqs = 8,
    [ValidateRange(1, 16)][int]$TensorParallelSize = 1,
    [ValidateRange(1, 16)][int]$PipelineParallelSize = 1,
    [ValidateRange(0, 1024)][int]$CpuOffloadGiB = 0,
    [ValidateSet('auto', 'bfloat16', 'fp8')][string]$KvCacheDtype = 'auto',
    [ValidateSet('AUTO', 'NONE', 'PIECEWISE', 'FULL')][string]$CudagraphMode = 'NONE',
    [ValidatePattern('^$|^[0-9]+(?:,[0-9]+)*$')][string]$CudaVisibleDevices = '',
    [string]$NcclDllPath = '',
    [string[]]$ExtraArgument = @(),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ExpectedWheelHash = '3e15c3b8f847b47a87582c9a4451a88b6ab4ecad2d7e44298e3f4d43c7bf0f98'
$python = Join-Path $InstallDirectory '.venv\Scripts\python.exe'
$recordPath = Join-Path $InstallDirectory 'install-record.json'
if (-not (Test-Path -LiteralPath $python -PathType Leaf) -or
    -not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
    throw "Pinned Windows CUDA vLLM environment not found at $InstallDirectory. Run Install-vLLM-WindowsCUDA.ps1 first."
}
$record = Get-Content -Raw -LiteralPath $recordPath | ConvertFrom-Json
if ($record.WheelSha256 -ne $ExpectedWheelHash -or $record.Release -ne 'v0.26.0') {
    throw 'Install record does not match the v4-pinned native Windows CUDA wheel.'
}

$isLocal = Test-Path -LiteralPath $Model
$isHubId = $Model -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
if (-not $isLocal -and -not $isHubId) { throw 'Model must be a local path or owner/repository Hugging Face ID.' }
if ($isLocal) { $Model = (Resolve-Path -LiteralPath $Model).Path }

$reserved = @($ExtraArgument | Where-Object {
    $_ -match '^--(host|port|max-model-len|gpu-memory-utilization|max-num-seqs|tensor-parallel-size|pipeline-parallel-size|cpu-offload-gb|kv-cache-dtype)(=|$)'
})
if ($reserved) { throw "ExtraArgument cannot override wrapper-owned settings: $($reserved -join ', ')" }

$worldSize = $TensorParallelSize * $PipelineParallelSize
if ($worldSize -gt 1) {
    if (-not $NcclDllPath -or -not (Test-Path -LiteralPath $NcclDllPath -PathType Leaf)) {
        throw 'Native Windows TP/PP requires -NcclDllPath pointing to a trusted, separately built nccl.dll.'
    }
    $NcclDllPath = (Resolve-Path -LiteralPath $NcclDllPath).Path
}

$oldVisible = $env:CUDA_VISIBLE_DEVICES
$oldNccl = $env:VLLM_NCCL_SO_PATH
$oldSpawn = $env:VLLM_WORKER_MULTIPROC_METHOD
try {
    if ($CudaVisibleDevices) { $env:CUDA_VISIBLE_DEVICES = $CudaVisibleDevices }
    if ($worldSize -gt 1) { $env:VLLM_NCCL_SO_PATH = $NcclDllPath }
    $env:VLLM_WORKER_MULTIPROC_METHOD = 'spawn'

    $probeText = (& $python -c @'
import json, torch, vllm
print(json.dumps({
    "vllm": vllm.__version__,
    "torch": torch.__version__,
    "torch_cuda": torch.version.cuda,
    "count": torch.cuda.device_count(),
    "devices": [torch.cuda.get_device_name(i) for i in range(torch.cuda.device_count())],
}, sort_keys=True))
'@ 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "CUDA runtime probe failed: $probeText" }
    $probe = $probeText | ConvertFrom-Json
    if ($probe.vllm -notmatch '^0\.26\.0' -or $probe.torch_cuda -notmatch '^13\.') {
        throw "Unexpected runtime versions: $probeText"
    }
    if ($worldSize -gt [int]$probe.count) {
        throw "Parallel world size $worldSize exceeds visible CUDA device count $($probe.count)."
    }

    $arguments = @(
        '-m', 'vllm.entrypoints.cli.main', 'serve', $Model,
        '--host', $HostAddress,
        '--port', [string]$Port,
        '--max-model-len', [string]$MaxModelLength,
        '--gpu-memory-utilization', $GpuMemoryUtilization.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture),
        '--max-num-seqs', [string]$MaxNumSeqs,
        '--tensor-parallel-size', [string]$TensorParallelSize,
        '--pipeline-parallel-size', [string]$PipelineParallelSize
    )
    if ($CpuOffloadGiB -gt 0) { $arguments += @('--cpu-offload-gb', [string]$CpuOffloadGiB) }
    if ($KvCacheDtype -ne 'auto') { $arguments += @('--kv-cache-dtype', $KvCacheDtype) }
    if ($CudagraphMode -ne 'AUTO') { $arguments += "-cc.cudagraph_mode=$CudagraphMode" }
    $arguments += $ExtraArgument

    [ordered]@{
        Endpoint = "http://$HostAddress`:$Port/v1"
        Model = $Model
        Runtime = $probe
        TensorParallelSize = $TensorParallelSize
        PipelineParallelSize = $PipelineParallelSize
        CpuOffloadGiB = $CpuOffloadGiB
        CudagraphMode = $CudagraphMode
        Command = @($python) + $arguments
        DryRun = [bool]$DryRun
    } | ConvertTo-Json -Depth 7
    if ($DryRun) { return }

    & $python @arguments
    $exitCode = $LASTEXITCODE
} finally {
    $env:CUDA_VISIBLE_DEVICES = $oldVisible
    $env:VLLM_NCCL_SO_PATH = $oldNccl
    $env:VLLM_WORKER_MULTIPROC_METHOD = $oldSpawn
}
if ($exitCode -ne 0) { throw "Native Windows CUDA vLLM exited with code $exitCode." }
