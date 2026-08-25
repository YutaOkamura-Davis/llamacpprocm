[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Distro,
    [string]$SourcePath = '~/.local/share/freetoken-v4-src',
    [string]$EnvironmentPath = '~/.venvs/freetoken-v4',
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$Commit = '184a4f114d00b7805274841488f2906233b5a961',
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
function Resolve-WslPath {
    param([string]$WindowsPath)
    $result = (& wsl.exe -d $Distro -- wslpath -a -u $WindowsPath 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $result) { throw "Could not map path into WSL: $result" }
    return $result
}
$plan = [ordered]@{
    Action = 'Install official FreeToken source under WSL2'
    Distro = $Distro
    SourcePath = $SourcePath
    EnvironmentPath = $EnvironmentPath
    Repository = 'https://github.com/FlashML-org/FreeToken.git'
    Commit = $Commit
    Apply = [bool]$Apply
    Requirements = 'NVIDIA GPU visible in WSL, driver r580+, CUDA 13 nvcc, Python 3.12, git, uv'
    Scope = 'Single-machine MoE offload; FreeToken tp-size is local and is not a cross-PC RPC transport.'
}
if (-not $Apply) { $plan | ConvertTo-Json -Depth 5; return }
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw 'WSL is not installed.' }
$known = @(& wsl.exe --list --quiet 2>$null | ForEach-Object { ([string]$_).Replace(([char]0).ToString(), [string]::Empty).Trim() } | Where-Object { $_ })
if ($Distro -notin $known) { throw "WSL distribution '$Distro' was not found. Installed: $($known -join ', ')" }

$script = Join-Path $PSScriptRoot 'wsl\Install-FreeToken.sh'
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw "Installer payload not found: $script" }
$wslScript = Resolve-WslPath -WindowsPath (Resolve-Path -LiteralPath $script).Path
& wsl.exe -d $Distro -- bash $wslScript $SourcePath $EnvironmentPath $Commit
if ($LASTEXITCODE -ne 0) { throw "FreeToken WSL installation failed with exit code $LASTEXITCODE." }
