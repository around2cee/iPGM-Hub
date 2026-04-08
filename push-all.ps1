# push-all.ps1
# Copies all iPGM repos from around2cee (personal GitHub) to csantos (work GitHub).
# Uses REST API only - no git required.
#
# Run this from inside the iPGM-Hub folder on Citrix:
#   $env:GH_PAT_WORK     = "ghp_yourWorkToken"
#   $env:GH_PAT_PERSONAL = "ghp_yourPersonalToken"
#   .\push-all.ps1

$WORK_PAT      = $env:GH_PAT_WORK
$PERSONAL_PAT  = $env:GH_PAT_PERSONAL
$SOURCE_OWNER  = "around2cee"
$DEST_OWNER    = "csantos"
$API           = "https://api.github.com"

# ---------------------------------------------------------------------------
# Fix SSL/TLS for corporate proxy environments (Citrix)
# Forces TLS 1.2 and trusts the corporate certificate chain
# ---------------------------------------------------------------------------

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# If your company uses SSL inspection, uncomment the line below:
# [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

$REPOS = @(
    "iPGM-Hub",
    "iPGM-Program-Alpha",
    "iPGM-Program-Beta",
    "iPGM-project-template"
)

if (-not $WORK_PAT -or -not $PERSONAL_PAT) {
    Write-Host ""
    Write-Host "ERROR: Both tokens must be set before running."
    Write-Host ""
    Write-Host '  $env:GH_PAT_WORK     = "ghp_your_csantos_work_token"'
    Write-Host '  $env:GH_PAT_PERSONAL = "ghp_your_around2cee_personal_token"'
    Write-Host ""
    exit 1
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Invoke-GH($token, $path, $method = "GET", $body = $null) {
    $headers = @{
        Authorization = "Bearer $token"
        Accept        = "application/vnd.github+json"
        "User-Agent"  = "ipgm-push-all/2.0"
    }
    $params = @{ Uri = "$API$path"; Method = $method; Headers = $headers }
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

# Get all file paths in a repo recursively via the git trees API
function Get-RepoFiles($token, $owner, $repo) {
    # Get default branch SHA
    $repoInfo = Invoke-GH $token "/repos/$owner/$repo"
    if (-not $repoInfo) {
        Write-Warning "  Cannot access $owner/$repo - skipping"
        return @()
    }
    $branch = $repoInfo.default_branch

    $ref = Invoke-GH $token "/repos/$owner/$repo/git/ref/heads/$branch"
    if (-not $ref) { return @() }
    $sha = $ref.object.sha

    # Get full tree recursively
    $tree = Invoke-GH $token "/repos/$owner/$repo/git/trees/$sha`?recursive=1"
    if (-not $tree) { return @() }

    # Return only blob (file) entries
    return $tree.tree | Where-Object { $_.type -eq "blob" }
}

# Get file content from source repo (returns base64 encoded content)
function Get-FileContent($token, $owner, $repo, $path) {
    $res = Invoke-GH $token "/repos/$owner/$repo/contents/$path"
    if (-not $res) { return $null }
    return $res.content -replace "`n", ""   # strip newlines from base64
}

# Upload a file to dest repo (creates or updates)
function Push-File($token, $owner, $repo, $path, $base64Content) {
    # Check if file exists to get SHA for update
    $existing = Invoke-GH $token "/repos/$owner/$repo/contents/$path"
    $sha      = if ($existing) { $existing.sha } else { $null }

    $body = @{
        message = "iPGM Hub and Spoke v2 - deploy"
        content = $base64Content
    }
    if ($sha) { $body.sha = $sha }

    $res = Invoke-GH $token "/repos/$owner/$repo/contents/$path" "PUT" $body
    if (-not $res) {
        Write-Warning "    Failed: $path"
    }
}

# Ensure destination repo exists
function Ensure-Repo($token, $owner, $repoName) {
    $existing = Invoke-GH $token "/repos/$owner/$repoName"
    if ($existing) {
        Write-Host "  Repo exists: $repoName"
        return
    }

    # Detect personal vs org
    $user  = Invoke-GH $token "/users/$owner"
    $isOrg = $user.type -eq "Organization"
    $url   = if ($isOrg) { "/orgs/$owner/repos" } else { "/user/repos" }

    $res = Invoke-GH $token $url "POST" @{
        name    = $repoName
        private = $true
        auto_init = $false
    }
    if ($res) { Write-Host "  Created repo: $repoName" }
    else      { Write-Warning "  Could not create repo: $repoName" }
}

# ---------------------------------------------------------------------------
# Main - copy each repo from around2cee to csantos
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "iPGM Hub and Spoke - Repo Copy"
Write-Host "From : $SOURCE_OWNER (personal)"
Write-Host "To   : $DEST_OWNER (work)"
Write-Host ""

foreach ($repo in $REPOS) {
    Write-Host "=== $repo ==="

    # Get all files from source
    Write-Host "  Reading files from $SOURCE_OWNER/$repo ..."
    $files = Get-RepoFiles $PERSONAL_PAT $SOURCE_OWNER $repo

    if ($files.Count -eq 0) {
        Write-Warning "  No files found in $SOURCE_OWNER/$repo - skipping"
        Write-Host ""
        continue
    }

    Write-Host "  Found $($files.Count) files"

    # Ensure dest repo exists
    Ensure-Repo $WORK_PAT $DEST_OWNER $repo

    # Copy each file
    $current = 0
    foreach ($file in $files) {
        $current++
        Write-Host "  [$current/$($files.Count)] $($file.path)"

        $content = Get-FileContent $PERSONAL_PAT $SOURCE_OWNER $repo $file.path
        if (-not $content) {
            Write-Warning "    Could not read: $($file.path)"
            continue
        }

        Push-File $WORK_PAT $DEST_OWNER $repo $file.path $content
    }

    Write-Host "  Done: github.com/$DEST_OWNER/$repo"
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
