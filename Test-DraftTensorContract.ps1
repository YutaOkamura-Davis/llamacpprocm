[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LlamaCli,
    [Parameter(Mandatory)][string]$DraftModel,
    [int]$ExpectedTensorCount = 58
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $LlamaCli -PathType Leaf)) { throw "llama-cli not found: $LlamaCli" }
if (-not (Test-Path -LiteralPath $DraftModel -PathType Leaf)) { throw "draft model not found: $DraftModel" }

# A deliberately tiny invocation: model-load diagnostics are emitted before generation.
# We capture stderr/stdout because llama.cpp has moved some loader logging between streams over time.
$output = @(& $LlamaCli -m $DraftModel -n 1 -p 'x' -ngl 0 2>&1)
$exitCode = $LASTEXITCODE
$text = $output -join "`n"

$wrongCount = [regex]::Match($text, 'wrong number of tensors;\s*expected\s+(\d+),\s*got\s+(\d+)', 'IgnoreCase')
if ($wrongCount.Success) {
    $expected = [int]$wrongCount.Groups[1].Value
    $got = [int]$wrongCount.Groups[2].Value
    throw "Draft tensor-contract mismatch: loader expected $expected and model supplied $got. Experimental goal is compatibility with the $ExpectedTensorCount-tensor public draft."
}

$reported = [regex]::Matches($text, '(?:tensor(?:s)?[^\r\n]{0,40}?)(\d+)', 'IgnoreCase') |
    ForEach-Object { [int]$_.Groups[1].Value }

[ordered]@{
    ExitCode = $exitCode
    ExpectedDraftTensorCount = $ExpectedTensorCount
    WrongTensorCountDiagnostic = $false
    ObservedTensorNumbers = @($reported | Sort-Object -Unique)
    Model = (Resolve-Path -LiteralPath $DraftModel).Path
    Cli = (Resolve-Path -LiteralPath $LlamaCli).Path
} | ConvertTo-Json -Depth 4

if ($exitCode -ne 0) {
    Write-Warning "llama-cli exited $exitCode. No explicit tensor-count mismatch was detected; inspect the loader output for another incompatibility."
    $output | ForEach-Object { Write-Host $_ }
    exit $exitCode
}
