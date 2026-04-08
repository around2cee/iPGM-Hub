# run-sync.ps1
# Runs the iPGM portfolio sync - pure PowerShell, no Node.js or git required.
# Designed for ephemeral Citrix environments.
# PAT is stored encrypted on your persistent F:\ drive.
#
# FIRST TIME SETUP (run once):
#   .\run-sync.ps1 -Setup
#
# NORMAL USE:
#   .\run-sync.ps1

param(
    [switch]$Setup
)

$GITHUB_USER = "csantos"
$CRED_FILE   = "F:\.ipgm_token.xml"

# ---------------------------------------------------------------------------
# Setup mode - save encrypted PAT to F:\
# ---------------------------------------------------------------------------

if ($Setup) {
    Write-Host ""
    Write-Host "iPGM Token Setup"
    Write-Host "----------------"
    Write-Host "Saves your GitHub PAT encrypted to $CRED_FILE"
    Write-Host "It can only be decrypted by you on this Citrix environment."
    Write-Host ""

    $secureToken = Read-Host "Enter your csantos work GitHub PAT (ghp_...)" -AsSecureString
    $cred        = New-Object System.Management.Automation.PSCredential("ipgm", $secureToken)
    $cred        | Export-Clixml -Path $CRED_FILE

    Write-Host ""
    Write-Host "Token saved to: $CRED_FILE"
    Write-Host "Run .\run-sync.ps1 (no flags) to sync the portfolio board."
    Write-Host ""
    exit 0
}

# ---------------------------------------------------------------------------
# Load token from encrypted file
# ---------------------------------------------------------------------------

if (-not (Test-Path $CRED_FILE)) {
    Write-Host ""
    Write-Host "No token found. Run setup first:"
    Write-Host "  .\run-sync.ps1 -Setup"
    Write-Host ""
    exit 1
}

try {
    $cred  = Import-Clixml -Path $CRED_FILE
    $TOKEN = $cred.GetNetworkCredential().Password
} catch {
    Write-Error "Could not read token from $CRED_FILE - run .\run-sync.ps1 -Setup again."
    exit 1
}

# ---------------------------------------------------------------------------
# Run the sync (sync.ps1 is in the same folder as this script)
# ---------------------------------------------------------------------------

$env:ORG_PORTFOLIO_TOKEN = $TOKEN
$env:ORG_NAME            = $GITHUB_USER

$syncScript = Join-Path $PSScriptRoot "sync.ps1"

if (-not (Test-Path $syncScript)) {
    Write-Error "Cannot find sync.ps1 at $syncScript"
    exit 1
}

& $syncScript

if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    Write-Error "Sync failed - check output above."
    exit 1
}
