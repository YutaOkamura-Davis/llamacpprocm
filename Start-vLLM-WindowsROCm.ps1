[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Model,
    [string]$InstallRoot = 'C:\AI\vllm-gfx1151',
    [ValidateSet('127.0.0.1', 'localhost', '::1')][string]$HostAddress = '127.0.0.1',
    [ValidateRange(1, 65535)][int]$Port = 8000,
    [ValidateRange(128, 1048576)][int]$MaxModelLength = 4096,
    [ValidateRange(0.10, 0.95)][double]$GpuMemoryUtilization = 0.70,
    [ValidateSet('auto', 'bf16', 'fp8')][string]$KvCacheDtype = 'auto',
    [ValidateSet('NONE', 'FULL', 'PIECEWISE')][string]$CudagraphMode = 'NONE',
    [ValidateRange(1.0, 256.0)][double]$GuardLimitGiB = 50.0,
    [ValidateRange(0.0, 256.0)][double]$GuardWarnGiB = 46.0,
    [ValidateRange(60, 7200)][int]$StallSeconds = 900,
    [string[]]$ExtraArgs = @(),
    [switch]$DisableHipBlasLt,
    [switch]$EnableStallWatchdog,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Commit = '89f703a1fb1dd583ff976b977d60cf5082532943'
$Repository = 'https://github.com/charlie12345/vLLM_for_AMD.git'
$PatchFile = Join-Path $PSScriptRoot 'patches\vllm-windows-rocm-gfx1151.patch'
$ExpectedChangedFiles = @(
    'env_windows_rocm.cmd',
    'serve_windows_rocm.cmd',
    'setup_windows_rocm.ps1'
)
$UnsafeCmdChars = '["%&|<>^!()\r\n]'

function Assert-CmdSafe([string]$Name, [string]$Value) {
    if ($Value -match $UnsafeCmdChars) {
        throw "$Name contains a character that cannot be passed safely through the fork's cmd.exe watchdog."
    }
}

function Quote-Cmd([string]$Value) {
    Assert-CmdSafe -Name 'argument' -Value $Value
    return '"' + $Value + '"'
}

if ($GuardWarnGiB -ge $GuardLimitGiB) { throw 'GuardWarnGiB must be below GuardLimitGiB.' }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git for Windows is required.' }
if (-not (Test-Path -LiteralPath (Join-Path $InstallRoot '.git'))) {
    throw "Pinned vLLM clone not found at $InstallRoot. Run Install-vLLM-WindowsROCm.ps1 first."
}
if (-not (Test-Path -LiteralPath $PatchFile -PathType Leaf)) { throw "Missing adapter patch: $PatchFile" }
Assert-CmdSafe -Name 'InstallRoot' -Value $InstallRoot
Assert-CmdSafe -Name 'Model' -Value $Model
foreach ($item in $ExtraArgs) { Assert-CmdSafe -Name 'ExtraArgs item' -Value $item }

$reserved = @($ExtraArgs | Where-Object {
    $_ -match '^--(host|port|max-model-len|gpu-memory-utilization|kv-cache-dtype)(=|$)'
})
if ($reserved) {
    throw "ExtraArgs cannot override wrapper-owned safety settings: $($reserved -join ', ')"
}

$actualCommit = (& git -C $InstallRoot rev-parse HEAD | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $Commit) {
    throw "Expected pinned vLLM commit $Commit; found '$actualCommit'."
}
$actualOrigin = (& git -C $InstallRoot remote get-url origin | Out-String).Trim()
$normalizedOrigin = ($actualOrigin.TrimEnd('/') -replace '\.git$', '').ToLowerInvariant()
$normalizedExpected = ($Repository.TrimEnd('/') -replace '\.git$', '').ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $normalizedOrigin -ne $normalizedExpected) {
    throw "Expected source origin $Repository; found '$actualOrigin'."
}
& git -C $InstallRoot apply --reverse --check --whitespace=nowarn $PatchFile 2>$null
if ($LASTEXITCODE -ne 0) { throw 'The audited gfx1151 patch is not applied cleanly to the pinned source.' }
$changed = @((& git -C $InstallRoot diff --name-only | Out-String).Trim() -split "`r?`n" |
    Where-Object { $_ } | Sort-Object -Unique)
if ($LASTEXITCODE -ne 0 -or
    @($changed | Where-Object { $_ -notin $ExpectedChangedFiles }).Count -gt 0 -or
    @($ExpectedChangedFiles | Where-Object { $_ -notin $changed }).Count -gt 0) {
    throw 'The source tree contains changes beyond the exact audited gfx1151 adapter patch.'
}

$server = Join-Path $InstallRoot 'serve_windows_rocm.cmd'
$guard = Join-Path $InstallRoot 'vram_guard.ps1'
$python = Join-Path $InstallRoot '.venv211\Scripts\python.exe'
foreach ($required in @($server, $guard, $python)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required runtime file is missing: $required" }
}

if ($Model -match '^[A-Za-z]:[\\/]' -or $Model -match '^[\\/]{2}' -or $Model.StartsWith('.')) {
    if (-not (Test-Path -LiteralPath $Model)) { throw "Local model path does not exist: $Model" }
    $Model = (Resolve-Path -LiteralPath $Model).Path
    Assert-CmdSafe -Name 'resolved Model' -Value $Model
}

$logs = Join-Path $InstallRoot 'logs'
if (-not $DryRun) { New-Item -ItemType Directory -Path $logs -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runLog = Join-Path $logs "vllm-gfx1151-$stamp.log"
$guardLog = Join-Path $logs "vllm-gfx1151-$stamp.guard.log"

$arguments = @(
    $Model,
    '--host', $HostAddress,
    '--port', [string]$Port,
    '--max-model-len', [string]$MaxModelLength,
    '--gpu-memory-utilization', $GpuMemoryUtilization.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
)
if ($KvCacheDtype -ne 'auto') { $arguments += @('--kv-cache-dtype', $KvCacheDtype) }
$arguments += $ExtraArgs

$quotedArguments = @($arguments | ForEach-Object { Quote-Cmd ([string]$_) })
$command = 'call {0} {1} > {2} 2>&1' -f (
    (Quote-Cmd $server),
    ($quotedArguments -join ' '),
    (Quote-Cmd $runLog)
)

Write-Host 'Native Windows vLLM gfx1151 launch' -ForegroundColor Cyan
Write-Host "  Endpoint:       http://$HostAddress`:$Port/v1"
Write-Host "  Model:          $Model"
Write-Host "  Max model len:  $MaxModelLength"
Write-Host "  GPU utilization: $GpuMemoryUtilization"
Write-Host "  KV cache dtype: $KvCacheDtype"
Write-Host "  CUDAGraph mode: $CudagraphMode"
Write-Host "  hipBLASLt:      $(-not $DisableHipBlasLt)"
Write-Host "  Watchdog:       warn $GuardWarnGiB GiB / stop $GuardLimitGiB GiB"
Write-Host "  Stall monitor:  $(if ($EnableStallWatchdog) { "enabled at ${StallSeconds}s" } else { 'disabled for an idle API server' })"
Write-Host "  Engine log:     $runLog"

if ($DryRun) {
    Write-Host ''
    Write-Host 'Dry run; guarded command:'
    Write-Host $command
    return
}

$oldGraph = $env:WINDOWS_ROCM_CUDAGRAPH_MODE
$oldBlas = $env:TORCH_BLAS_PREFER_HIPBLASLT
try {
    $env:WINDOWS_ROCM_CUDAGRAPH_MODE = $CudagraphMode
    $env:TORCH_BLAS_PREFER_HIPBLASLT = if ($DisableHipBlasLt) { '0' } else { '1' }
    $guardArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $guard,
        '-Command', $command,
        '-LimitGiB', [string]$GuardLimitGiB,
        '-WarnGiB', [string]$GuardWarnGiB,
        '-LogPath', $guardLog
    )
    if ($EnableStallWatchdog) {
        $guardArguments += @('-StallLogPath', $runLog, '-StallSec', [string]$StallSeconds)
    }
    & powershell.exe @guardArguments
    $exitCode = $LASTEXITCODE
}
finally {
    $env:WINDOWS_ROCM_CUDAGRAPH_MODE = $oldGraph
    $env:TORCH_BLAS_PREFER_HIPBLASLT = $oldBlas
}
if ($exitCode -ne 0) { throw "vLLM exited with code $exitCode. See $runLog and $guardLog" }
