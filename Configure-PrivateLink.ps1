[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$InterfaceAlias,

    [Parameter(Mandatory)]
    [ipaddress]$LocalAddress,

    [Parameter(Mandatory)]
    [ipaddress]$PeerAddress,

    [ValidateRange(1, 32)]
    [int]$PrefixLength = 30,

    [ValidateRange(1, 65535)]
    [int]$RpcPort = 50052,

    [switch]$DisableDnsRegistration
)

$ErrorActionPreference = 'Stop'

function Test-SameIPv4Subnet {
    param([ipaddress]$Left, [ipaddress]$Right, [int]$Prefix)

    $leftBytes = $Left.GetAddressBytes()
    $rightBytes = $Right.GetAddressBytes()
    $remaining = $Prefix
    for ($i = 0; $i -lt 4; $i++) {
        if ($remaining -ge 8) {
            $mask = 255
        } elseif ($remaining -le 0) {
            $mask = 0
        } else {
            $mask = 256 - [math]::Pow(2, 8 - $remaining)
        }
        if (($leftBytes[$i] -band [int]$mask) -ne ($rightBytes[$i] -band [int]$mask)) {
            return $false
        }
        $remaining -= 8
    }
    return $true
}

function Test-Rfc1918Address {
    param([ipaddress]$Address)

    $bytes = $Address.GetAddressBytes()
    return ($bytes[0] -eq 10) -or
        ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell window.'
}
if ($LocalAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
    $PeerAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'This helper accepts IPv4 addresses only.'
}
if ($LocalAddress.Equals($PeerAddress)) { throw 'LocalAddress and PeerAddress must differ.' }
if (-not (Test-SameIPv4Subnet $LocalAddress $PeerAddress $PrefixLength)) {
    throw "$LocalAddress and $PeerAddress are not in the same /$PrefixLength subnet."
}

$firstBytes = @($LocalAddress.GetAddressBytes()[0], $PeerAddress.GetAddressBytes()[0])
if ($firstBytes | Where-Object { $_ -eq 0 -or $_ -eq 127 -or $_ -ge 224 }) {
    throw 'Unspecified, loopback, multicast, and reserved addresses are not valid for a private RPC link.'
}
if (-not (Test-Rfc1918Address $LocalAddress) -or -not (Test-Rfc1918Address $PeerAddress)) {
    Write-Warning 'At least one address is not RFC1918 private space. Do not expose llama.cpp RPC to an untrusted network.'
}

$adapter = Get-NetAdapter -Name $InterfaceAlias -ErrorAction Stop
if ($adapter.Status -notin @('Up', 'Disconnected')) {
    throw "Adapter $InterfaceAlias is not usable (status: $($adapter.Status))."
}

$existingAddress = @(Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 `
    -ErrorAction SilentlyContinue | Where-Object IPAddress -eq $LocalAddress.IPAddressToString)
if ($existingAddress -and $existingAddress[0].PrefixLength -ne $PrefixLength) {
    throw "$LocalAddress already exists on $InterfaceAlias with prefix /$($existingAddress[0].PrefixLength), not /$PrefixLength."
}
if (-not $existingAddress -and $PSCmdlet.ShouldProcess(
        $InterfaceAlias, "Add $LocalAddress/$PrefixLength")) {
    New-NetIPAddress -InterfaceAlias $InterfaceAlias `
        -IPAddress $LocalAddress.IPAddressToString -PrefixLength $PrefixLength | Out-Null
}

if ($DisableDnsRegistration -and $PSCmdlet.ShouldProcess(
        $InterfaceAlias, 'Disable DNS registration on the point-to-point link')) {
    Set-DnsClient -InterfaceAlias $InterfaceAlias -RegisterThisConnectionsAddress $false
}

$ruleName = "llama.cpp RPC $($PeerAddress.IPAddressToString) to $($LocalAddress.IPAddressToString):$RpcPort"
$existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if (-not $existingRule -and $PSCmdlet.ShouldProcess(
        $ruleName, "Permit TCP from $PeerAddress to $LocalAddress on port $RpcPort")) {
    New-NetFirewallRule -DisplayName $ruleName -Group 'llama.cpp RPC private' `
        -Direction Inbound -Action Allow -Enabled True -Protocol TCP `
        -LocalPort $RpcPort -LocalAddress $LocalAddress.IPAddressToString `
        -RemoteAddress $PeerAddress.IPAddressToString -InterfaceAlias $InterfaceAlias `
        -Profile Any | Out-Null
} elseif ($existingRule -and $PSCmdlet.ShouldProcess($ruleName, 'Enable the existing peer-restricted rule')) {
    $existingRule | Set-NetFirewallRule -Enabled True -Action Allow | Out-Null
}

[ordered]@{
    InterfaceAlias = $InterfaceAlias
    Status = [string]$adapter.Status
    LinkSpeed = [string]$adapter.LinkSpeed
    MtuBytes = $adapter.MtuSize
    LocalAddress = $LocalAddress.IPAddressToString
    PeerAddress = $PeerAddress.IPAddressToString
    PrefixLength = $PrefixLength
    RpcPort = $RpcPort
    FirewallRule = $ruleName
} | ConvertTo-Json
