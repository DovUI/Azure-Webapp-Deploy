<#
.SYNOPSIS
    Interactive deployment script for a new orchestration resource set.

.DESCRIPTION
    Prompts the user for a prefix (e.g. "orch2026"), then deploys an ARM template
    that creates the following resources in the target resource group:

      <prefix>-asp          App Service Plan (S1 Standard)
      <prefix>              Web App
      <prefix>-is           Web App
      <prefix>-wh           Web App
      <prefix>-rc           Web App
      <prefix>db            SQL Database (S1 Standard) on existing server

    Requires Azure CLI (az) to be installed and logged in.

.EXAMPLE
    .\Deploy-OrchResources.ps1
#>

[CmdletBinding()]
param(
    [string]$TemplateFile = (Join-Path $PSScriptRoot 'orch-template.json'),
    [string]$DefaultResourceGroup = 'Infra-DovB-RG',
    [string]$DefaultSqlServer = 'dovorch22sql-dwhngduyobf2g',
    [string]$DefaultLocation = 'East US'
)

# --- sanity checks -----------------------------------------------------------

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI ('az') was not found in PATH. Install it from https://aka.ms/azure-cli and re-run."
    exit 1
}

if (-not (Test-Path $TemplateFile)) {
    Write-Error "Template file not found: $TemplateFile"
    exit 1
}

# Confirm the user is signed in
$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "You are not signed in to Azure. Running 'az login'..." -ForegroundColor Yellow
    az login | Out-Null
    $account = az account show --output json | ConvertFrom-Json
}
Write-Host "Signed in as: $($account.user.name)" -ForegroundColor DarkGray
Write-Host "Subscription: $($account.name) ($($account.id))" -ForegroundColor DarkGray
Write-Host ""

# --- prompt for inputs -------------------------------------------------------

function Read-Default([string]$prompt, [string]$default) {
    $value = Read-Host "$prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $default }
    return $value
}

# Prefix: required, validate against Azure web app naming rules
do {
    $prefix = Read-Host "Resource prefix (e.g. orch2026). Used as <prefix>, <prefix>-is, <prefix>-wh, <prefix>-rc, <prefix>-asp, <prefix>db"
    $prefix = $prefix.Trim().ToLower()

    if ([string]::IsNullOrWhiteSpace($prefix)) {
        Write-Host "  Prefix is required." -ForegroundColor Red
        $valid = $false
        continue
    }

    # Web app names must be 2-60 chars, alphanumeric and hyphens, start/end alphanumeric.
    # We add suffixes up to 3 chars (e.g. '-wh'), so cap the prefix at 57.
    if ($prefix -notmatch '^[a-z0-9]([a-z0-9-]{0,55}[a-z0-9])?$') {
        Write-Host "  Invalid. Use lowercase letters, digits and hyphens. Must start/end with a letter or digit. 2-57 chars." -ForegroundColor Red
        $valid = $false
        continue
    }
    $valid = $true
} while (-not $valid)

$resourceGroup     = Read-Default 'Resource group'                $DefaultResourceGroup
$location          = Read-Default 'Region for App Service + Plan' $DefaultLocation
$sqlServerName     = Read-Default 'Existing SQL server name'      $DefaultSqlServer
$sqlDatabaseRegion = Read-Default 'SQL database region (MUST match SQL server region)' $DefaultLocation

# --- preview -----------------------------------------------------------------

Write-Host ""
Write-Host "About to deploy the following to resource group '$resourceGroup':" -ForegroundColor Cyan
Write-Host "  App Service Plan : $prefix-asp ($location, S1 Standard)"
Write-Host "  Web App          : $prefix"
Write-Host "  Web App          : $prefix-is"
Write-Host "  Web App          : $prefix-wh"
Write-Host "  Web App          : $prefix-rc"
Write-Host "  SQL Database     : ${prefix}db on $sqlServerName ($sqlDatabaseRegion, S1 Standard)"
Write-Host ""

$dryRun = Read-Host "Run 'what-if' preview first to see exact changes? (Y/n)"
if ($dryRun -notmatch '^[nN]') {
    Write-Host "Running what-if..." -ForegroundColor Yellow
    az deployment group what-if `
        --resource-group $resourceGroup `
        --template-file $TemplateFile `
        --parameters prefix=$prefix `
                     location="$location" `
                     sqlServerName=$sqlServerName `
                     sqlDatabaseLocation="$sqlDatabaseRegion"
    Write-Host ""
}

$confirm = Read-Host "Proceed with the actual deployment? (y/N)"
if ($confirm -notmatch '^[yY]') {
    Write-Host "Cancelled. No changes made." -ForegroundColor Yellow
    exit 0
}

# --- deploy ------------------------------------------------------------------

$deploymentName = "$prefix-deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Write-Host "Deploying as '$deploymentName'..." -ForegroundColor Green

az deployment group create `
    --resource-group $resourceGroup `
    --template-file $TemplateFile `
    --name $deploymentName `
    --parameters prefix=$prefix `
                 location="$location" `
                 sqlServerName=$sqlServerName `
                 sqlDatabaseLocation="$sqlDatabaseRegion"

if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment failed. See errors above."
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "Deployment complete." -ForegroundColor Green
Write-Host "Outputs:" -ForegroundColor Cyan
az deployment group show `
    --resource-group $resourceGroup `
    --name $deploymentName `
    --query properties.outputs `
    --output jsonc
