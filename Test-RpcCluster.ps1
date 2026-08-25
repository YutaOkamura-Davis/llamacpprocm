[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Server,

    [Parameter(Mandatory)]
    [string[]]$Rpc,

    [ValidateRange(100, 60000)]
    [int]$TimeoutMilliseconds = 3000,

    [switch]$ContinueOnTcpFailure,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Split-RpcEndpoint {
    param([string]$Endpoint)

    if ($Endpoint -match '^\[([^\]]+)\]:([0-9]+)$' -or $Endpoint -match '^([^:]+):([0-9]+)$') {
        $portValue = [int]$matches[2]
        if ($portValue -lt 1 -or $portValue -gt 65535) { throw "Invalid RPC port in $Endpoint" }
        return [pscustomobject]@{ Host = $matches[1]; Port = $portValue; Endpoint = $Endpoint }
    }
    throw "Invalid RPC endpoint '$Endpoint'. Use host:port or [IPv6]:port."
}

function Test-TcpEndpoint {
    param([string]$ComputerName, [int]$TcpPort, [int]$Timeout)

    $client = [Net.Sockets.TcpClient]::new()
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $result = $client.BeginConnect($ComputerName, $TcpPort, $null, $null)
        if (-not $result.AsyncWaitHandle.WaitOne($Timeout, $false)) {
            return [pscustomobject]@{ Reachable = $false; Milliseconds = $stopwatch.ElapsedMilliseconds; Error = 'timeout' }
        }
        $client.EndConnect($result)
        return [pscustomobject]@{ Reachable = $true; Milliseconds = $stopwatch.ElapsedMilliseconds; Error = $null }
    } catch {
        return [pscustomobject]@{ Reachable = $false; Milliseconds = $stopwatch.ElapsedMilliseconds; Error = $_.Exception.Message }
    } finally {
        $stopwatch.Stop()
        $client.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $Server -PathType Leaf)) { throw "Server executable not found: $Server" }
if (-not $Rpc) { throw 'At least one RPC endpoint is required.' }

$parsedEndpoints = @($Rpc | ForEach-Object { Split-RpcEndpoint $_ })
if (($parsedEndpoints.Endpoint | Sort-Object -Unique).Count -ne $parsedEndpoints.Count) {
    throw 'RPC endpoints must be unique.'
}

$checks = @(foreach ($endpoint in $parsedEndpoints) {
    $result = Test-TcpEndpoint $endpoint.Host $endpoint.Port $TimeoutMilliseconds
    [ordered]@{
        Endpoint = $endpoint.Endpoint
        Reachable = $result.Reachable
        ConnectMilliseconds = $result.Milliseconds
        Error = $result.Error
    }
})

$failed = @($checks | Where-Object { -not $_.Reachable })
if ($DryRun) {
    [ordered]@{
        Rpc = $parsedEndpoints.Endpoint
        TcpChecks = $checks
        ProbeCommand = "`"$Server`" --rpc $($parsedEndpoints.Endpoint -join ',') --list-devices"
    } | ConvertTo-Json -Depth 6
    return
}
if ($failed -and -not $ContinueOnTcpFailure) {
    throw "TCP preflight failed: $($failed.Endpoint -join ', ')"
}

$deviceOutput = @(& $Server --rpc ($parsedEndpoints.Endpoint -join ',') --list-devices 2>&1 | ForEach-Object {
    [string]$_
})
$probeExitCode = $LASTEXITCODE

[ordered]@{
    Timestamp = (Get-Date).ToString('o')
    Rpc = $parsedEndpoints.Endpoint
    TcpChecks = $checks
    DeviceProbeExitCode = $probeExitCode
    DeviceOutput = $deviceOutput
} | ConvertTo-Json -Depth 8

if ($probeExitCode -ne 0) { exit $probeExitCode }
