[CmdletBinding()]
param(
    [string]$InstallDirectory = 'C:\llm-runtimes\vllm-windows-cuda',
    [switch]$Apply,
    [switch]$AcceptExperimentalRisk
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Release = 'v0.26.0'
$WheelName = 'vllm-0.26.0+cu132-cp312-cp312-win_amd64.whl'
$WheelUrl = 'https://github.com/SystemPanic/vllm-windows/releases/download/v0.26.0/vllm-0.26.0%2Bcu132-cp312-cp312-win_amd64.whl'
$WheelSha256 = '3e15c3b8f847b47a87582c9a4451a88b6ab4ecad2d7e44298e3f4d43c7bf0f98'
$TorchIndex = 'https://download.pytorch.org/whl/cu130'

if ($env:OS -ne 'Windows_NT') { throw 'This installer is for native 64-bit Windows only.' }
if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
    throw 'Run from 64-bit PowerShell on 64-bit Windows.'
}

$py = Get-Command py.exe -ErrorAction SilentlyContinue | Select-Object -First 1
$nvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue | Select-Object -First 1
$pythonVersion = $null
if ($py) {
    $pythonVersion = (& $py.Source -3.12 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>$null | Out-String).Trim()
}
$gpuQuery = $null
$cudaReported = $null
if ($nvidiaSmi) {
    $gpuQuery = (& $nvidiaSmi.Source --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits 2>$null | Out-String).Trim()
    $smiText = (& $nvidiaSmi.Source 2>$null | Out-String)
    if ($smiText -match 'CUDA Version:\s*([0-9.]+)') { $cudaReported = $matches[1] }
}

$plan = [ordered]@{
    Action = 'Install the released community native-Windows CUDA vLLM wheel'
    Source = 'https://github.com/SystemPanic/vllm-windows'
    Release = $Release
    Wheel = $WheelName
    WheelSha256 = $WheelSha256
    InstallDirectory = $InstallDirectory
    Python312 = $pythonVersion
    NvidiaSmi = [bool]$nvidiaSmi
    NvidiaGpuQuery = $gpuQuery
    DriverReportedCuda = $cudaReported
    AppliesTo = 'RTX 3060/3060 Ti Ampere and RTX 4080 Laptop Ada; one Windows PC at a time'
    MultiGpuBoundary = 'Local TP/PP additionally requires a separately built trusted NCCL DLL; no cross-PC pooling is automated.'
    Apply = [bool]$Apply
}
if (-not $Apply) { $plan | ConvertTo-Json -Depth 5; return }

if (-not $AcceptExperimentalRisk) {
    throw 'Apply requires -AcceptExperimentalRisk because this is a community Windows wheel, not an official vLLM build.'
}
if (-not $py -or $pythonVersion -ne '3.12') { throw 'Install 64-bit Python 3.12 with the py.exe launcher.' }
if (-not $nvidiaSmi -or -not $gpuQuery) { throw 'nvidia-smi could not enumerate an NVIDIA GPU.' }
if (-not $cudaReported -or [version]$cudaReported -lt [version]'13.0') {
    throw "The release requires a CUDA 13-capable NVIDIA driver; nvidia-smi reported '$cudaReported'. This installer does not update drivers."
}

$parent = Split-Path -Parent $InstallDirectory
if (-not $parent) { throw 'InstallDirectory must include an explicit parent directory.' }
if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
if (-not (Test-Path -LiteralPath $InstallDirectory)) {
    New-Item -ItemType Directory -Path $InstallDirectory | Out-Null
} else {
    $unexpected = @(Get-ChildItem -LiteralPath $InstallDirectory -Force | Where-Object {
        $_.Name -notin @('.venv', 'downloads', 'install-record.json', 'pip-freeze.txt')
    })
    if ($unexpected) {
        throw "InstallDirectory contains unrelated files: $($unexpected.Name -join ', ')"
    }
}

$venv = Join-Path $InstallDirectory '.venv'
$python = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    & $py.Source -3.12 -m venv $venv
    if ($LASTEXITCODE -ne 0) { throw 'Python virtual environment creation failed.' }
}
$downloads = Join-Path $InstallDirectory 'downloads'
if (-not (Test-Path -LiteralPath $downloads)) { New-Item -ItemType Directory -Path $downloads | Out-Null }
$wheel = Join-Path $downloads $WheelName
if (Test-Path -LiteralPath $wheel -PathType Leaf) {
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $wheel).Hash.ToLowerInvariant()
    if ($actualHash -ne $WheelSha256) { throw "Existing wheel hash mismatch: $actualHash" }
} else {
    $partial = Join-Path $downloads ('.partial-' + [guid]::NewGuid().ToString('N'))
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $WheelUrl -OutFile $partial
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $partial).Hash.ToLowerInvariant()
        if ($actualHash -ne $WheelSha256) { throw "Downloaded wheel hash mismatch: $actualHash" }
        Move-Item -LiteralPath $partial -Destination $wheel
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
}

& $python -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw 'pip upgrade failed.' }
& $python -m pip install $wheel --extra-index-url $TorchIndex
if ($LASTEXITCODE -ne 0) { throw 'Pinned vLLM Windows wheel installation failed.' }

$probe = (& $python -c @'
import json, torch, vllm
if not torch.cuda.is_available():
    raise SystemExit("Torch cannot see CUDA after installation")
print(json.dumps({
    "vllm": vllm.__version__,
    "torch": torch.__version__,
    "torch_cuda": torch.version.cuda,
    "devices": [
        {"name": torch.cuda.get_device_name(i), "capability": torch.cuda.get_device_capability(i)}
        for i in range(torch.cuda.device_count())
    ],
}, sort_keys=True))
'@ 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw "Installed runtime probe failed: $probe" }
Write-Host $probe

& $python -m pip freeze | Set-Content -LiteralPath (Join-Path $InstallDirectory 'pip-freeze.txt') -Encoding UTF8
$record = [ordered]@{
    InstalledAt = (Get-Date).ToString('o')
    Source = 'https://github.com/SystemPanic/vllm-windows'
    Release = $Release
    Wheel = $WheelName
    WheelSha256 = $WheelSha256
    TorchIndex = $TorchIndex
    Probe = $probe | ConvertFrom-Json
} | ConvertTo-Json -Depth 7
Set-Content -LiteralPath (Join-Path $InstallDirectory 'install-record.json') -Value $record -Encoding UTF8
Write-Host 'Native Windows CUDA vLLM install completed. Start with a single GPU and a small model.' -ForegroundColor Green
