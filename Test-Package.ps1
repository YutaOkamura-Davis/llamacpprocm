[CmdletBinding()]
param(
    [string]$PackageDirectory = $PSScriptRoot,
    [switch]$RequireAuthenticode
)

$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $PackageDirectory 'SHA256SUMS.txt'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Checksum manifest not found: $manifestPath"
}

$results = @(foreach ($line in Get-Content -LiteralPath $manifestPath) {
    if (-not $line.Trim()) { continue }
    if ($line -notmatch '^([0-9a-fA-F]{64})  (.+)$') { throw "Malformed checksum line: $line" }
    $expected = $matches[1].ToLowerInvariant()
    $relativePath = $matches[2]
    $fullPath = Join-Path $PackageDirectory ($relativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        [pscustomobject]@{ Path = $relativePath; Exists = $false; HashMatches = $false; SignatureStatus = $null }
        continue
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash.ToLowerInvariant()
    $signatureStatus = $null
    if ([IO.Path]::GetExtension($fullPath) -in @('.exe', '.dll')) {
        $signatureStatus = [string](Get-AuthenticodeSignature -LiteralPath $fullPath).Status
    }
    [pscustomobject]@{
        Path = $relativePath
        Exists = $true
        HashMatches = $actual -eq $expected
        SignatureStatus = $signatureStatus
    }
})

$failedHash = @($results | Where-Object { -not $_.Exists -or -not $_.HashMatches })
$failedSignature = @($results | Where-Object {
    $_.SignatureStatus -and $_.SignatureStatus -ne 'Valid'
})

[ordered]@{
    Timestamp = (Get-Date).ToString('o')
    PackageDirectory = (Resolve-Path -LiteralPath $PackageDirectory).Path
    FilesChecked = $results.Count
    HashesValid = $failedHash.Count -eq 0
    AllBinariesAuthenticodeSigned = $failedSignature.Count -eq 0
    Note = 'The supplied prebuilt binaries are expected to be unsigned; SHA-256 is the package integrity control.'
    Failures = $failedHash
} | ConvertTo-Json -Depth 7

if ($failedHash) { exit 1 }
if ($RequireAuthenticode -and $failedSignature) { exit 2 }
