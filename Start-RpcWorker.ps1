[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RpcServer,

    [Parameter(Mandatory)]
    [ipaddress]$BindAddress,

    [string]$Device,

    [string]$CacheDirectory = 'C:\llama-rpc-cache',

    [ValidateRange(1, 65535)]
    [int]$Port = 50052,

    [ValidateRange(0, 256)]
    [int]$Threads = 0,

    [switch]$DisableCache,
    [switch]$EnableDebug,
    [switch]$SkipAddressCheck,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function ConvertTo-CommandText {
    param([string]$Executable, [string[]]$ArgumentList)

    $quoted = @($ArgumentList | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    })
    return ('"{0}" {1}' -f $Executable, ($quoted -join ' ')).Trim()
}

if (-not (Test-Path -LiteralPath $RpcServer -PathType Leaf)) {
    throw "RPC executable not found: $RpcServer"
}
if ($BindAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'Use the private link-specific IPv4 address.'
}
if ($BindAddress.IPAddressToString -in @('0.0.0.0', '127.0.0.1')) {
    throw 'Bind to the private link-specific address, not wildcard or loopback.'
}

if (-not $SkipAddressCheck) {
    $localAddress = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $BindAddress.IPAddressToString `
        -ErrorAction SilentlyContinue
    if (-not $localAddress) {
        throw "$BindAddress is not configured on this computer. Run Configure-PrivateLink.ps1 first."
    }
}

if ($Device) {
    $devices = @($Device -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $devices) { throw 'Device contained no usable device names.' }
    if ($devices | Where-Object { $_ -notmatch '^(CUDA|Vulkan|ROCm|CPU)[0-9]*$' }) {
        throw 'Device entries must look like CUDA0, CUDA1, Vulkan0, ROCm0, or CPU.'
    }
    $Device = $devices -join ','
}

if ($Threads -eq 0) {
    $coreCount = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
    if (-not $coreCount) { $coreCount = [Environment]::ProcessorCount }
    $Threads = [math]::Max(1, [int]$coreCount)
}

$arguments = @(
    '-H', $BindAddress.IPAddressToString,
    '-p', $Port,
    '-t', $Threads
)
if ($Device) { $arguments += @('-d', $Device) }

if (-not $DisableCache) {
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path $CacheDirectory | Out-Null
        $resolvedCacheDirectory = (Resolve-Path -LiteralPath $CacheDirectory).Path
        $env:LLAMA_CACHE = $resolvedCacheDirectory
    } else {
        $resolvedCacheDirectory = [IO.Path]::GetFullPath($CacheDirectory)
    }
    $arguments += '-c'
}
if ($EnableDebug -and -not $DryRun) { $env:GGML_RPC_DEBUG = '1' }

$commandText = ConvertTo-CommandText $RpcServer $arguments
Write-Warning 'llama.cpp RPC has no authentication or encryption. Keep this endpoint peer-firewalled and private.'
Write-Host "Launching: $commandText"
if ($Device -and $Device -match '(^|,)CPU(,|$)') {
    Write-Warning 'Remote CPU adds capacity but is normally much slower than GPU-only placement.'
}
if (-not $Device) {
    Write-Host 'Device selection: all detected accelerators (upstream default).'
}
if (-not $DisableCache) { Write-Host "Tensor cache: $resolvedCacheDirectory" }
if ($DryRun) { return }

& $RpcServer @arguments
exit $LASTEXITCODE
