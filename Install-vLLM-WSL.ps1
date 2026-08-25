[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Distro,
    [ValidateSet('CUDA', 'ROCm')]
    [string]$Backend = 'CUDA',
    [string]$EnvironmentPath = '~/.venvs/vllm-v4',
    [string]$VllmVersion,
    [ValidatePattern('^rocm[0-9]+$')]
    [string]$RocmVariant = 'rocm723',
    [ValidatePattern('^gfx[0-9a-z]+$')]
    [string]$RocmArchitecture = 'gfx1151',
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$versions = @{ CUDA = '0.27.1'; ROCm = '0.27.1' }
if (-not $VllmVersion) { $VllmVersion = $versions[$Backend] }
if ($VllmVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+([.][A-Za-z0-9]+)?$') { throw 'Invalid vLLM version.' }

function Resolve-WslPath {
    param([string]$WindowsPath)
    $result = (& wsl.exe -d $Distro -- wslpath -a -u $WindowsPath 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $result) { throw "Could not map path into WSL: $result" }
    return $result
}

$plan = [ordered]@{
    Action = 'Install vLLM in an isolated WSL environment'
    Distro = $Distro
    Backend = $Backend
    EnvironmentPath = $EnvironmentPath
    VllmVersion = $VllmVersion
    RocmVariant = if ($Backend -eq 'ROCm') { $RocmVariant } else { $null }
    RocmArchitecture = if ($Backend -eq 'ROCm') { $RocmArchitecture } else { $null }
    Apply = [bool]$Apply
    Note = if ($Backend -eq 'ROCm') {
        'Pinned to the current official ROCm wheel index (rocm723). gfx1151 still requires a working ROCm WSL GPU stack and a compatible driver.'
    } else {
        'Pinned to the current official vLLM release. WSL must expose nvidia-smi.'
    }
}
if (-not $Apply) { $plan | ConvertTo-Json -Depth 5; return }
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw 'WSL is not installed.' }
$known = @(& wsl.exe --list --quiet 2>$null | ForEach-Object { ([string]$_).Replace(([char]0).ToString(), [string]::Empty).Trim() } | Where-Object { $_ })
if ($Distro -notin $known) { throw "WSL distribution '$Distro' was not found. Installed: $($known -join ', ')" }

$script = Join-Path $PSScriptRoot 'wsl\Install-vLLM.sh'
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw "Installer payload not found: $script" }
$wslScript = Resolve-WslPath -WindowsPath (Resolve-Path -LiteralPath $script).Path
& wsl.exe -d $Distro -- bash $wslScript $Backend $EnvironmentPath $VllmVersion $RocmVariant $RocmArchitecture
if ($LASTEXITCODE -ne 0) { throw "vLLM WSL installation failed with exit code $LASTEXITCODE." }
