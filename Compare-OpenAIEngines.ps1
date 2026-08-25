[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ConfigFile,

    [string]$Prompt = 'Explain why pipelining a transformer over ordinary Ethernet can reduce capacity pressure but hurt single-user token latency. Be precise.',
    [string]$PromptFile,
    [ValidateRange(8, 8192)]
    [int]$MaxTokens = 256,
    [ValidateRange(0, 10)]
    [int]$Warmup = 1,
    [ValidateRange(1, 20)]
    [int]$Repetitions = 3,
    [ValidateCount(1, 8)]
    [ValidateRange(1, 32)]
    [int[]]$Concurrency = @(1, 2, 4),
    [ValidateRange(10, 3600)]
    [int]$RequestTimeoutSeconds = 600,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) { throw "Config file not found: $ConfigFile" }
if ($PromptFile) {
    if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) { throw "Prompt file not found: $PromptFile" }
    $Prompt = Get-Content -LiteralPath $PromptFile -Raw
}

$engines = @(Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json)
if (-not $engines) { throw 'The configuration must contain at least one engine.' }

function Get-PropertyValue {
    param([object]$Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Get-ContentHash {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function New-HttpClient {
    param([string]$ApiKey)
    $handler = [Net.Http.HttpClientHandler]::new()
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($RequestTimeoutSeconds)
    if ($ApiKey) {
        $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $ApiKey)
    }
    return $client
}

function Invoke-Batch {
    param(
        [Net.Http.HttpClient]$Client,
        [uri]$Endpoint,
        [string]$Body,
        [int]$Width
    )

    $requests = [Collections.Generic.List[Net.Http.HttpRequestMessage]]::new()
    $tasks = [Collections.Generic.List[Threading.Tasks.Task[Net.Http.HttpResponseMessage]]]::new()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        for ($i = 0; $i -lt $Width; $i++) {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $Endpoint)
            $request.Content = [Net.Http.StringContent]::new($Body, [Text.Encoding]::UTF8, 'application/json')
            $requests.Add($request)
            $tasks.Add($Client.SendAsync($request))
        }
        [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks.ToArray())
        $clock.Stop()

        $responses = @()
        foreach ($task in $tasks) {
            $response = $task.GetAwaiter().GetResult()
            try {
                $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if (-not $response.IsSuccessStatusCode) {
                    throw "HTTP $([int]$response.StatusCode): $text"
                }
                $parsed = $text | ConvertFrom-Json
                $choice = @($parsed.choices)[0]
                $content = if ($choice.message) { [string]$choice.message.content } else { [string]$choice.text }
                $responses += [pscustomobject]@{
                    PromptTokens = [int](Get-PropertyValue $parsed.usage 'prompt_tokens' 0)
                    CompletionTokens = [int](Get-PropertyValue $parsed.usage 'completion_tokens' 0)
                    FinishReason = [string](Get-PropertyValue $choice 'finish_reason' '')
                    ContentHash = Get-ContentHash $content
                }
            } finally {
                $response.Dispose()
            }
        }
        $promptTokens = ($responses | Measure-Object PromptTokens -Sum).Sum
        $completionTokens = ($responses | Measure-Object CompletionTokens -Sum).Sum
        return [pscustomobject]@{
            Concurrency = $Width
            WallSeconds = [math]::Round($clock.Elapsed.TotalSeconds, 4)
            Requests = $responses.Count
            PromptTokens = [int]$promptTokens
            CompletionTokens = [int]$completionTokens
            OutputTokensPerSecond = if ($clock.Elapsed.TotalSeconds -gt 0) {
                [math]::Round($completionTokens / $clock.Elapsed.TotalSeconds, 4)
            } else { 0 }
            RequestSeconds = if ($responses.Count -gt 0) {
                [math]::Round($clock.Elapsed.TotalSeconds / $responses.Count, 4)
            } else { $null }
            ContentHashes = @($responses.ContentHash)
            FinishReasons = @($responses.FinishReason)
        }
    } finally {
        if ($clock.IsRunning) { $clock.Stop() }
        foreach ($request in $requests) { $request.Dispose() }
    }
}

$allRuns = [Collections.Generic.List[object]]::new()
foreach ($engine in $engines) {
    $name = [string](Get-PropertyValue $engine 'name' '')
    $endpointText = [string](Get-PropertyValue $engine 'endpoint' '')
    $model = [string](Get-PropertyValue $engine 'model' '')
    if (-not $name -or -not $endpointText -or -not $model) {
        throw 'Every engine needs name, endpoint, and model fields.'
    }

    $endpoint = $null
    if (-not [uri]::TryCreate($endpointText, [UriKind]::Absolute, [ref]$endpoint) -or
        $endpoint.Scheme -notin @('http', 'https')) {
        throw "Invalid HTTP(S) endpoint for '$name': $endpointText"
    }
    $isLoopback = $endpoint.IsLoopback -or $endpoint.Host -in @('localhost', '127.0.0.1', '::1')
    $allowInsecure = [bool](Get-PropertyValue $engine 'allowInsecureHttp' $false)
    if ($endpoint.Scheme -eq 'http' -and -not $isLoopback -and -not $allowInsecure) {
        throw "Engine '$name' uses non-loopback HTTP. Set allowInsecureHttp=true only on a trusted private link."
    }

    $apiKey = $null
    $apiKeyEnvironment = [string](Get-PropertyValue $engine 'apiKeyEnvironment' '')
    if ($apiKeyEnvironment) {
        $apiKey = [Environment]::GetEnvironmentVariable($apiKeyEnvironment)
        if (-not $apiKey) { throw "Environment variable '$apiKeyEnvironment' is empty for engine '$name'." }
    }

    $extraBody = Get-PropertyValue $engine 'extraBody' $null
    $body = [ordered]@{
        model = $model
        messages = @([ordered]@{ role = 'user'; content = $Prompt })
        max_tokens = $MaxTokens
        temperature = 0
        stream = $false
    }
    if ($extraBody) {
        foreach ($property in $extraBody.PSObject.Properties) { $body[$property.Name] = $property.Value }
    }
    $jsonBody = $body | ConvertTo-Json -Depth 10 -Compress

    $client = New-HttpClient -ApiKey $apiKey
    try {
        for ($i = 0; $i -lt $Warmup; $i++) {
            [void](Invoke-Batch -Client $client -Endpoint $endpoint -Body $jsonBody -Width 1)
        }
        foreach ($width in ($Concurrency | Sort-Object -Unique)) {
            for ($run = 1; $run -le $Repetitions; $run++) {
                $result = Invoke-Batch -Client $client -Endpoint $endpoint -Body $jsonBody -Width $width
                $allRuns.Add([pscustomobject]@{
                    Engine = $name
                    Endpoint = $endpoint.AbsoluteUri
                    Model = $model
                    Concurrency = $width
                    Repetition = $run
                    WallSeconds = $result.WallSeconds
                    Requests = $result.Requests
                    PromptTokens = $result.PromptTokens
                    CompletionTokens = $result.CompletionTokens
                    OutputTokensPerSecond = $result.OutputTokensPerSecond
                    RequestSeconds = $result.RequestSeconds
                    ContentHashes = $result.ContentHashes
                    FinishReasons = $result.FinishReasons
                })
            }
        }
    } finally {
        $client.Dispose()
    }
}

$summary = @($allRuns | Group-Object Engine, Concurrency | ForEach-Object {
    $first = $_.Group[0]
    $hashes = @($_.Group | ForEach-Object { $_.ContentHashes } | Sort-Object -Unique)
    $finishReasons = @($_.Group | ForEach-Object { $_.FinishReasons } | Sort-Object -Unique)
    [pscustomobject]@{
        Engine = $first.Engine
        Model = $first.Model
        Concurrency = $first.Concurrency
        AverageOutputTokensPerSecond = [math]::Round(($_.Group | Measure-Object OutputTokensPerSecond -Average).Average, 4)
        BestOutputTokensPerSecond = [math]::Round(($_.Group | Measure-Object OutputTokensPerSecond -Maximum).Maximum, 4)
        AverageBatchWallSeconds = [math]::Round(($_.Group | Measure-Object WallSeconds -Average).Average, 4)
        AverageRequestSeconds = [math]::Round(($_.Group | Measure-Object RequestSeconds -Average).Average, 4)
        DistinctOutputHashes = $hashes.Count
        FinishReasons = $finishReasons -join ','
    }
} | Sort-Object Concurrency, @{ Expression = 'AverageOutputTokensPerSecond'; Descending = $true })

$report = [ordered]@{
    SchemaVersion = 1
    Timestamp = (Get-Date).ToString('o')
    PromptSha256 = Get-ContentHash $Prompt
    MaxTokens = $MaxTokens
    Warmup = $Warmup
    Repetitions = $Repetitions
    Summary = $summary
    Runs = @($allRuns)
}

if ($OutputDirectory) {
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $OutputDirectory "engine-comparison-$stamp.json"
    $csvPath = Join-Path $OutputDirectory "engine-comparison-$stamp.csv"
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    $summary | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
}

$report | ConvertTo-Json -Depth 10
