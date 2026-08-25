[CmdletBinding()]
param(
    [string[]]$Distro = @(),
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

function Test-CommandAvailable {
    param([Parameter(Mandatory)][string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-NativeText {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @())
    try {
        $text = (& $FilePath @ArgumentList 2>&1 | Out-String).Trim()
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $text }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Text = $_.Exception.Message }
    }
}

function Convert-KeyValueLines {
    param([string[]]$Lines)
    $map = [ordered]@{}
    foreach ($line in $Lines) {
        if ($line -match '^([^=]+)=(.*)$') { $map[$matches[1]] = $matches[2].Trim() }
    }
    return $map
}

$gpu = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object {
    [ordered]@{
        Name = $_.Name
        DriverVersion = $_.DriverVersion
        PnpDeviceId = $_.PNPDeviceID
    }
})

$nativeTools = [ordered]@{}
foreach ($name in @('git', 'cmake', 'ninja', 'py', 'python', 'uv', 'nvidia-smi', 'rocminfo', 'hipInfo', 'amd-smi')) {
    $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    $nativeTools[$name] = if ($command) { $command.Source } else { $null }
}

$nvidia = $null
if ($nativeTools['nvidia-smi']) {
    $query = Invoke-NativeText -FilePath $nativeTools['nvidia-smi'] -ArgumentList @(
        '--query-gpu=name,driver_version,memory.total,memory.free', '--format=csv,noheader,nounits'
    )
    $summary = Invoke-NativeText -FilePath $nativeTools['nvidia-smi']
    $maxCuda = if ($summary.Text -match 'CUDA Version:\s*([0-9.]+)') { $matches[1] } else { $null }
    $nvidia = [ordered]@{
        ExitCode = $query.ExitCode
        Query = $query.Text
        DriverMaxCuda = $maxCuda
    }
}

$nativeRocm = [ordered]@{ Target = $null; Probe = $null }
$rocminfoCommand = $nativeTools['rocminfo']
if (-not $rocminfoCommand -and $env:HIP_PATH) {
    $candidate = Join-Path $env:HIP_PATH 'bin\rocminfo.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $rocminfoCommand = $candidate }
}
if ($rocminfoCommand) {
    $probe = Invoke-NativeText -FilePath $rocminfoCommand
    $targets = @([regex]::Matches($probe.Text, 'gfx[0-9a-z]+') | ForEach-Object Value | Sort-Object -Unique)
    $nativeRocm = [ordered]@{
        Target = if ($targets) { $targets -join ',' } else { $null }
        Probe = if ($probe.Text.Length -gt 2000) { $probe.Text.Substring(0, 2000) } else { $probe.Text }
    }
}

$wslCommandAvailable = Test-CommandAvailable 'wsl.exe'
$wslAvailable = $false
$wslVersion = $null
$distros = @()
if ($wslCommandAvailable) {
    $versionProbe = Invoke-NativeText -FilePath 'wsl.exe' -ArgumentList @('--version')
    $wslVersion = $versionProbe.Text.Replace(([char]0).ToString(), [string]::Empty)
    $wslAvailable = $versionProbe.ExitCode -eq 0
}
if ($wslAvailable) {
    if (-not $Distro) {
        $distros = @(& wsl.exe --list --quiet 2>$null | ForEach-Object {
            ([string]$_).Replace(([char]0).ToString(), [string]::Empty).Trim()
        } | Where-Object { $_ })
    } else {
        $distros = @($Distro)
    }
}

$wslProbes = @(foreach ($name in $distros) {
    $probeScript = @'
set +e
kv() { printf '%s=%s\n' "$1" "$2"; }
kv ARCH "$(uname -m 2>/dev/null)"
kv OS "$(. /etc/os-release 2>/dev/null; printf '%s %s' "${ID:-unknown}" "${VERSION_ID:-unknown}")"
kv PYTHON "$(python3 --version 2>/dev/null)"
kv UV "$(uv --version 2>/dev/null)"
kv DXG "$(test -e /dev/dxg && printf yes || printf no)"
kv NVIDIA "$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits 2>/dev/null | tr '\n' ';')"
kv NVCC "$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9.]*\).*/\1/p' | head -1)"
kv ROCM "$(rocminfo 2>/dev/null | grep -oE 'gfx[0-9a-z]+' | sort -u | tr '\n' ',')"
kv ROCM_VERSION "$(cat /opt/rocm/.info/version 2>/dev/null || rocm-smi --showdriverversion 2>/dev/null | head -1)"
'@
    $raw = @(& wsl.exe -d $name -- bash -lc $probeScript 2>&1)
    $exitCode = $LASTEXITCODE
    $map = Convert-KeyValueLines -Lines $raw
    [ordered]@{
        Distro = $name
        ExitCode = $exitCode
        Architecture = $map['ARCH']
        OS = $map['OS']
        Python = $map['PYTHON']
        Uv = $map['UV']
        DxgDevice = $map['DXG']
        Nvidia = $map['NVIDIA']
        Nvcc = $map['NVCC']
        RocmTargets = $map['ROCM']
        RocmVersion = $map['ROCM_VERSION']
        Raw = if ($exitCode -ne 0) { ($raw -join "`n") } else { $null }
    }
})

$hasFlow = [bool]($gpu.Name -match 'Radeon|Ryzen AI')
$hasNvidia = [bool]($gpu.Name -match 'NVIDIA|RTX')
$flowNativeTarget = [bool]($nativeRocm.Target -match '(^|,)gfx1151(,|$)')
$wslNvidiaReady = [bool]($wslProbes | Where-Object { $_.Nvidia })
$wslRocmReady = [bool]($wslProbes | Where-Object { $_.RocmTargets -match 'gfx1151' })
$nativeCuda13 = [bool]($nvidia -and $nvidia.DriverMaxCuda -and [version]$nvidia.DriverMaxCuda -ge [version]'13.0')

$decisions = @(
    [ordered]@{
        Engine = 'DFlash 2 / llama.cpp RPC'
        Status = 'preferred'
        Reason = 'Native Windows mixed-vendor path; benchmark Flow Vulkan versus HIP and use RPC only when it improves capacity or measured speed.'
    },
    [ordered]@{
        Engine = 'FreeToken native Windows ROCm fork'
        Status = if ($flowNativeTarget) { 'experimental-ready' } elseif ($hasFlow) { 'needs-ROCm-probe' } else { 'not-applicable' }
        Reason = 'gfx1151 is parameterizable, but this community port was verified on gfx1201 and its Windows MoE offload/GGUF paths remain incomplete.'
    },
    [ordered]@{
        Engine = 'vLLM native Windows ROCm fork'
        Status = if ($flowNativeTarget) { 'experimental-ready' } elseif ($hasFlow) { 'needs-pinned-build' } else { 'not-applicable' }
        Reason = 'The pinned community fork has native Windows HIP extensions and gfx1151-tuned kernels, but its published end-to-end qualification is gfx1201 and it is single-GPU only.'
    },
    [ordered]@{
        Engine = 'vLLM native Windows CUDA fork'
        Status = if ($nativeCuda13) { 'candidate' } elseif ($hasNvidia) { 'needs-CUDA13-driver' } else { 'not-applicable' }
        Reason = 'The pinned released wheel explicitly includes Ampere and Ada, but it is community-maintained; local multi-GPU additionally needs a separately built Windows NCCL DLL.'
    },
    [ordered]@{
        Engine = 'FreeToken official under WSL2'
        Status = if ($wslNvidiaReady) { 'candidate' } elseif ($hasNvidia) { 'needs-WSL-GPU' } else { 'not-applicable' }
        Reason = 'Official source requires Linux, NVIDIA, driver r580+, CUDA 13, and nvcc; it is a local MoE-offload engine, not cross-PC RPC.'
    },
    [ordered]@{
        Engine = 'vLLM under WSL2'
        Status = if ($wslRocmReady -or $wslNvidiaReady) { 'candidate' } else { 'needs-WSL-GPU' }
        Reason = 'Official vLLM is Linux-only natively. Use WSL for the supported upstream path; raw Ethernet collectives across these PCs are an experimental throughput path.'
    }
)

$report = [ordered]@{
    SchemaVersion = 1
    Timestamp = (Get-Date).ToString('o')
    ComputerName = $env:COMPUTERNAME
    Windows = [ordered]@{
        Caption = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
        Version = [Environment]::OSVersion.Version.ToString()
        PowerShell = $PSVersionTable.PSVersion.ToString()
        LogicalProcessors = [Environment]::ProcessorCount
        PhysicalMemoryGiB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)
    }
    GPUs = $gpu
    NativeTools = $nativeTools
    Nvidia = $nvidia
    NativeRocm = $nativeRocm
    WSL = [ordered]@{
        CommandAvailable = $wslCommandAvailable
        Available = $wslAvailable
        Version = $wslVersion
        Probes = $wslProbes
    }
    Decisions = $decisions
}

$json = $report | ConvertTo-Json -Depth 9
if ($OutputPath) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8
}
$json
