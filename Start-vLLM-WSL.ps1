[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Distro,
    [Parameter(Mandatory)][string]$Model,
    [string]$EnvironmentPath = '~/.venvs/vllm-v4',
    [ValidateRange(1, 65535)][int]$Port = 8000,
    [ValidateRange(0.1, 0.99)][double]$GpuMemoryUtilization = 0.90,
    [ValidateRange(256, 1048576)][int]$MaxModelLength = 32768,
    [ValidateRange(0, 256)][double]$CpuOffloadGiB = 0,
    [ValidateRange(1, 16)][int]$TensorParallelSize = 1,
    [ValidateRange(1, 16)][int]$PipelineParallelSize = 1,
    [ValidateSet('auto', 'half', 'float16', 'bfloat16', 'float', 'float32')]
    [string]$Dtype = 'auto',
    [string]$Quantization = '',
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
$script = Join-Path $PSScriptRoot 'wsl\Start-vLLM.sh'
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw "Launcher payload not found: $script" }
$arguments = @(
    $EnvironmentPath, $Model, [string]$Port,
    $GpuMemoryUtilization.ToString([Globalization.CultureInfo]::InvariantCulture),
    [string]$MaxModelLength,
    $CpuOffloadGiB.ToString([Globalization.CultureInfo]::InvariantCulture),
    [string]$TensorParallelSize, [string]$PipelineParallelSize, $Dtype, $Quantization
) + $ExtraArgument
if ($DryRun) {
    [ordered]@{
        Distro = $Distro
        Script = $script
        Arguments = $arguments
        Bind = '127.0.0.1 only'
        Note = 'For the Aurora two-GPU experiment, benchmark -PipelineParallelSize 2 before tensor parallelism because the GPUs have unequal VRAM and no NVLink.'
    } | ConvertTo-Json -Depth 5
    return
}
$wslScript = Resolve-WslPath -WindowsPath (Resolve-Path -LiteralPath $script).Path
& wsl.exe -d $Distro -- bash $wslScript @arguments
if ($LASTEXITCODE -ne 0) { throw "vLLM exited with code $LASTEXITCODE." }
