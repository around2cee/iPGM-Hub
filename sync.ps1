# sync.ps1
# iPGM Hub and Spoke portfolio sync - pure PowerShell, no Node.js required.
# Calls the GitHub GraphQL API directly using Invoke-RestMethod.
#
# Usage:
#   $env:ORG_PORTFOLIO_TOKEN = "ghp_..."
#   $env:ORG_NAME            = "csantos"
#   .\sync.ps1

$TOKEN         = $env:ORG_PORTFOLIO_TOKEN
$OWNER         = $env:ORG_NAME
$PROJECT_TITLE = "iPGM Program Portfolio"
$LABEL_NAME    = "portfolio-report"
$LABEL_COLOR   = "0075ca"
$LABEL_DESC    = "Surface this issue in the iPGM portfolio board"

# Fix SSL/TLS for corporate proxy environments (Citrix)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# If still failing, uncomment:
# [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

if (-not $TOKEN -or -not $OWNER) {
    Write-Error "ERROR: ORG_PORTFOLIO_TOKEN and ORG_NAME must be set."
    exit 1
}

$GQL_URL = "https://bbgithub.dev.bloomberg.com/api/graphql"
$HEADERS = @{
    Authorization = "Bearer $TOKEN"
    Accept        = "application/vnd.github+json"
    "User-Agent"  = "ipgm-hub-sync/2.0"
}

# ---------------------------------------------------------------------------
# GraphQL helper
# ---------------------------------------------------------------------------

function Invoke-GQL($query, $variables = @{}) {
    $body = @{ query = $query; variables = $variables } | ConvertTo-Json -Depth 20
    try {
        $res = Invoke-RestMethod -Uri $GQL_URL -Method POST `
            -Headers $HEADERS -Body $body -ContentType "application/json"
    } catch {
        Write-Error "GraphQL request failed: $_"
        exit 1
    }
    if ($res.errors) {
        Write-Error "GraphQL errors: $($res.errors | ConvertTo-Json -Depth 5)"
        exit 1
    }
    return $res.data
}

# ---------------------------------------------------------------------------
# REST helper
# ---------------------------------------------------------------------------

function Invoke-GH($path, $method = "GET", $body = $null) {
    $uri    = "https://bbgithub.dev.bloomberg.com/api/v3$path"
    $params = @{ Uri = $uri; Method = $method; Headers = $HEADERS }
    if ($body) {
        $params.Body        = ($body | ConvertTo-Json -Depth 10)
        $params.ContentType = "application/json"
    }
    try {
        return Invoke-RestMethod @params
    } catch {
        # 422 = already exists, not a real error
        if ($_.Exception.Response.StatusCode.value__ -eq 422) { return $null }
        Write-Warning "REST call failed ($method $path): $_"
        return $null
    }
}

# ---------------------------------------------------------------------------
# Detect personal account vs org
# ---------------------------------------------------------------------------

function Get-OwnerInfo($owner) {
    $data = Invoke-GQL @"
query GetOwner(`$owner: String!) {
  repositoryOwner(login: `$owner) {
    id
    __typename
  }
}
"@ @{ owner = $owner }

    if (-not $data.repositoryOwner) {
        Write-Error "Cannot find GitHub account: '$owner'. Check ORG_NAME."
        exit 1
    }
    return @{
        Id    = $data.repositoryOwner.id
        IsOrg = ($data.repositoryOwner.__typename -eq "Organization")
    }
}

# ---------------------------------------------------------------------------
# Get all repos for owner (paginated)
# ---------------------------------------------------------------------------

function Get-AllRepos($owner) {
    $repos  = @()
    $cursor = $null

    do {
        $vars = @{ owner = $owner; cursor = $cursor }
        $data = Invoke-GQL @"
query ListRepos(`$owner: String!, `$cursor: String) {
  repositoryOwner(login: `$owner) {
    repositories(first: 100, after: `$cursor, orderBy: { field: NAME, direction: ASC }) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id name description url isPrivate stargazerCount
        primaryLanguage { name }
      }
    }
  }
}
"@ $vars

        $page   = $data.repositoryOwner.repositories
        $repos += $page.nodes
        $cursor = if ($page.pageInfo.hasNextPage) { $page.pageInfo.endCursor } else { $null }
    } while ($cursor)

    return $repos
}

# ---------------------------------------------------------------------------
# Find or create the portfolio project
# ---------------------------------------------------------------------------

function Find-OrCreate-Project($owner, $ownerId, $isOrg) {
    $findQuery = if ($isOrg) {
        @"
query FindProject(`$owner: String!) {
  organization(login: `$owner) {
    projectsV2(first: 20) { nodes { id title } }
  }
}
"@
    } else {
        @"
query FindProject(`$owner: String!) {
  user(login: `$owner) {
    projectsV2(first: 20) { nodes { id title } }
  }
}
"@
    }

    $data     = Invoke-GQL $findQuery @{ owner = $owner }
    $projects = if ($isOrg) { $data.organization.projectsV2.nodes } else { $data.user.projectsV2.nodes }
    $existing = $projects | Where-Object { $_.title -eq $PROJECT_TITLE } | Select-Object -First 1

    if ($existing) {
        Write-Host "  Found existing project: '$PROJECT_TITLE' ($($existing.id))"
        return $existing.id
    }

    $created = Invoke-GQL @"
mutation CreateProject(`$ownerId: ID!, `$title: String!) {
  createProjectV2(input: { ownerId: `$ownerId, title: `$title }) {
    projectV2 { id title }
  }
}
"@ @{ ownerId = $ownerId; title = $PROJECT_TITLE }

    $projectId = $created.createProjectV2.projectV2.id
    Write-Host "  Created project: '$PROJECT_TITLE' ($projectId)"
    return $projectId
}

# ---------------------------------------------------------------------------
# Get current project fields
# ---------------------------------------------------------------------------

function Get-ProjectFields($projectId) {
    $data = Invoke-GQL @"
query GetFields(`$projectId: ID!) {
  node(id: `$projectId) {
    ... on ProjectV2 {
      fields(first: 25) {
        nodes {
          ... on ProjectV2Field { id name dataType }
          ... on ProjectV2SingleSelectField {
            id name dataType
            options { id name }
          }
        }
      }
    }
  }
}
"@ @{ projectId = $projectId }

    return $data.node.fields.nodes
}

# ---------------------------------------------------------------------------
# Ensure all iPGM custom fields exist
# ---------------------------------------------------------------------------

$DESIRED_FIELDS = @(
    @{ name = "Status";          dataType = "SINGLE_SELECT"; manual = $true;
       options = @(
           @{ name = "Todo";        color = "GRAY"   }
           @{ name = "In Progress"; color = "YELLOW" }
           @{ name = "Done";        color = "GREEN"  }
       )
    }
    @{ name = "Phase";           dataType = "SINGLE_SELECT"; manual = $true;
       options = @(
           @{ name = "Initiation"; color = "BLUE"   }
           @{ name = "Planning";   color = "PURPLE" }
           @{ name = "Execution";  color = "YELLOW" }
           @{ name = "Go-Live";    color = "ORANGE" }
           @{ name = "Monitoring"; color = "GREEN"  }
           @{ name = "Closed";     color = "GRAY"   }
       )
    }
    @{ name = "PEI Level";       dataType = "SINGLE_SELECT"; manual = $true;
       options = @(
           @{ name = "High";   color = "RED"    }
           @{ name = "Medium"; color = "YELLOW" }
           @{ name = "Low";    color = "GREEN"  }
       )
    }
    @{ name = "Program Manager"; dataType = "TEXT";          manual = $true  }
    @{ name = "Language";        dataType = "TEXT";          manual = $false }
    @{ name = "Visibility";      dataType = "SINGLE_SELECT"; manual = $false;
       options = @(
           @{ name = "Public";  color = "GREEN" }
           @{ name = "Private"; color = "GRAY"  }
       )
    }
    @{ name = "Stars";           dataType = "NUMBER";        manual = $false }
    @{ name = "Repo URL";        dataType = "TEXT";          manual = $false }
)

function Initialize-Fields($projectId) {
    $existing      = Get-ProjectFields $projectId
    $existingByName = @{}
    foreach ($f in $existing) { $existingByName[$f.name] = $f }
    $fieldMap = @{}

    foreach ($desired in $DESIRED_FIELDS) {
        $field = $existingByName[$desired.name]

        if (-not $field) {
            $isSS = $desired.dataType -eq "SINGLE_SELECT"
            $vars = @{
                projectId = $projectId
                name      = $desired.name
                dataType  = $desired.dataType
            }
            if ($isSS) {
                $vars.options = @($desired.options | ForEach-Object {
                    @{ name = $_.name; color = $_.color; description = "" }
                })
            }

            $result = Invoke-GQL @"
mutation CreateField(
  `$projectId: ID!
  `$name: String!
  `$dataType: ProjectV2CustomFieldType!
  `$options: [ProjectV2SingleSelectFieldOptionInput!]
) {
  createProjectV2Field(input: {
    projectId: `$projectId
    name: `$name
    dataType: `$dataType
    singleSelectOptions: `$options
  }) {
    projectV2Field {
      ... on ProjectV2Field { id name dataType }
      ... on ProjectV2SingleSelectField { id name dataType options { id name } }
    }
  }
}
"@ $vars

            $field = $result.createProjectV2Field.projectV2Field
            Write-Host "  Created field: '$($desired.name)'"
        }

        # Ensure all options exist on SINGLE_SELECT fields
        if ($desired.dataType -eq "SINGLE_SELECT" -and $desired.options) {
            $existingOpts = @{}
            foreach ($o in $field.options) { $existingOpts[$o.name] = $true }
            $needsUpdate  = $desired.options | Where-Object { -not $existingOpts[$_.name] }

            if ($needsUpdate) {
                $updated = Invoke-GQL @"
mutation SetOptions(`$projectId: ID!, `$fieldId: ID!, `$options: [ProjectV2SingleSelectFieldOptionInput!]!) {
  updateProjectV2Field(input: {
    projectId: `$projectId
    fieldId: `$fieldId
    singleSelectOptions: `$options
  }) {
    projectV2Field {
      ... on ProjectV2SingleSelectField { id options { id name } }
    }
  }
}
"@ @{
                    projectId = $projectId
                    fieldId   = $field.id
                    options   = @($desired.options | ForEach-Object {
                        @{ name = $_.name; color = $_.color; description = "" }
                    })
                }
                $field = $updated.updateProjectV2Field.projectV2Field
                Write-Host "  Updated options on '$($desired.name)'"
            }
        }

        $entry = @{ id = $field.id; dataType = $desired.dataType; manual = $desired.manual }
        if ($desired.dataType -eq "SINGLE_SELECT") {
            $optMap = @{}
            foreach ($o in $field.options) { $optMap[$o.name] = $o.id }
            $entry.options = $optMap
        }
        $fieldMap[$desired.name] = $entry
    }

    return $fieldMap
}

# ---------------------------------------------------------------------------
# Get all existing project items (paginated)
# ---------------------------------------------------------------------------

function Get-AllItems($projectId) {
    $itemMap = @{}
    $cursor  = $null

    do {
        $data = Invoke-GQL @"
query GetItems(`$projectId: ID!, `$cursor: String) {
  node(id: `$projectId) {
    ... on ProjectV2 {
      items(first: 100, after: `$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          content {
            ... on DraftIssue { title }
            ... on Issue { url }
          }
        }
      }
    }
  }
}
"@ @{ projectId = $projectId; cursor = $cursor }

        $page = $data.node.items
        foreach ($item in $page.nodes) {
            $key = if ($item.content.title) { $item.content.title } else { $item.content.url }
            if ($key) { $itemMap[$key] = $item.id }
        }
        $cursor = if ($page.pageInfo.hasNextPage) { $page.pageInfo.endCursor } else { $null }
    } while ($cursor)

    return $itemMap
}

# ---------------------------------------------------------------------------
# Set a field value on a board item
# ---------------------------------------------------------------------------

function Set-FieldValue($projectId, $itemId, $field, $value) {
    $valueInput = $null

    if ($field.dataType -eq "TEXT") {
        $valueInput = @{ text = [string]$value }
    } elseif ($field.dataType -eq "NUMBER") {
        $valueInput = @{ number = [double]$value }
    } elseif ($field.dataType -eq "SINGLE_SELECT") {
        $optionId = $field.options[$value]
        if (-not $optionId) { return }
        $valueInput = @{ singleSelectOptionId = $optionId }
    } else {
        return
    }

    Invoke-GQL @"
mutation UpdateField(`$projectId: ID!, `$itemId: ID!, `$fieldId: ID!, `$value: ProjectV2FieldValue!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: `$projectId
    itemId:    `$itemId
    fieldId:   `$fieldId
    value:     `$value
  }) {
    projectV2Item { id }
  }
}
"@ @{ projectId = $projectId; itemId = $itemId; fieldId = $field.id; value = $valueInput } | Out-Null
}

# ---------------------------------------------------------------------------
# Upsert a repo as a draft issue on the board
# ---------------------------------------------------------------------------

function Sync-Repo($projectId, $fieldMap, [ref]$itemMap, $repo) {
    $isNew  = -not $itemMap.Value.ContainsKey($repo.name)
    $itemId = $null

    if ($isNew) {
        $result = Invoke-GQL @"
mutation AddDraft(`$projectId: ID!, `$title: String!, `$body: String!) {
  addProjectV2DraftIssue(input: { projectId: `$projectId, title: `$title, body: `$body }) {
    projectItem { id }
  }
}
"@ @{ projectId = $projectId; title = $repo.name; body = if ($repo.description) { $repo.description } else { "" } }

        $itemId = $result.addProjectV2DraftIssue.projectItem.id
        $itemMap.Value[$repo.name] = $itemId
    } else {
        $itemId = $itemMap.Value[$repo.name]
    }

    # Auto-sync metadata fields
    $lang = if ($repo.primaryLanguage -and $repo.primaryLanguage.name) { $repo.primaryLanguage.name } else { "" }
    Set-FieldValue $projectId $itemId $fieldMap["Language"]   $lang
    Set-FieldValue $projectId $itemId $fieldMap["Repo URL"]   $repo.url
    Set-FieldValue $projectId $itemId $fieldMap["Stars"]      $repo.stargazerCount
    $visibility = if ($repo.isPrivate) { "Private" } else { "Public" }
    Set-FieldValue $projectId $itemId $fieldMap["Visibility"] $visibility

    # Manual fields - set defaults on new items only
    if ($isNew) {
        Set-FieldValue $projectId $itemId $fieldMap["Status"] "Todo"
        Set-FieldValue $projectId $itemId $fieldMap["Phase"]  "Initiation"
    }

    return $isNew
}

# ---------------------------------------------------------------------------
# Ensure portfolio-report label exists in every repo
# ---------------------------------------------------------------------------

function Initialize-Label($owner, $repos) {
    foreach ($repo in $repos) {
        $labels = Invoke-GH "/repos/$owner/$($repo.name)/labels"
        if (-not $labels) { continue }
        if ($labels | Where-Object { $_.name -eq $LABEL_NAME }) { continue }

        Invoke-GH "/repos/$owner/$($repo.name)/labels" "POST" @{
            name        = $LABEL_NAME
            color       = $LABEL_COLOR
            description = $LABEL_DESC
        } | Out-Null

        Write-Host "  Created label '$LABEL_NAME' in $($repo.name)"
    }
}

# ---------------------------------------------------------------------------
# Get issues labelled portfolio-report
# ---------------------------------------------------------------------------

function Get-FlaggedIssues($owner, $isOrg) {
    $issues    = @()
    $cursor    = $null
    $qualifier = if ($isOrg) { "org:$owner" } else { "user:$owner" }

    do {
        $data = Invoke-GQL @"
query GetFlagged(`$query: String!, `$cursor: String) {
  search(query: `$query, type: ISSUE, first: 100, after: `$cursor) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on Issue {
        id title url number
        repository { name }
      }
    }
  }
}
"@ @{ query = "$qualifier label:$LABEL_NAME is:issue is:open"; cursor = $cursor }

        $page    = $data.search
        $issues += $page.nodes | Where-Object { $_.id }
        $cursor  = if ($page.pageInfo.hasNextPage) { $page.pageInfo.endCursor } else { $null }
    } while ($cursor)

    return $issues
}

function Sync-FlaggedIssues($projectId, [ref]$itemMap, $issues) {
    $added = 0
    foreach ($issue in $issues) {
        if ($itemMap.Value.ContainsKey($issue.url)) { continue }

        $result = Invoke-GQL @"
mutation AddIssue(`$projectId: ID!, `$contentId: ID!) {
  addProjectV2ItemById(input: { projectId: `$projectId, contentId: `$contentId }) {
    item { id }
  }
}
"@ @{ projectId = $projectId; contentId = $issue.id }

        $itemMap.Value[$issue.url] = $result.addProjectV2ItemById.item.id
        Write-Host "  + Issue: [$($issue.repository.name)#$($issue.number)] $($issue.title)"
        $added++
    }
    return $added
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "iPGM Hub and Spoke Portfolio Sync"
Write-Host "Owner  : $OWNER"
Write-Host "Project: $PROJECT_TITLE"
Write-Host ""

Write-Host "Detecting account type..."
$ownerInfo = Get-OwnerInfo $OWNER
$isOrg     = $ownerInfo.IsOrg
$ownerId   = $ownerInfo.Id
Write-Host "  $(if ($isOrg) { 'Organization' } else { 'Personal account' })"

Write-Host "Fetching all repos..."
$repos = Get-AllRepos $OWNER
Write-Host "  Found $($repos.Count) repos"

Write-Host "Finding or creating iPGM portfolio project..."
$projectId = Find-OrCreate-Project $OWNER $ownerId $isOrg

Write-Host "Ensuring iPGM custom fields..."
$fieldMap = Initialize-Fields $projectId

Write-Host "Ensuring portfolio-report label in all repos..."
Initialize-Label $OWNER $repos

Write-Host "Loading existing project items..."
$itemMap = Get-AllItems $projectId

Write-Host "Syncing repos to board..."
$created = 0
$updated = 0
foreach ($repo in $repos) {
    $isNew = Sync-Repo $projectId $fieldMap ([ref]$itemMap) $repo
    if ($isNew) { $created++; Write-Host "  + Added: $($repo.name)" }
    else        { $updated++ }
}

Write-Host "Fetching flagged issues..."
$issues = Get-FlaggedIssues $OWNER $isOrg
Write-Host "  Found $($issues.Count) issue(s) labelled '$LABEL_NAME'"

Write-Host "Syncing flagged issues..."
$issuesAdded = Sync-FlaggedIssues $projectId ([ref]$itemMap) $issues

Write-Host ""
Write-Host "Done."
Write-Host "  Repos  -- created: $created, updated: $updated"
Write-Host "  Issues -- added:   $issuesAdded"
Write-Host ""
Write-Host "Board: github.com/$OWNER?tab=projects"
Write-Host ""
