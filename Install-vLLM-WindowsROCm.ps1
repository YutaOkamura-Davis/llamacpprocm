[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\AI\vllm-gfx1151',
    [ValidateRange(1, 64)][int]$MaxJobs = 12,
    [ValidateRange(1.0, 256.0)][double]$GuardLimitGiB = 50.0,
    [ValidateRange(0.0, 256.0)][double]$GuardWarnGiB = 46.0,
    [switch]$Apply,
    [switch]$AcceptExperimentalRisk
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Repository = 'https://github.com/charlie12345/vLLM_for_AMD.git'
$Commit = '89f703a1fb1dd583ff976b977d60cf5082532943'
$PatchFile = Join-Path $PSScriptRoot 'patches\vllm-windows-rocm-gfx1151.patch'
$ExpectedChangedFiles = @(
    'env_windows_rocm.cmd',
    'serve_windows_rocm.cmd',
    'setup_windows_rocm.ps1'
)

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Capture)
    if ($Capture) {
        $result = (& git @Arguments | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $result" }
        return $result
    }
    & git @Arguments
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE." }
}

function Normalize-GitUrl([string]$Value) {
    return ($Value.Trim().TrimEnd('/') -replace '\.git$', '').ToLowerInvariant()
}

if ($env:OS -ne 'Windows_NT') { throw 'This adapter is for native 64-bit Windows only.' }
if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
    throw 'Run this adapter from 64-bit PowerShell on 64-bit Windows.'
}
if ($GuardWarnGiB -ge $GuardLimitGiB) { throw 'GuardWarnGiB must be below GuardLimitGiB.' }
if (-not (Test-Path -LiteralPath $PatchFile -PathType Leaf)) { throw "Missing adapter patch: $PatchFile" }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git for Windows is required.' }

$resolvedParent = Split-Path -Parent $InstallRoot
if (-not $resolvedParent) { throw 'InstallRoot must include an explicit parent directory.' }

$patchHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $PatchFile).Hash.ToLowerInvariant()
$gpuNames = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
    ForEach-Object Name)

Write-Host 'Native Windows vLLM gfx1151 adaptation plan' -ForegroundColor Cyan
Write-Host "  Source:       $Repository"
Write-Host "  Commit:       $Commit"
Write-Host "  Destination:  $InstallRoot"
Write-Host "  Patch SHA256: $patchHash"
Write-Host "  GPU(s):       $($gpuNames -join '; ')"
Write-Host '  Stack:        Python 3.12, Torch 2.11.0+rocm7.13.0, ROCm 7.13.0, Triton Windows 3.6.0.post26'
Write-Host '  Target:       gfx1151 only; single process / single GPU; Safetensors/HF models; no GGUF'
Write-Host "  VRAM guard:   warn $GuardWarnGiB GiB / stop $GuardLimitGiB GiB"
Write-Host ''
Write-Warning 'This is a pinned community vLLM 0.26.0 fork. Its native Windows path was tested upstream on gfx1201, not this Flow gfx1151.'

if (-not $Apply) {
    Write-Host 'Plan only: no directory, environment, package, GPU context, or build was changed.'
    Write-Host 'Rerun with -Apply -AcceptExperimentalRisk after installing uv and Visual Studio 2022 Build Tools (Desktop C++).'
    return
}
if (-not $AcceptExperimentalRisk) {
    throw 'Apply requires -AcceptExperimentalRisk because this exact gfx1151 build is not upstream-qualified.'
}
if ($gpuNames -notmatch 'AMD|Radeon|Ryzen') { throw 'No AMD/Radeon Windows display adapter was detected.' }

if (-not (Test-Path -LiteralPath $InstallRoot)) {
    if (-not (Test-Path -LiteralPath $resolvedParent)) {
        New-Item -ItemType Directory -Path $resolvedParent -Force | Out-Null
    }
    Invoke-Git -Arguments @('clone', '--filter=blob:none', $Repository, $InstallRoot)
    Invoke-Git -Arguments @('-C', $InstallRoot, 'checkout', '--detach', $Commit)
} else {
    if (-not (Test-Path -LiteralPath (Join-Path $InstallRoot '.git'))) {
        throw "InstallRoot exists but is not a Git clone: $InstallRoot"
    }
}

$actualCommit = Invoke-Git -Arguments @('-C', $InstallRoot, 'rev-parse', 'HEAD') -Capture
if ($actualCommit -ne $Commit) {
    throw "Refusing a different source revision. Expected $Commit; found $actualCommit."
}
$actualOrigin = Invoke-Git -Arguments @('-C', $InstallRoot, 'remote', 'get-url', 'origin') -Capture
if ((Normalize-GitUrl $actualOrigin) -ne (Normalize-GitUrl $Repository)) {
    throw "Unexpected origin '$actualOrigin'; expected '$Repository'."
}

& git -C $InstallRoot apply --check --whitespace=nowarn $PatchFile 2>$null
$canApply = $LASTEXITCODE -eq 0
if ($canApply) {
    Invoke-Git -Arguments @('-C', $InstallRoot, 'apply', '--whitespace=nowarn', $PatchFile)
} else {
    & git -C $InstallRoot apply --reverse --check --whitespace=nowarn $PatchFile 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'The pinned adapter patch is neither cleanly applicable nor already applied. Refusing an ambiguous source tree.'
    }
}

$changed = @((Invoke-Git -Arguments @('-C', $InstallRoot, 'diff', '--name-only') -Capture) -split "`r?`n" |
    Where-Object { $_ } | Sort-Object -Unique)
$unexpected = @($changed | Where-Object { $_ -notin $ExpectedChangedFiles })
$missing = @($ExpectedChangedFiles | Where-Object { $_ -notin $changed })
if ($unexpected -or $missing) {
    throw "Source diff is not exactly the audited gfx1151 patch. Unexpected: $($unexpected -join ', '); missing: $($missing -join ', ')."
}
$untracked = @((Invoke-Git -Arguments @(
    '-C', $InstallRoot, 'ls-files', '--others', '--exclude-standard'
) -Capture) -split "`r?`n" | Where-Object {
    $_ -and $_ -ne 'dflash-v4-adapter.json' -and -not $_.StartsWith('.venv211/')
})
if ($untracked) {
    throw "Untracked source files could affect the build: $($untracked -join ', ')"
}

& git -C $InstallRoot diff --check
if ($LASTEXITCODE -ne 0) { throw 'The applied adapter patch failed git diff --check.' }

$setup = Join-Path $InstallRoot 'setup_windows_rocm.ps1'
& $setup -MaxJobs $MaxJobs -GuardLimitGiB $GuardLimitGiB -GuardWarnGiB $GuardWarnGiB
if ($LASTEXITCODE -ne 0) { throw "The pinned fork setup failed with exit code $LASTEXITCODE." }

$record = [ordered]@{
    Adapter = 'dflash-rpc-windows-v4-vllm-gfx1151'
    InstalledAt = (Get-Date).ToString('o')
    Repository = $Repository
    Commit = $Commit
    PatchSha256 = $patchHash
    Architecture = 'gfx1151'
    MaxJobs = $MaxJobs
} | ConvertTo-Json -Depth 4
Set-Content -LiteralPath (Join-Path $InstallRoot 'dflash-v4-adapter.json') -Value $record -Encoding UTF8

Write-Host ''
Write-Host 'Native Windows vLLM gfx1151 build completed. Qualify a small model before loading a heavy checkpoint.' -ForegroundColor Green
