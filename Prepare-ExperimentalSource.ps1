[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Workspace = (Join-Path $PSScriptRoot 'experiment-source'),
    [switch]$ForceRefresh
)

$ErrorActionPreference = 'Stop'

$DFlashRepo = 'https://github.com/z-lab/llama.cpp-fork.git'
$DFlashCommit = '7ea40ee98acb416787863aee935dbb99491acad5'
$RocmFpxRepo = 'https://github.com/charlie12345/ROCmFPX.git'
$RocmFpxCommit = 'c49ebdbd5c9f01ec242369f9e7f7967855f80cba'

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    & $Command @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE"
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git was not found in PATH.'
}

$workspaceFull = [IO.Path]::GetFullPath($Workspace)
if ($ForceRefresh -and (Test-Path -LiteralPath $workspaceFull)) {
    if ($PSCmdlet.ShouldProcess($workspaceFull, 'Delete generated experimental workspace')) {
        Remove-Item -LiteralPath $workspaceFull -Recurse -Force
    }
}
New-Item -ItemType Directory -Force -Path $workspaceFull | Out-Null

function Initialize-PinnedClone {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Commit
    )

    $path = Join-Path $workspaceFull $Name
    $newClone = $false

    if (-not (Test-Path -LiteralPath $path)) {
        Invoke-Checked -Command 'git' -ArgumentList @(
            'clone',
            '--filter=blob:none',
            '--no-checkout',
            $Repository,
            $path
        )
        $newClone = $true
    }

    if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) {
        throw "$path exists but is not a Git repository."
    }

    # A --no-checkout clone has an intentionally empty worktree. In that state,
    # git status reports every indexed file as deleted, which is not a user edit.
    # This also recovers cleanly from a previous run that stopped immediately
    # after cloning and before the pinned checkout was materialized.
    $worktreeItems = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop |
        Where-Object { $_.Name -ne '.git' })
    $emptyWorktree = $worktreeItems.Count -eq 0

    if (-not $newClone -and -not $emptyWorktree) {
        $dirty = @(& git -C $path status --porcelain --untracked-files=no)
        if ($LASTEXITCODE -ne 0) {
            throw "git status failed for $path"
        }
        if ($dirty) {
            throw "$path has tracked local changes. Use a clean workspace or -ForceRefresh."
        }
    }

    Invoke-Checked -Command 'git' -ArgumentList @(
        '-C', $path,
        'fetch', 'origin', $Commit,
        '--depth', '1'
    )

    $checkoutArgs = @('-C', $path, 'checkout', '--detach')
    if ($newClone -or $emptyWorktree) {
        $checkoutArgs += '--force'
    }
    $checkoutArgs += $Commit
    Invoke-Checked -Command 'git' -ArgumentList $checkoutArgs

    $actual = (& git -C $path rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "git rev-parse failed for $path"
    }
    if ($actual -ne $Commit) {
        throw "Pin verification failed for ${Name}: $actual"
    }

    $remainingChanges = @(& git -C $path status --porcelain --untracked-files=no)
    if ($LASTEXITCODE -ne 0) {
        throw "post-checkout git status failed for $path"
    }
    if ($remainingChanges) {
        throw "$path is not clean after checking out the pinned commit."
    }

    return $path
}

$dflashPath = Initialize-PinnedClone -Name 'dflash-base' -Repository $DFlashRepo -Commit $DFlashCommit
$donorPath = Initialize-PinnedClone -Name 'rocmfpx-donor' -Repository $RocmFpxRepo -Commit $RocmFpxCommit
$hybridPath = Join-Path $workspaceFull 'hybrid'

# Do not clone from dflash-base here. It is intentionally a partial/promisor
# clone, and cloning from a local partial clone can fail when upload-pack needs
# objects that were promised by its upstream remote. Build the independent
# hybrid directly from the canonical DFlash remote instead.
if (Test-Path -LiteralPath $hybridPath) {
    $hybridGit = Join-Path $hybridPath '.git'
    if (-not (Test-Path -LiteralPath $hybridGit)) {
        # A failed clone can leave a generated, non-repository directory behind.
        Remove-Item -LiteralPath $hybridPath -Recurse -Force
    }
}

if (-not (Test-Path -LiteralPath $hybridPath)) {
    Invoke-Checked -Command 'git' -ArgumentList @(
        'clone', '--filter=blob:none', '--no-checkout', $DFlashRepo, $hybridPath
    )
    Invoke-Checked -Command 'git' -ArgumentList @(
        '-C', $hybridPath, 'fetch', 'origin', $DFlashCommit, '--depth', '1'
    )
    Invoke-Checked -Command 'git' -ArgumentList @(
        '-C', $hybridPath, 'checkout', '--detach', '--force', $DFlashCommit
    )
    Invoke-Checked -Command 'git' -ArgumentList @(
        '-C', $hybridPath, 'remote', 'rename', 'origin', 'dflash-upstream'
    )
    Invoke-Checked -Command 'git' -ArgumentList @(
        '-C', $hybridPath, 'remote', 'add', 'rocmfpx-donor', $RocmFpxRepo
    )
    Invoke-Checked -Command 'git' -ArgumentList @(
        '-C', $hybridPath, 'checkout', '-B', 'win-rocmfpx-experiment', $DFlashCommit
    )
} else {
    $hybridDirty = @(& git -C $hybridPath status --porcelain --untracked-files=no)
    if ($LASTEXITCODE -ne 0) {
        throw "git status failed for $hybridPath"
    }
    if ($hybridDirty) {
        throw "$hybridPath has tracked local changes. Refusing to overwrite them."
    }

    $hybridActual = (& git -C $hybridPath rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "git rev-parse failed for $hybridPath"
    }
    if ($hybridActual -ne $DFlashCommit) {
        throw "Hybrid source is at $hybridActual instead of the expected base $DFlashCommit. Use -ForceRefresh only if you want to discard it."
    }
}

$manifest = [ordered]@{
    CreatedAt = (Get-Date).ToString('o')
    Workspace = $workspaceFull
    DFlash = [ordered]@{
        Repository = $DFlashRepo
        Commit = $DFlashCommit
        Path = $dflashPath
    }
    RocmFPX = [ordered]@{
        Repository = $RocmFpxRepo
        Commit = $RocmFpxCommit
        Path = $donorPath
    }
    Hybrid = [ordered]@{
        Path = $hybridPath
        BaseCommit = $DFlashCommit
        Branch = 'win-rocmfpx-experiment'
    }
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $workspaceFull 'SOURCE-PINS.json') -Encoding UTF8

$checklist = @'
PORTING ORDER - keep these as separate commits

1. Baseline Windows Vulkan build at the DFlash pin. No donor code yet.
2. Port ROCmFP4/ROCmFPX tensor-type + CPU reference/metadata plumbing only.
3. Build and run CPU/reference parsing tests.
4. Port Vulkan shader generation, shader sources, and Vulkan dispatch for the new types.
5. Run Vulkan backend tests on Radeon 8060S before touching DFlash loader code.
6. Preserve the DFlash2 model loader from dflash-base. Resolve only compile/API conflicts.
7. Load the public Q8 draft and verify the 58-tensor contract; reject an 81-tensor expectation.
8. Run deterministic target-only vs target+draft correctness tests.
9. Benchmark against the stable 17.2 tok/s setup using identical prompts/settings.

Do not wholesale-copy src/models/dflash.cpp from ROCmFPX donor.
Do not promote this tree to production until correctness passes.
'@
$checklist | Set-Content -LiteralPath (Join-Path $workspaceFull 'PORTING-NEXT.txt') -Encoding UTF8

Write-Host "Experimental sources prepared under $workspaceFull"
Write-Host "Hybrid working tree: $hybridPath"
Write-Host 'Next: build the untouched baseline first, then port tensor-format core as one isolated commit.'
