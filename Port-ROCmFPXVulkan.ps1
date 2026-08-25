[CmdletBinding()]
param(
    [string]$HybridPath = (Join-Path $PSScriptRoot 'experiment-source\hybrid'),
    [ValidateSet('Core', 'Vulkan', 'All')]
    [string]$Stage = 'All',
    [string]$DFlashCommit = '7ea40ee98acb416787863aee935dbb99491acad5',
    [string]$DonorCommit = 'c49ebdbd5c9f01ec242369f9e7f7967855f80cba',
    [string]$OfficialBaseCommit = '22cadc1944f4658214aee03abd08240358840a95',
    [string]$GitUserName = 'Yuta Okamura',
    [string]$GitUserEmail = '120001990+YutaOkamura-Davis@users.noreply.github.com'
)

$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [switch]$Capture
    )

    if ($Capture) {
        $output = @(& git -C $HybridPath @ArgumentList)
        if ($LASTEXITCODE -ne 0) {
            throw "git $($ArgumentList -join ' ') failed with exit code $LASTEXITCODE"
        }
        return $output
    }

    & git -C $HybridPath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "git $($ArgumentList -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Get-RemoteNames {
    return @(Invoke-Git -ArgumentList @('remote') -Capture)
}

function Add-UniquePath {
    param(
        [Parameter(Mandatory)][Collections.Generic.HashSet[string]]$Set,
        [string]$Path
    )

    if ($Path) {
        [void]$Set.Add(($Path -replace '\\', '/'))
    }
}

function Get-DonorEntry {
    param([Parameter(Mandatory)][string]$Path)

    $lines = @(Invoke-Git -ArgumentList @('ls-tree', $DonorCommit, '--', $Path) -Capture)
    if (-not $lines) {
        return $null
    }
    if ($lines.Count -ne 1 -or $lines[0] -notmatch '^([0-9]{6})\s+\w+\s+([0-9a-f]{40})\t(.+)$') {
        throw "Unexpected ls-tree result for ${Path}: $($lines -join '; ')"
    }
    return [pscustomobject]@{
        Mode = $matches[1]
        Sha = $matches[2]
        Path = $matches[3]
    }
}

function New-SyntheticPortCommit {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][string]$StateDirectory
    )

    if (-not $Paths) {
        throw "No paths selected for $Name stage."
    }

    $indexPath = Join-Path $StateDirectory ("index-{0}" -f $Name.ToLowerInvariant())
    if (Test-Path -LiteralPath $indexPath) {
        Remove-Item -LiteralPath $indexPath -Force
    }

    $oldIndex = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = $indexPath
        Invoke-Git -ArgumentList @('read-tree', $OfficialBaseCommit)

        foreach ($path in $Paths) {
            $entry = Get-DonorEntry -Path $path
            if ($entry) {
                $cacheInfo = "$($entry.Mode),$($entry.Sha),$($entry.Path)"
                Invoke-Git -ArgumentList @('update-index', '--add', '--cacheinfo', $cacheInfo)
            } else {
                Invoke-Git -ArgumentList @('update-index', '--remove', '--', $path)
            }
        }

        $tree = (Invoke-Git -ArgumentList @('write-tree') -Capture)[0].Trim()
        $message = "Synthetic ROCmFPX $Name port from $DonorCommit"
        $commit = (Invoke-Git -ArgumentList @('commit-tree', $tree, '-p', $OfficialBaseCommit, '-m', $message) -Capture)[0].Trim()
        return $commit
    } finally {
        if ($null -eq $oldIndex) {
            Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
        } else {
            $env:GIT_INDEX_FILE = $oldIndex
        }
    }
}

function Apply-SyntheticCommit {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Commit
    )

    & git -C $HybridPath cherry-pick $Commit
    if ($LASTEXITCODE -ne 0) {
        $conflicts = @(& git -C $HybridPath diff --name-only --diff-filter=U)
        $conflictText = if ($conflicts) { $conflicts -join "`n  " } else { '(Git did not report an unmerged path)' }
        throw "$Name port stopped on a real three-way conflict.`nConflicts:`n  $conflictText`nDo not guess. Paste this output for review, or abort with: git -C `"$HybridPath`" cherry-pick --abort"
    }
}

$HybridPath = [IO.Path]::GetFullPath($HybridPath)
if (-not (Test-Path -LiteralPath (Join-Path $HybridPath '.git'))) {
    throw "Hybrid Git tree not found: $HybridPath. Run Prepare-ExperimentalSource.ps1 first."
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git was not found in PATH.'
}

$inProgress = @('CHERRY_PICK_HEAD', 'MERGE_HEAD', 'REVERT_HEAD') | Where-Object {
    Test-Path -LiteralPath (Join-Path $HybridPath ".git\$_")
}
if ($inProgress) {
    throw "Hybrid repository already has an in-progress Git operation: $($inProgress -join ', '). Finish or abort it first."
}

$dirty = @(& git -C $HybridPath status --porcelain --untracked-files=no)
if ($LASTEXITCODE -ne 0) {
    throw 'git status failed in hybrid tree.'
}
if ($dirty) {
    throw "Hybrid tree has tracked local changes. Commit/reset them before porting:`n$($dirty -join "`n")"
}

Invoke-Git -ArgumentList @('config', 'user.name', $GitUserName)
Invoke-Git -ArgumentList @('config', 'user.email', $GitUserEmail)

$remotes = Get-RemoteNames
if ('rocmfpx-donor' -notin $remotes) {
    Invoke-Git -ArgumentList @('remote', 'add', 'rocmfpx-donor', 'https://github.com/charlie12345/ROCmFPX.git')
}
if ('llama-official' -notin $remotes) {
    Invoke-Git -ArgumentList @('remote', 'add', 'llama-official', 'https://github.com/ggml-org/llama.cpp.git')
}

Write-Host 'Fetching pinned donor and documented upstream integration baseline...'
Invoke-Git -ArgumentList @('fetch', 'rocmfpx-donor', $DonorCommit, '--depth', '1')
Invoke-Git -ArgumentList @('fetch', 'llama-official', $OfficialBaseCommit, '--depth', '1')

foreach ($commit in @($DFlashCommit, $DonorCommit, $OfficialBaseCommit)) {
    Invoke-Git -ArgumentList @('cat-file', '-e', "$commit^{commit}")
}

$loaderBefore = (Invoke-Git -ArgumentList @('rev-parse', 'HEAD:src/models/dflash.cpp') -Capture)[0].Trim()
$specBefore = (Invoke-Git -ArgumentList @('rev-parse', 'HEAD:common/speculative.cpp') -Capture)[0].Trim()

# Discover the donor surface dynamically. We select files by actual ROCmFP4/FPX
# symbols/names, then split the result into backend-neutral core and Vulkan.
$allPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$grepOutput = @(& git -C $HybridPath grep -I -l -i -E 'rocmfp4|rocmfpx' $DonorCommit --)
$grepExit = $LASTEXITCODE
if ($grepExit -notin @(0, 1)) {
    throw "git grep failed with exit code $grepExit"
}
foreach ($line in $grepOutput) {
    $path = $line
    if ($path -match '^[0-9a-f]{7,40}:(.+)$') {
        $path = $matches[1]
    }
    Add-UniquePath -Set $allPaths -Path $path
}

$namedPaths = @(Invoke-Git -ArgumentList @('ls-tree', '-r', '--name-only', $DonorCommit, '--', 'ggml') -Capture |
    Where-Object { $_ -match '(?i)rocmfp4|rocmfpx' })
foreach ($path in $namedPaths) {
    Add-UniquePath -Set $allPaths -Path $path
}

$corePaths = @($allPaths | Where-Object {
    $p = $_
    if ($p -eq 'src/models/dflash.cpp' -or $p -eq 'common/speculative.cpp') { return $false }
    if ($p -like 'ggml/src/ggml-vulkan/*') { return $false }
    if ($p -like 'ggml/src/ggml-cuda/*' -or $p -like 'ggml/src/ggml-hip/*') { return $false }
    if ($p -like 'docs/*' -or $p -like 'scripts/*' -or $p -like 'tests/*') { return $false }

    return ($p -like 'ggml/*') -or
        ($p -eq 'gguf-py/gguf/constants.py') -or
        ($p -eq 'src/llama-model-loader.cpp')
} | Sort-Object)

$vulkanPaths = @($allPaths | Where-Object {
    $_ -like 'ggml/src/ggml-vulkan/*'
} | Sort-Object)

if (-not $corePaths) {
    throw 'No ROCmFPX core paths were discovered. Refusing an empty port.'
}
if (-not $vulkanPaths) {
    throw 'No ROCmFPX Vulkan paths were discovered. Refusing an incomplete Vulkan port.'
}

$stateDirectory = Join-Path (Split-Path -Parent $HybridPath) 'port-state'
New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
$corePaths | Set-Content -LiteralPath (Join-Path $stateDirectory 'core-paths.txt') -Encoding UTF8
$vulkanPaths | Set-Content -LiteralPath (Join-Path $stateDirectory 'vulkan-paths.txt') -Encoding UTF8

$headBefore = (Invoke-Git -ArgumentList @('rev-parse', 'HEAD') -Capture)[0].Trim()
$coreSynthetic = $null
$vulkanSynthetic = $null

$coreAlreadyPresent = $false
& git -C $HybridPath grep -q 'GGML_TYPE_Q4_0_ROCMFP4' HEAD -- ggml/include/ggml.h 2>$null
if ($LASTEXITCODE -eq 0) { $coreAlreadyPresent = $true }

if ($Stage -in @('Core', 'All')) {
    if ($coreAlreadyPresent) {
        Write-Host 'ROCmFPX core type marker is already present; skipping Core stage.'
    } else {
        Write-Host "Core port paths: $($corePaths.Count)"
        $coreSynthetic = New-SyntheticPortCommit -Name 'Core' -Paths $corePaths -StateDirectory $stateDirectory
        Apply-SyntheticCommit -Name 'Core' -Commit $coreSynthetic
        Write-Host "Core port committed: $((Invoke-Git -ArgumentList @('rev-parse', 'HEAD') -Capture)[0])"
    }
}

if ($Stage -in @('Vulkan', 'All')) {
    & git -C $HybridPath grep -q 'GGML_TYPE_Q4_0_ROCMFP4' HEAD -- ggml/include/ggml.h 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Vulkan stage requires ROCmFPX core types first. Run this script with -Stage Core.'
    }

    $vulkanAlreadyPresent = $false
    & git -C $HybridPath grep -q -i 'rocmfp4' HEAD -- ggml/src/ggml-vulkan 2>$null
    if ($LASTEXITCODE -eq 0) { $vulkanAlreadyPresent = $true }

    if ($vulkanAlreadyPresent) {
        Write-Host 'ROCmFPX Vulkan marker is already present; skipping Vulkan stage.'
    } else {
        Write-Host "Vulkan port paths: $($vulkanPaths.Count)"
        $vulkanSynthetic = New-SyntheticPortCommit -Name 'Vulkan' -Paths $vulkanPaths -StateDirectory $stateDirectory
        Apply-SyntheticCommit -Name 'Vulkan' -Commit $vulkanSynthetic
        Write-Host "Vulkan port committed: $((Invoke-Git -ArgumentList @('rev-parse', 'HEAD') -Capture)[0])"
    }
}

$loaderAfter = (Invoke-Git -ArgumentList @('rev-parse', 'HEAD:src/models/dflash.cpp') -Capture)[0].Trim()
$specAfter = (Invoke-Git -ArgumentList @('rev-parse', 'HEAD:common/speculative.cpp') -Capture)[0].Trim()
if ($loaderAfter -ne $loaderBefore) {
    throw 'Safety invariant failed: src/models/dflash.cpp changed during the ROCmFPX port.'
}
if ($specAfter -ne $specBefore) {
    throw 'Safety invariant failed: common/speculative.cpp changed during the ROCmFPX port.'
}

$headAfter = (Invoke-Git -ArgumentList @('rev-parse', 'HEAD') -Capture)[0].Trim()
$manifest = [ordered]@{
    PortedAt = (Get-Date).ToString('o')
    HybridPath = $HybridPath
    Stage = $Stage
    HeadBefore = $headBefore
    HeadAfter = $headAfter
    DFlashCommit = $DFlashCommit
    DonorCommit = $DonorCommit
    OfficialBaseCommit = $OfficialBaseCommit
    DFlashLoaderBlobPreserved = $loaderBefore -eq $loaderAfter
    SpeculativeHostBlobPreserved = $specBefore -eq $specAfter
    CorePathCount = $corePaths.Count
    VulkanPathCount = $vulkanPaths.Count
    CoreSyntheticCommit = $coreSynthetic
    VulkanSyntheticCommit = $vulkanSynthetic
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stateDirectory 'PORT-MANIFEST.json') -Encoding UTF8

Write-Host 'ROCmFPX Windows Vulkan source port applied.'
Write-Host "DFlash loader preserved: $($loaderBefore -eq $loaderAfter)"
Write-Host "DFlash speculative host preserved: $($specBefore -eq $specAfter)"
Write-Host "Hybrid HEAD: $headAfter"
Write-Host 'Next: build with Build-ExperimentalVulkan.ps1 and resolve compile/API mismatches without replacing the DFlash loader.'
