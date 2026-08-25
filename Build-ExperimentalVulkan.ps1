[CmdletBinding()]
param(
    [string]$HybridPath = (Join-Path $PSScriptRoot 'experiment-source\hybrid'),
    [string]$BuildDirectory,
    [ValidateRange(1, 256)]
    [int]$Parallel = 16,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    & $Command @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE"
    }
}

$HybridPath = [IO.Path]::GetFullPath($HybridPath)
if (-not (Test-Path -LiteralPath (Join-Path $HybridPath '.git'))) {
    throw "Hybrid Git tree not found: $HybridPath. Run Prepare-ExperimentalSource.ps1 first."
}

if (-not $BuildDirectory) {
    $BuildDirectory = Join-Path $HybridPath 'build-win-vulkan'
}
$BuildDirectory = [IO.Path]::GetFullPath($BuildDirectory)

foreach ($tool in 'git', 'cmake', 'ninja') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Missing required tool: $tool"
    }
}

if (-not (Get-Command glslc -ErrorAction SilentlyContinue)) {
    if ($env:VULKAN_SDK) {
        $vulkanBin = Join-Path $env:VULKAN_SDK 'Bin'
        $glslc = Join-Path $vulkanBin 'glslc.exe'
        if (Test-Path -LiteralPath $glslc -PathType Leaf) {
            $env:PATH = "$vulkanBin;$env:PATH"
        }
    }
}
if (-not (Get-Command glslc -ErrorAction SilentlyContinue)) {
    throw 'Vulkan glslc was not found. Install the LunarG Vulkan SDK and reopen PowerShell.'
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw 'Visual Studio vswhere.exe was not found. Install Visual Studio 2022 Build Tools with Desktop C++.'
}
$vsInstall = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $vsInstall) {
    throw 'Visual Studio C++ Build Tools were not found.'
}
$vsDevCmd = Join-Path $vsInstall 'Common7\Tools\VsDevCmd.bat'
$environmentLines = & cmd.exe /d /s /c "`"$vsDevCmd`" -arch=x64 -host_arch=x64 && set"
if ($LASTEXITCODE -ne 0) {
    throw 'Visual Studio environment setup failed.'
}
foreach ($line in $environmentLines) {
    if ($line -match '^([^=]+)=(.*)$') {
        Set-Item -Path "Env:$($matches[1])" -Value $matches[2]
    }
}
$env:VSLANG = '1033'

$trackedChanges = @(& git -C $HybridPath status --porcelain --untracked-files=no)
if ($LASTEXITCODE -ne 0) {
    throw 'git status failed in hybrid tree.'
}
if ($trackedChanges) {
    throw "Hybrid tree has tracked changes. Commit or reset them before building:`n$($trackedChanges -join "`n")"
}

if ($Clean -and (Test-Path -LiteralPath $BuildDirectory)) {
    Remove-Item -LiteralPath $BuildDirectory -Recurse -Force
}

$cmakeArgs = @(
    '-S', $HybridPath,
    '-B', $BuildDirectory,
    '-G', 'Ninja',
    '-DCMAKE_BUILD_TYPE=Release',
    '-DGGML_VULKAN=ON',
    '-DGGML_RPC=ON',
    '-DLLAMA_CURL=OFF',
    '-DLLAMA_BUILD_SERVER=ON',
    '-DLLAMA_BUILD_TESTS=ON',
    '-DLLAMA_BUILD_TOOLS=ON',
    '-DLLAMA_BUILD_EXAMPLES=ON',
    '-DLLAMA_BUILD_UI=OFF',
    '-DLLAMA_USE_PREBUILT_UI=OFF'
)
Invoke-Checked -Command 'cmake' -ArgumentList $cmakeArgs

$targets = @('llama-cli', 'llama-server', 'llama-bench', 'ggml-rpc-server', 'test-backend-ops')
$buildArgs = @('--build', $BuildDirectory, '--target') + $targets + @('--parallel', [string]$Parallel)
Invoke-Checked -Command 'cmake' -ArgumentList $buildArgs

$head = (& git -C $HybridPath rev-parse HEAD).Trim()
$binDirectory = Join-Path $BuildDirectory 'bin'
$manifest = [ordered]@{
    BuiltAt = (Get-Date).ToString('o')
    HybridPath = $HybridPath
    Commit = $head
    BuildDirectory = $BuildDirectory
    Backend = 'Vulkan'
    Targets = $targets
    Glslc = (Get-Command glslc).Source
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $BuildDirectory 'BUILD-WIN-VULKAN.json') -Encoding UTF8

Write-Host "Windows Vulkan build complete: $binDirectory"
Write-Host "Commit: $head"
Write-Host 'Next correctness gate: run llama-cli/llama-bench on Vulkan0 before applying donor changes.'
