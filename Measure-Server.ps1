[CmdletBinding()]
param(
    [uri]$Endpoint = 'http://127.0.0.1:8080/v1/chat/completions',
    [string]$ModelName = 'local-model',
    [string]$Prompt = 'Explain why layer-parallel RPC minimizes communication across a slow network. Be precise and concise.',
    [string]$PromptFile,
    [ValidateRange(16, 8192)]
    [int]$MaxTokens = 256,
    [ValidateRange(0, 10)]
    [int]$Warmup = 1,
    [ValidateRange(1, 50)]
    [int]$Repetitions = 3,
    [string]$ApiKey
)

$ErrorActionPreference = 'Stop'

if ($PromptFile) {
    if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) { throw "Prompt file not found: $PromptFile" }
    $Prompt = Get-Content -LiteralPath $PromptFile -Raw
}

$headers = @{}
if ($ApiKey) { $headers.Authorization = "Bearer $ApiKey" }
$body = [ordered]@{
    model = $ModelName
    messages = @([ordered]@{ role = 'user'; content = $Prompt })
    max_tokens = $MaxTokens
    temperature = 0
    stream = $false
}
$jsonBody = $body | ConvertTo-Json -Depth 6

function Invoke-OneRequest {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-RestMethod -Method Post -Uri $Endpoint -Headers $headers `
        -ContentType 'application/json' -Body $jsonBody
    $stopwatch.Stop()
    return [pscustomobject]@{
        WallSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
        PromptTokens = $response.usage.prompt_tokens
        GeneratedTokens = $response.usage.completion_tokens
        PromptTokensPerSecond = $response.timings.prompt_per_second
        GeneratedTokensPerSecond = $response.timings.predicted_per_second
        StopReason = $response.choices[0].finish_reason
    }
}

for ($i = 0; $i -lt $Warmup; $i++) { [void](Invoke-OneRequest) }
$results = @(for ($i = 0; $i -lt $Repetitions; $i++) { Invoke-OneRequest })

$promptSpeeds = @($results | Where-Object PromptTokensPerSecond | Select-Object -ExpandProperty PromptTokensPerSecond)
$generationSpeeds = @($results | Where-Object GeneratedTokensPerSecond | Select-Object -ExpandProperty GeneratedTokensPerSecond)

[ordered]@{
    Timestamp = (Get-Date).ToString('o')
    Endpoint = $Endpoint.AbsoluteUri
    WarmupRequests = $Warmup
    MeasuredRequests = $Repetitions
    AverageWallSeconds = [math]::Round(($results | Measure-Object WallSeconds -Average).Average, 3)
    AveragePromptTokensPerSecond = if ($promptSpeeds) {
        [math]::Round(($promptSpeeds | Measure-Object -Average).Average, 3)
    } else { $null }
    AverageGeneratedTokensPerSecond = if ($generationSpeeds) {
        [math]::Round(($generationSpeeds | Measure-Object -Average).Average, 3)
    } else { $null }
    Results = $results
} | ConvertTo-Json -Depth 8
