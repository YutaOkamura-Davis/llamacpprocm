[CmdletBinding()]
param(
    [string]$Repository = 'z-lab/llama.cpp-fork',
    [string]$CandidateBranch = 'dflash2',
    [string]$QualifiedCommit = '7ea40ee98acb416787863aee935dbb99491acad5'
)

$ErrorActionPreference = 'Stop'

$headers = @{
    'User-Agent' = 'llamacpprocm-upstream-check'
    'Accept' = 'application/vnd.github+json'
}

$compareUrl = "https://api.github.com/repos/$Repository/compare/$QualifiedCommit...$CandidateBranch"
try {
    $result = Invoke-RestMethod -Uri $compareUrl -Headers $headers
} catch {
    throw "Could not query upstream comparison: $($_.Exception.Message)"
}

$summary = [ordered]@{
    Repository = $Repository
    CandidateBranch = $CandidateBranch
    QualifiedCommit = $QualifiedCommit
    CandidateCommit = $result.head_commit.sha
    Status = $result.status
    AheadBy = [int]$result.ahead_by
    BehindBy = [int]$result.behind_by
    TotalCommits = [int]$result.total_commits
    CheckedAt = (Get-Date).ToString('o')
    CompareUrl = "https://github.com/$Repository/compare/$QualifiedCommit...$CandidateBranch"
}

$summary | ConvertTo-Json

if ($result.ahead_by -gt 0) {
    Write-Warning "Upstream $CandidateBranch is $($result.ahead_by) commit(s) ahead of the qualified pin. Review and benchmark before changing Build-Node.ps1."
}
if ($result.behind_by -gt 0) {
    Write-Warning "The candidate branch is behind the qualified pin; verify the branch name and upstream history."
}
