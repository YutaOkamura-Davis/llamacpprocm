[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Model,
    [string]$InstallDirectory = 'C:\llm-runtimes\freetoken-windows-rocm',
    [string]$RocmPath = $env:HIP_PATH,
    [ValidatePattern('^gfx[0-9a-z]+$')][string]$Architecture = 'gfx1151',
    [ValidateSet('Dense', 'MoE')][string]$Mode = 'Dense',
    [ValidateRange(1, 65535)][int]$Port = 1919,
    [ValidateRange(0, 1048576)][int]$KVPages = 0,
    [string[]]$ExtraArgument = @(),
    [switch]$AllowExperimentalGGUF,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$expectedCommit = '45675e47348a167a9b36ca224ad310c1ee1e34b4'
if (-not (Test-Path -LiteralPath (Join-Path $InstallDirectory '.git') -PathType Container)) {
    throw "FreeToken fork is not installed at $InstallDirectory"
}
$actual = (& git.exe -C $InstallDirectory rev-parse HEAD 2>&1 | Out-String).Trim()
if ($actual -ne $expectedCommit) { throw "FreeToken source is $actual; v4 requires $expectedCommit." }
if (-not $RocmPath -or -not (Test-Path -LiteralPath $RocmPath -PathType Container)) { throw 'Pass -RocmPath or set HIP_PATH.' }
$isLocalModel = Test-Path -LiteralPath $Model
$isHuggingFaceId = $Model -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
if (-not $isLocalModel -and -not $isHuggingFaceId) { throw 'Model must be a local path or owner/repository Hugging Face ID.' }
if ($Model -match '\.gguf$' -and -not $AllowExperimentalGGUF) {
    throw 'Packed GGUF execution in this fork is not yet end-to-end qualified on gfx1151. Use a supported HF checkpoint, or pass -AllowExperimentalGGUF for a lab test.'
}
foreach ($value in @($Model, $RocmPath)) {
    if ($value -match '[\r\n%]') { throw 'Model and ROCm paths cannot contain newlines or percent signs because the pinned fork launches through cmd.exe.' }
}
foreach ($value in $ExtraArgument) {
    if ($value -match '[\r\n&|<>^%]') { throw "Unsafe command-shell metacharacter in ExtraArgument: $value" }
}

$runner = Join-Path $InstallDirectory 'dist\run-server.ps1'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Fork launcher missing: $runner" }
$extra = @($ExtraArgument)
if ($Mode -eq 'MoE') {
    $extra += @('--moe-backend', 'fused', '--cuda-graph-max-bs', '0')
}
$payload = [ordered]@{
    Runner = $runner
    Model = $Model
    Architecture = $Architecture
    RocmPath = $RocmPath
    Port = $Port
    KVPages = $KVPages
    Extra = $extra
}
if ($DryRun) {
    [ordered]@{
        Executable = 'powershell.exe'
        Payload = $payload
        SourceCommit = $actual
        Qualification = if ($Mode -eq 'MoE') { 'Experimental fused/eager MoE; offload is intentionally disabled.' } else { 'Experimental dense gfx1151 path.' }
    } | ConvertTo-Json -Depth 6
    return
}
$payloadJson = $payload | ConvertTo-Json -Depth 6 -Compress
$payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payloadJson))
$childScript = @'
$ErrorActionPreference = 'Stop'
$json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:DFLASH_V4_FT_PAYLOAD))
$p = $json | ConvertFrom-Json
& $p.Runner -Model $p.Model -Arch $p.Architecture -RocmPath $p.RocmPath `
    -Port ([int]$p.Port) -KVPages ([int]$p.KVPages) -ExtraArgs @($p.Extra)
'@
$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
$priorPayload = [Environment]::GetEnvironmentVariable('DFLASH_V4_FT_PAYLOAD', 'Process')
try {
    [Environment]::SetEnvironmentVariable('DFLASH_V4_FT_PAYLOAD', $payloadBase64, 'Process')
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand
    $childExitCode = $LASTEXITCODE
} finally {
    [Environment]::SetEnvironmentVariable('DFLASH_V4_FT_PAYLOAD', $priorPayload, 'Process')
}
if ($childExitCode -ne 0) { throw "FreeToken Windows launcher failed with exit code $childExitCode." }
