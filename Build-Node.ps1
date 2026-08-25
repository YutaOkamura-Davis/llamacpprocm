[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('CUDA', 'Vulkan', 'HIP', 'CPU')]
    [string]$Backend,

    [ValidateSet('Controller', 'Worker')]
    [string]$Role = 'Worker',

    [string]$SourceDirectory = 'C:\llama-dflash2',

    [ValidatePattern('^(auto|[0-9]+(;[0-9]+)*)$')]
    [string]$CudaArchitectures = 'auto',

    [ValidatePattern('^(auto|gfx[0-9a-f]+(;gfx[0-9a-f]+)*)$')]
    [string]$HipArchitectures = 'auto',

    [string]$HipSdkDirectory,

    [ValidateRange(1, 256)]
    [int]$Parallel = 8,

    [switch]$EnableAllCudaKvQuants
)

$ErrorActionPreference = 'Stop'
$repo = 'https://github.com/z-lab/llama.cpp-fork.git'
$commit = '7ea40ee98acb416787863aee935dbb99491acad5'

function Invoke-Checked {
    param(
        [Parameter(Mandatory)]
        [string]$Command,
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$ArgumentList
    )

    & $Command @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE."
    }
}

foreach ($tool in 'git', 'cmake', 'ninja') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Missing required tool: $tool"
    }
}

$sourceParent = Split-Path -Parent $SourceDirectory
if ($sourceParent -and -not (Test-Path -LiteralPath $sourceParent)) {
    New-Item -ItemType Directory -Force -Path $sourceParent | Out-Null
}

if (-not (Test-Path -LiteralPath $SourceDirectory)) {
    Invoke-Checked git @('clone', '--filter=blob:none', $repo, $SourceDirectory)
} elseif (-not (Test-Path -LiteralPath (Join-Path $SourceDirectory '.git'))) {
    throw "SourceDirectory exists but is not a Git repository: $SourceDirectory"
} else {
    # Generated build-* directories are intentionally inside SourceDirectory.
    # Reject tracked edits while allowing those untracked build artifacts.
    $dirty = & git -C $SourceDirectory status --porcelain --untracked-files=no
    if ($LASTEXITCODE -ne 0) { throw 'git status failed.' }
    if ($dirty) { throw 'The source repository has local changes; use a clean directory.' }
}

Invoke-Checked git @('-C', $SourceDirectory, 'fetch', 'origin', $commit, '--depth', '1')
Invoke-Checked git @('-C', $SourceDirectory, 'checkout', '--detach', $commit)
$actualCommit = (& git -C $SourceDirectory rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $commit) {
    throw "Source pin verification failed. Expected $commit, got $actualCommit."
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio vswhere.exe was not found.' }
$vsInstall = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $vsInstall) { throw 'Visual Studio C++ Build Tools were not found.' }

$vsDevCmd = Join-Path $vsInstall 'Common7\Tools\VsDevCmd.bat'
$environmentLines = & cmd.exe /d /s /c "`"$vsDevCmd`" -arch=x64 -host_arch=x64 && set"
if ($LASTEXITCODE -ne 0) { throw 'Visual Studio environment setup failed.' }
foreach ($line in $environmentLines) {
    if ($line -match '^([^=]+)=(.*)$') {
        Set-Item -Path "Env:$($matches[1])" -Value $matches[2]
    }
}
$env:VSLANG = '1033'

if ($Backend -eq 'CUDA') {
    if (-not (Get-Command nvcc -ErrorAction SilentlyContinue)) {
        throw 'CUDA nvcc was not found. Install a CUDA toolkit and reopen PowerShell.'
    }
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
        throw 'nvidia-smi was not found; automatic architecture detection is unavailable.'
    }
    if ($CudaArchitectures -eq 'auto') {
        $capabilities = @(& nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $capabilities) {
            throw 'Could not query NVIDIA compute capability.'
        }
        $detected = @($capabilities | ForEach-Object {
            $value = $_.Trim() -replace '\.', ''
            if ($value -notmatch '^[0-9]+$') { throw "Unexpected compute capability: $_" }
            $value
        } | Sort-Object -Unique)
        $CudaArchitectures = $detected -join ';'
    }
}

if ($Backend -eq 'Vulkan' -and -not (Get-Command glslc -ErrorAction SilentlyContinue)) {
    throw 'Vulkan glslc was not found. Install the LunarG Vulkan SDK and reopen PowerShell.'
}

if ($Backend -eq 'HIP') {
    if (-not $HipSdkDirectory) {
        if ($env:HIP_PATH) {
            $HipSdkDirectory = $env:HIP_PATH
        } elseif ($env:ROCM_PATH) {
            $HipSdkDirectory = $env:ROCM_PATH
        } else {
            $rocmRoot = Join-Path $env:ProgramFiles 'AMD\ROCm'
            if (Test-Path -LiteralPath $rocmRoot -PathType Container) {
                $HipSdkDirectory = Get-ChildItem -LiteralPath $rocmRoot -Directory |
                    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\clang.exe') } |
                    Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending |
                    Select-Object -First 1 -ExpandProperty FullName
            }
        }
    }
    if (-not $HipSdkDirectory -or -not (Test-Path -LiteralPath $HipSdkDirectory -PathType Container)) {
        throw 'AMD HIP SDK was not found. Install HIP SDK for Windows or pass -HipSdkDirectory.'
    }
    $HipSdkDirectory = (Resolve-Path -LiteralPath $HipSdkDirectory).Path
    $hipBin = Join-Path $HipSdkDirectory 'bin'
    $clang = Join-Path $hipBin 'clang.exe'
    $clangxx = Join-Path $hipBin 'clang++.exe'
    if (-not (Test-Path -LiteralPath $clang -PathType Leaf) -or
        -not (Test-Path -LiteralPath $clangxx -PathType Leaf)) {
        throw "HIP SDK clang/clang++ were not found under $hipBin."
    }
    $env:HIP_PATH = $HipSdkDirectory
    $env:ROCM_PATH = $HipSdkDirectory
    if (($env:PATH -split ';') -notcontains $hipBin) {
        $env:PATH = "$hipBin;$env:PATH"
    }

    if ($HipArchitectures -eq 'auto') {
        $probeCandidates = @(
            (Join-Path $hipBin 'hipInfo.exe'),
            (Join-Path $hipBin 'rocminfo.exe')
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
        $probeOutput = @()
        foreach ($probe in $probeCandidates) {
            $probeOutput += @(& $probe 2>$null)
            if ($LASTEXITCODE -eq 0 -and $probeOutput) { break }
        }
        $detected = @($probeOutput | ForEach-Object {
            [regex]::Matches([string]$_, '\bgfx[1-9][0-9a-f]{3,}\b') | ForEach-Object Value
        } | Sort-Object -Unique)
        if (-not $detected) {
            throw 'Could not detect an AMD GPU architecture. For the Ryzen AI Max+ 395, pass -HipArchitectures gfx1151.'
        }
        $HipArchitectures = $detected -join ';'
    }
}

$backendName = $Backend.ToLowerInvariant()
$buildDirectory = Join-Path $SourceDirectory "build-$backendName"
$cmakeArgs = @(
    '-S', $SourceDirectory,
    '-B', $buildDirectory,
    '-G', 'Ninja',
    '-DCMAKE_BUILD_TYPE=Release',
    '-DGGML_RPC=ON',
    '-DLLAMA_CURL=OFF',
    '-DLLAMA_BUILD_TESTS=OFF',
    '-DLLAMA_BUILD_TOOLS=ON',
    ("-DLLAMA_BUILD_SERVER={0}" -f $(if ($Role -eq 'Controller') { 'ON' } else { 'OFF' })),
    '-DLLAMA_BUILD_UI=OFF',
    '-DLLAMA_USE_PREBUILT_UI=OFF',
    '-DLLAMA_BUILD_EXAMPLES=ON'
)

switch ($Backend) {
    'CUDA' {
        $cmakeArgs += '-DGGML_CUDA=ON'
        $cmakeArgs += "-DCMAKE_CUDA_ARCHITECTURES=$CudaArchitectures"
        if ($EnableAllCudaKvQuants) {
            $cmakeArgs += '-DGGML_CUDA_FA_ALL_QUANTS=ON'
        }
    }
    'Vulkan' {
        $cmakeArgs += '-DGGML_VULKAN=ON'
    }
    'HIP' {
        $cmakeArgs += '-DGGML_HIP=ON'
        $cmakeArgs += "-DGPU_TARGETS=$HipArchitectures"
        $cmakeArgs += "-DCMAKE_C_COMPILER=$clang"
        $cmakeArgs += "-DCMAKE_CXX_COMPILER=$clangxx"
        if ($EnableAllCudaKvQuants) {
            # ggml-hip shares these flash-attention template options with ggml-cuda.
            $cmakeArgs += '-DGGML_CUDA_FA_ALL_QUANTS=ON'
        }
    }
}

Invoke-Checked cmake $cmakeArgs

$targets = @('ggml-rpc-server', 'llama-bench')
if ($Role -eq 'Controller') { $targets += 'llama-server' }
$buildArgs = @('--build', $buildDirectory, '--target') + $targets + @('--parallel', $Parallel)
Invoke-Checked cmake $buildArgs

$binDirectory = Join-Path $buildDirectory 'bin'
$manifest = [ordered]@{
    SourceRepository = $repo
    Commit = $actualCommit
    BuiltAt = (Get-Date).ToString('o')
    ComputerName = $env:COMPUTERNAME
    Backend = $Backend
    Role = $Role
    CudaArchitectures = if ($Backend -eq 'CUDA') { $CudaArchitectures } else { $null }
    HipArchitectures = if ($Backend -eq 'HIP') { $HipArchitectures } else { $null }
    HipSdkDirectory = if ($Backend -eq 'HIP') { $HipSdkDirectory } else { $null }
    AllCudaKvQuants = [bool]$EnableAllCudaKvQuants
    AllGpuKvQuants = [bool]$EnableAllCudaKvQuants
    BuildDirectory = $buildDirectory
    Targets = $targets
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $binDirectory 'BUILD-LOCAL.json') -Encoding UTF8

Write-Host "Build complete: $binDirectory"
if ($Backend -eq 'CUDA') {
    Write-Host "CUDA architecture(s): $CudaArchitectures"
}
if ($Backend -eq 'HIP') {
    Write-Host "HIP architecture(s): $HipArchitectures"
}
