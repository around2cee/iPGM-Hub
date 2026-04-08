# push-all.ps1
# Copies all iPGM repos from around2cee (github.com) to csantos (Bloomberg GHE).
# Uses REST API only - no git required.
#
# Run this from inside the iPGM-Hub folder on Citrix:
#   $env:GH_PAT_WORK     = "ghp_yourBloombergWorkToken"
#   $env:GH_PAT_PERSONAL = "ghp_yourPersonalToken"
#   .\push-all.ps1

$WORK_PAT     = $env:GH_PAT_WORK
$PERSONAL_PAT = $env:GH_PAT_PERSONAL
$SOURCE_OWNER = "around2cee"
$DEST_OWNER   = "csantos"

# Personal GitHub (github.com)
$PERSONAL_API = "https://api.github.com"

# Bloomberg GitHub Enterprise Server
$WORK_API     = "https://bbgithub.dev.bloomberg.com/api/v3"

$REPOS = @(
    "iPGM-Hub",
    "iPGM-Program-Alpha",
    "iPGM-Program-Beta",
    "iPGM-project-template"
)

# Fix SSL/TLS for corporate proxy environments
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# If still failing uncomment:
# [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

if (-not $WORK_PAT -or -not $PERSONAL_PAT) {
    Write-Host ""
    Write-Host "ERROR: Both tokens must be set before running."
    Write-Host ""
    Write-Host '  $env:GH_PAT_WORK     = "ghp_your_bloomberg_work_token"'
    Write-Host '  $env:GH_PAT_PERSONAL = "ghp_your_around2cee_personal_token"'
    Write-Host ""
    exit 1
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Invoke-GHApi($baseUrl, $token, $path, $method = "GET", $body = $null) {
    $headers = @{
        Authorization = "Bearer $token"
        Accept        = "application/vnd.github+json"
        "User-Agent"  = "ipgm-push-all/2.0"
    }
    $params = @{ Uri = "$baseUrl$path"; Method = $method; Headers = $headers }
    if ($body) {
        $params.Body        = ($body | ConvertTo-Json -Depth 20)
        $params.ContentType = "application/json"
    }
    try {
        return Invoke-RestMethod @params
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 404) { return $null }
        if ($code -eq 422) { return $null }
        Write-Warning "  API call failed ($method $path): $($_.Exception.Message)"
        return $null
    }
}

function Read-PersonalGH($path) {
    return Invoke-GHApi $PERSONAL_API $PERSONAL_PAT $path
}

function Write-WorkGH($path, $method = "GET", $body = $null) {
    return Invoke-GHApi $WORK_API $WORK_PAT $path $method $body
}

# Get all file paths in a repo recursively
function Get-RepoFiles($owner, $repo) {
    $repoInfo = Read-PersonalGH "/repos/$owner/$repo"
    if (-not $repoInfo) {
        Write-Warning "  Cannot access $owner/$repo - skipping"
        return @()
    }
    $branch = $repoInfo.default_branch
    $ref    = Read-PersonalGH "/repos/$owner/$repo/git/ref/heads/$branch"
    if (-not $ref) { return @() }

    $tree = Read-PersonalGH "/repos/$owner/$repo/git/trees/$($ref.object.sha)?recursive=1"
    if (-not $tree) { return @() }

    return $tree.tree | Where-Object { $_.type -eq "blob" }
}

# Get file content from source repo (returns base64)
function Get-FileContent($owner, $repo, $path) {
    $res = Read-PersonalGH "/repos/$owner/$repo/contents/$path"
    if (-not $res) { return $null }
    return $res.content -replace "`n", ""
}

# Create repo on Bloomberg GHE if it does not exist
function Initialize-WorkRepo($repoName) {
    $existing = Write-WorkGH "/repos/$DEST_OWNER/$repoName"
    if ($existing) {
        Write-Host "  Repo exists: $repoName"
        return
    }

    # Detect personal vs org on work GHE
    $user  = Write-WorkGH "/users/$DEST_OWNER"
    $isOrg = $user -and $user.type -eq "Organization"
    $url   = if ($isOrg) { "/orgs/$DEST_OWNER/repos" } else { "/user/repos" }

    $res = Write-WorkGH $url "POST" @{
        name      = $repoName
        private   = $true
        auto_init = $false
    }
    if ($res) { Write-Host "  Created repo: $repoName" }
    else      { Write-Warning "  Could not create repo: $repoName (may already exist)" }
}

# Upload a single file to Bloomberg GHE
function Send-File($repoName, $path, $base64Content) {
    $existing = Write-WorkGH "/repos/$DEST_OWNER/$repoName/contents/$path"
    $sha      = if ($existing) { $existing.sha } else { $null }

    $body = @{
        message = "iPGM Hub and Spoke v2 - deploy"
        content = $base64Content
    }
    if ($sha) { $body.sha = $sha }

    $res = Write-WorkGH "/repos/$DEST_OWNER/$repoName/contents/$path" "PUT" $body
    if (-not $res) { Write-Warning "    Failed: $path" }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "iPGM Hub and Spoke - Repo Copy"
Write-Host "From : $SOURCE_OWNER (github.com)"
Write-Host "To   : $DEST_OWNER (bbgithub.dev.bloomberg.com)"
Write-Host ""

foreach ($repo in $REPOS) {
    Write-Host "=== $repo ==="

    Write-Host "  Reading files from $SOURCE_OWNER/$repo ..."
    $files = Get-RepoFiles $SOURCE_OWNER $repo

    if ($files.Count -eq 0) {
        Write-Warning "  No files found in $SOURCE_OWNER/$repo - skipping"
        Write-Host ""
        continue
    }

    Write-Host "  Found $($files.Count) files"

    Initialize-WorkRepo $repo

    $current = 0
    foreach ($file in $files) {
        $current++
        Write-Host "  [$current/$($files.Count)] $($file.path)"

        $content = Get-FileContent $SOURCE_OWNER $repo $file.path
        if (-not $content) {
            Write-Warning "    Could not read: $($file.path)"
            continue
        }

        Send-File $repo $file.path $content
    }

    Write-Host "  Done: bbgithub.dev.bloomberg.com/$DEST_OWNER/$repo"
    Write-Host ""
}

Write-Host "=============================================="
Write-Host " Copy Complete"
Write-Host "=============================================="
Write-Host ""
Write-Host "Now run the portfolio sync:"
Write-Host "  .\run-sync.ps1 -Setup   (first time only)"
Write-Host "  .\run-sync.ps1"
Write-Host ""
