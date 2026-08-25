[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$VulkanBench,

    [Parameter(Mandatory)]
    [string]$HipBench,

    [Parameter(Mandatory)]
    [string]$Model,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'benchmark-results\flow-backends'),

    [ValidateRange(32, 65536)]
    [int[]]$UBatchSize = @(128, 256, 512),
    [ValidateRange(0, 1048576)]
    [int[]]$DepthTokens = @(0, 8192, 32768),
    [ValidateRange(16, 131072)]
    [int]$PromptTokens = 512,
    [ValidateRange(16, 8192)]
    [int]$GenerateTokens = 128,
    [ValidateRange(1, 20)]
    [int]$Repetitions = 3,
    [ValidateRange(32, 65536)]
    [int]$BatchSize = 2048,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$benchmarkScript = Join-Path $PSScriptRoot 'Benchmark-Layout.ps1'

foreach ($path in @($benchmarkScript, $VulkanBench, $HipBench, $Model)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "File not found: $path" }
}
if ($UBatchSize | Where-Object { $_ -gt $BatchSize }) {
    throw 'Every UBatchSize must be less than or equal to BatchSize.'
}

$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null
}

$runs = @(
    [pscustomobject]@{ Backend = 'Vulkan'; Bench = $VulkanBench; Device = 'Vulkan0' },
    [pscustomobject]@{ Backend = 'HIP'; Bench = $HipBench; Device = 'ROCm0' }
)

$records = [Collections.Generic.List[object]]::new()
foreach ($run in $runs) {
    $rawPath = Join-Path $resolvedOutput ("{0}-raw.jsonl" -f $run.Backend.ToLowerInvariant())
    $invoke = @{
        LlamaBench = $run.Bench
        Model = $Model
        DeviceList = $run.Device
        TensorSplit = '1'
        PromptTokens = $PromptTokens
        GenerateTokens = $GenerateTokens
        Repetitions = $Repetitions
        BatchSize = $BatchSize
        UBatchSize = $UBatchSize
        DepthTokens = $DepthTokens
        OutputFormat = 'jsonl'
        OutputPath = $rawPath
        DryRun = $DryRun
    }
    & $benchmarkScript @invoke
    if ($DryRun) { continue }

    foreach ($line in Get-Content -LiteralPath $rawPath) {
        if (-not $line.TrimStart().StartsWith('{')) { continue }
        try { $item = $line | ConvertFrom-Json } catch { continue }
        $records.Add([pscustomobject]@{
            Backend = $run.Backend
            Test = if ([int]$item.n_prompt -gt 0) { 'prompt' } else { 'generate' }
            PromptTokens = [int]$item.n_prompt
            GenerateTokens = [int]$item.n_gen
            DepthTokens = [int]$item.n_depth
            BatchSize = [int]$item.n_batch
            UBatchSize = [int]$item.n_ubatch
            TokensPerSecond = [double]$item.avg_ts
            StdDevTokensPerSecond = [double]$item.stddev_ts
        })
    }
}

if ($DryRun) { return }
if (-not $records.Count) { throw 'No JSONL benchmark records were parsed.' }

$allPath = Join-Path $resolvedOutput 'flow-backend-results.csv'
$bestPath = Join-Path $resolvedOutput 'flow-backend-best.csv'
$records | Sort-Object Test, DepthTokens, Backend, UBatchSize | Export-Csv -NoTypeInformation -LiteralPath $allPath

$best = @($records | Group-Object Test, DepthTokens | ForEach-Object {
    $_.Group | Sort-Object TokensPerSecond -Descending | Select-Object -First 1
})
$best | Sort-Object Test, DepthTokens | Export-Csv -NoTypeInformation -LiteralPath $bestPath

[ordered]@{
    OutputDirectory = $resolvedOutput
    RunsParsed = $records.Count
    BestByTestAndDepth = $best
    Interpretation = 'Use the winning backend for the local Flow controller, then validate DFlash2 end to end with Measure-Server.ps1.'
} | ConvertTo-Json -Depth 7
