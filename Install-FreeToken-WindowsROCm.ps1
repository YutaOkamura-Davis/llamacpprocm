[CmdletBinding()]
param(
    [string]$InstallDirectory = 'C:\llm-runtimes\freetoken-windows-rocm',
    [string]$RocmPath = $env:HIP_PATH,
    [string]$WheelDirectory = '',
    [ValidatePattern('^gfx[0-9a-z]+$')]
    [string]$Architecture = 'gfx1151',
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$Commit = '45675e47348a167a9b36ca224ad310c1ee1e34b4',
    [switch]$AllowArchitectureMismatch,
    [switch]$AcceptExperimentalRisk,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$repository = 'https://github.com/Maxritz/FreeToken-rocm-test.git'

$plan = [ordered]@{
    Action = 'Install the community FreeToken native-Windows ROCm port'
    Repository = $repository
    Commit = $Commit
    InstallDirectory = $InstallDirectory
    Architecture = $Architecture
    RocmPath = $RocmPath
    WheelDirectory = if ($WheelDirectory) { $WheelDirectory } else { 'fork-managed nightly wheel cache' }
    Apply = [bool]$Apply
    Qualification = 'Experimental gfx1151 adaptation. The fork was measured on gfx1201; packed GGUF and Windows MoE offload are not production-ready.'
}
if (-not $Apply) { $plan | ConvertTo-Json -Depth 5; return }
if (-not $AcceptExperimentalRisk) {
    throw 'Re-run with -AcceptExperimentalRisk after reading RUNTIME-LAB.md. This port patches installed packages and uses ROCm nightly components.'
}
if ($Architecture -ne 'gfx1151' -and -not $AllowArchitectureMismatch) {
    throw 'This v4 adapter is qualified only as an experimental gfx1151 path. Use -AllowArchitectureMismatch to test another target.'
}
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { throw 'git.exe is required.' }
if (-not (Get-Command py.exe -ErrorAction SilentlyContinue)) { throw 'Python launcher py.exe is required.' }
$pythonProbe = (& py.exe -3.12 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $pythonProbe -ne '3.12') { throw "Python 3.12 is required; probe returned '$pythonProbe'." }
if (-not $RocmPath -or -not (Test-Path -LiteralPath $RocmPath -PathType Container)) {
    throw 'Pass -RocmPath pointing to the extracted Windows ROCm/TheRock runtime, or set HIP_PATH.'
}
$hipcc = Join-Path $RocmPath 'bin\hipcc.exe'
if (-not (Test-Path -LiteralPath $hipcc -PathType Leaf)) { throw "hipcc.exe not found: $hipcc" }

$rocminfo = Join-Path $RocmPath 'bin\rocminfo.exe'
if (Test-Path -LiteralPath $rocminfo -PathType Leaf) {
    $rocmText = (& $rocminfo 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'rocminfo failed; fix the HIP runtime before installing FreeToken.' }
    if ($rocmText -notmatch [regex]::Escape($Architecture) -and -not $AllowArchitectureMismatch) {
        throw "rocminfo did not report $Architecture. Use the correct device package/runtime."
    }
} elseif (-not $AllowArchitectureMismatch) {
    throw "rocminfo.exe is missing. Use -AllowArchitectureMismatch only if another trusted probe confirmed $Architecture."
}

if (Test-Path -LiteralPath $InstallDirectory) {
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDirectory '.git') -PathType Container)) {
        throw "Install directory exists but is not a git repository: $InstallDirectory"
    }
    $dirty = (& git.exe -C $InstallDirectory status --porcelain 2>&1 | Out-String).Trim()
    if ($dirty) { throw 'Existing FreeToken source tree has local changes; refusing to change commits.' }
    $origin = (& git.exe -C $InstallDirectory remote get-url origin 2>&1 | Out-String).Trim()
    if ($origin -notmatch 'Maxritz/FreeToken-rocm-test') { throw "Unexpected git origin: $origin" }
} else {
    $parent = Split-Path -Parent $InstallDirectory
    if (-not $parent) { throw 'InstallDirectory must include a parent directory.' }
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    & git.exe clone --filter=blob:none $repository $InstallDirectory
    if ($LASTEXITCODE -ne 0) { throw 'FreeToken fork clone failed.' }
}

& git.exe -C $InstallDirectory fetch --depth 1 origin $Commit
if ($LASTEXITCODE -ne 0) { throw 'Could not fetch the pinned FreeToken fork commit.' }
& git.exe -C $InstallDirectory checkout --detach $Commit
if ($LASTEXITCODE -ne 0) { throw 'Could not check out the pinned FreeToken fork commit.' }
$actual = (& git.exe -C $InstallDirectory rev-parse HEAD | Out-String).Trim()
if ($actual -ne $Commit) { throw "Source pin mismatch: $actual" }

$env:HIP_PATH = $RocmPath
$env:TVM_FFI_ROCM_ARCH_LIST = $Architecture
$env:TRITON_OVERRIDE_ARCH = $Architecture
$env:ROCM_SDK_TARGET_FAMILY = $Architecture
$env:CC = Join-Path $RocmPath 'lib\llvm\bin\clang.EXE'

# The pinned fork's dist/install.ps1 contains three syntactically invalid
# "$PIP install" statements. Perform the same stages with argument-safe native
# invocations and install the full non-CUDA runtime dependency set.
$venv = Join-Path $InstallDirectory '.venv'
$python = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    & py.exe -3.12 -m venv $venv
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the private Python 3.12 environment.' }
}
& $python -m pip install --upgrade pip 'setuptools>=77' wheel
if ($LASTEXITCODE -ne 0) { throw 'Could not update pip/setuptools/wheel.' }

if (-not $WheelDirectory) {
    $WheelDirectory = Join-Path $InstallDirectory "rocm-wheels\py312-$Architecture"
}
if (-not (Test-Path -LiteralPath $WheelDirectory)) {
    New-Item -ItemType Directory -Path $WheelDirectory -Force | Out-Null
}
$wheelFiles = @(Get-ChildItem -LiteralPath $WheelDirectory -Filter *.whl -File -ErrorAction SilentlyContinue)
if (-not $wheelFiles) {
    $index = 'https://rocm.nightlies.amd.com/whl-multi-arch/'
    $rocmRequirement = "rocm[libraries,devel,device-$Architecture]"
    & $python -m pip download --index-url $index -d $WheelDirectory $rocmRequirement
    if ($LASTEXITCODE -ne 0) { throw 'ROCm/TheRock wheel download failed.' }
    $wheelFiles = @(Get-ChildItem -LiteralPath $WheelDirectory -Filter *.whl -File)
}
if (-not ($wheelFiles.Name -match [regex]::Escape($Architecture))) {
    throw "Wheel directory does not contain a device package for $Architecture."
}
$wheelIdentities = @($wheelFiles | ForEach-Object {
    if ($_.Name -match '^(?<Package>.+?)-(?<Version>[0-9][^-]*)-') {
        [pscustomobject]@{ Package = $matches.Package.ToLowerInvariant(); Version = $matches.Version; File = $_.Name }
    }
})
$duplicates = @($wheelIdentities | Group-Object Package | Where-Object {
    @($_.Group.Version | Sort-Object -Unique).Count -gt 1
})
if ($duplicates) {
    throw "Wheel directory contains multiple versions of: $($duplicates.Name -join ', '). Use a clean per-architecture directory."
}
$wheelPaths = @($wheelFiles.FullName)
& $python -m pip install --no-deps --force-reinstall @wheelPaths
if ($LASTEXITCODE -ne 0) { throw 'ROCm/TheRock wheel installation failed.' }

$runtimeDependencies = @(
    'apache-tvm-ffi==0.1.13.post3',
    'einops>=0.8,<1',
    'fastapi>=0.115,<1',
    'flashlib==0.3.0',
    'gguf>=0.19,<1',
    'huggingface_hub>=1.5,<2',
    'msgpack>=1.1,<2',
    'modelscope>=1.37,<2',
    'numpy>=2.0,<2.5',
    'openai>=2.0,<3',
    'partial-json-parser>=0.2,<1',
    'prompt_toolkit>=3.0,<4',
    'pydantic>=2.9,<3',
    'pyzmq>=27,<28',
    'safetensors>=0.6,<1',
    'tqdm>=4.66,<5',
    'transformers>=5.5,<6',
    'triton-windows>=3.7.1',
    'uvicorn>=0.30,<1',
    'psutil', 'requests', 'aiohttp'
)
& $python -m pip install @runtimeDependencies
if ($LASTEXITCODE -ne 0) { throw 'FreeToken runtime dependency installation failed.' }

$env:FREETOKEN_SKIP_CUDA_EXT = '1'
try {
    & $python -m pip install -e $InstallDirectory --no-deps --no-build-isolation
    if ($LASTEXITCODE -ne 0) { throw 'FreeToken editable installation failed.' }
} finally {
    Remove-Item Env:FREETOKEN_SKIP_CUDA_EXT -ErrorAction SilentlyContinue
}
$patcher = Join-Path $InstallDirectory 'dist\patch_upstream.py'
if (-not (Test-Path -LiteralPath $patcher -PathType Leaf)) { throw "Upstream compatibility patcher missing: $patcher" }
& $python $patcher
if ($LASTEXITCODE -ne 0) { throw 'FreeToken upstream package patching failed.' }

& $python -c "import json, torch, freetoken; assert torch.cuda.is_available(); print(json.dumps({'torch':torch.__version__,'hip':torch.version.hip,'gpu':torch.cuda.get_device_name(0)}, indent=2))"
if ($LASTEXITCODE -ne 0) { throw 'FreeToken native Windows smoke import failed.' }

$lockPath = Join-Path $InstallDirectory 'v4-install-lock.txt'
@(
    "commit=$Commit"
    "architecture=$Architecture"
    "rocm_path=$RocmPath"
    'wheel_sha256:'
    ($wheelFiles | Sort-Object Name | ForEach-Object {
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
        "$hash  $($_.Name)"
    })
    'pip_freeze:'
    (& $python -m pip freeze)
) | Set-Content -LiteralPath $lockPath -Encoding UTF8
Write-Host "Experimental FreeToken ROCm adapter installed at $InstallDirectory" -ForegroundColor Green
