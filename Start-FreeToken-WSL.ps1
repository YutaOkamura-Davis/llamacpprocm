[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Distro,
    [Parameter(Mandatory)][string]$Model,
    [string]$EnvironmentPath = '~/.venvs/freetoken-v4',
    [ValidateRange(1, 65535)][int]$Port = 1919,
    [ValidateSet('auto', 'fused', 'offload', 'cpu', 'hybrid')]
    [string]$MoeBackend = 'auto',
    [ValidateRange(0.1, 0.99)][double]$MemoryRatio = 0.90,
    [ValidateRange(256, 1048576)][int]$MaxSequenceLength = 32768,
    [switch]$CalibrateBandwidth,
    [string[]]$ExtraArgument = @(),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
function Resolve-WslPath {
    param([string]$WindowsPath)
    $result = (& wsl.exe -d $Distro -- wslpath -a -u $WindowsPath 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $result) { throw "Could not map path into WSL: $result" }
    return $result
}
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw 'WSL is not installed.' }
$script = Join-Path $PSScriptRoot 'wsl\Start-FreeToken.sh'
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw "Launcher payload not found: $script" }
$arguments = @(
    $EnvironmentPath, $Model, [string]$Port, $MoeBackend,
    $MemoryRatio.ToString([Globalization.CultureInfo]::InvariantCulture),
    [string]$MaxSequenceLength,
    $(if ($CalibrateBandwidth) { '1' } else { '0' })
) + $ExtraArgument
if ($DryRun) {
    [ordered]@{
        Distro = $Distro
        Script = $script
        Arguments = $arguments
        Bind = '127.0.0.1 only'
        Recommendation = 'Run -CalibrateBandwidth once, then compare auto, offload, and hybrid on an MoE model.'
    } | ConvertTo-Json -Depth 5
    return
}
$wslScript = Resolve-WslPath -WindowsPath (Resolve-Path -LiteralPath $script).Path
& wsl.exe -d $Distro -- bash $wslScript @arguments
if ($LASTEXITCODE -ne 0) { throw "FreeToken exited with code $LASTEXITCODE." }
