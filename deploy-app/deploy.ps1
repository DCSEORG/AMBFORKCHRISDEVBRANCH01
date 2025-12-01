<#
.SYNOPSIS
    Deploys the Expense Management application to Azure App Service.

.DESCRIPTION
    This script automates the application deployment process including:
    - Building and publishing the .NET application
    - Creating a deployment zip package
    - Deploying to Azure App Service
    - Optionally configuring app settings

    The script can read deployment context from the infrastructure deployment,
    eliminating the need to manually specify resource group and web app names.

.PARAMETER ResourceGroup
    The name of the Azure resource group containing the App Service.
    Optional if .deployment-context.json exists from infrastructure deployment.

.PARAMETER WebAppName
    The name of the Azure Web App to deploy to.
    Optional if .deployment-context.json exists from infrastructure deployment.

.PARAMETER SkipBuild
    Switch to skip the build step (useful if already built).

.PARAMETER ConfigureSettings
    Switch to configure app settings after deployment.

.EXAMPLE
    .\deploy.ps1

.EXAMPLE
    .\deploy.ps1 -ResourceGroup "rg-expensemgmt-demo"

.EXAMPLE
    .\deploy.ps1 -ResourceGroup "rg-expensemgmt-demo" -WebAppName "app-expensemgmt-abc123"

.EXAMPLE
    .\deploy.ps1 -SkipBuild -ConfigureSettings
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$WebAppName,

    [Parameter(Mandatory = $false)]
    [switch]$SkipBuild,

    [Parameter(Mandatory = $false)]
    [switch]$ConfigureSettings
)

# Set error preference
$ErrorActionPreference = "Continue"

# Check PowerShell version and warn if using older version
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "[WARNING] You are running PowerShell $($PSVersionTable.PSVersion). PowerShell 7+ is recommended." -ForegroundColor Yellow
    Write-Host "          Install with: winget install Microsoft.PowerShell" -ForegroundColor Yellow
    Write-Host ""
}

# Colors for output
function Write-Step { param($Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Success { param($Message) Write-Host "    [OK] $Message" -ForegroundColor Green }
function Write-Info { param($Message) Write-Host "    $Message" -ForegroundColor White }
function Write-Warning { param($Message) Write-Host "    [WARNING] $Message" -ForegroundColor Yellow }
function Write-Error { param($Message) Write-Host "    [ERROR] $Message" -ForegroundColor Red }

# Banner
Write-Host ""
Write-Host "=========================================" -ForegroundColor Magenta
Write-Host "  Expense Management App Deployment" -ForegroundColor Magenta
Write-Host "=========================================" -ForegroundColor Magenta
Write-Host ""

# Find repo root and check for deployment context
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$contextFile = Join-Path $repoRoot ".deployment-context.json"
$deploymentContext = $null

# Load deployment context if available
if (Test-Path $contextFile) {
    Write-Step "Loading deployment context"
    $deploymentContext = Get-Content $contextFile | ConvertFrom-Json
    Write-Success "Found deployment context from: $($deploymentContext.deployedAt)"
    
    # Use context values if parameters not provided
    if (-not $ResourceGroup) {
        $ResourceGroup = $deploymentContext.resourceGroup
        Write-Info "Using resource group from context: $ResourceGroup"
    }
    if (-not $WebAppName) {
        $WebAppName = $deploymentContext.webAppName
        Write-Info "Using web app from context: $WebAppName"
    }
}

# Validate we have required values
if (-not $ResourceGroup) {
    Write-Error "Resource group not specified and no deployment context found."
    Write-Error "Either run deploy-infra/deploy.ps1 first, or provide -ResourceGroup parameter."
    exit 1
}

# Validate Azure CLI is installed and logged in
Write-Step "Validating prerequisites"
try {
    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) {
        throw "Not logged into Azure CLI"
    }
    Write-Success "Logged into Azure CLI as $($account.user.name)"
} catch {
    Write-Error "Please login to Azure CLI first: az login"
    exit 1
}

# Check if .NET SDK is installed
$dotnetVersion = dotnet --version 2>$null
if (-not $dotnetVersion) {
    Write-Error ".NET SDK is not installed. Please install it from https://dotnet.microsoft.com/download"
    exit 1
}
Write-Success ".NET SDK version: $dotnetVersion"

# Get web app name from deployment outputs if not provided
if (-not $WebAppName) {
    Write-Step "Retrieving web app name from infrastructure deployment"
    try {
        $WebAppName = az deployment group show --resource-group $ResourceGroup --name main --query "properties.outputs.webAppName.value" -o tsv 2>$null
        if (-not $WebAppName) {
            Write-Error "Could not retrieve web app name. Please provide -WebAppName parameter or ensure infrastructure is deployed."
            exit 1
        }
        Write-Success "Web App: $WebAppName"
    } catch {
        Write-Error "Failed to retrieve deployment outputs. Please provide -WebAppName parameter."
        exit 1
    }
} else {
    Write-Success "Web App: $WebAppName"
}

# Find the source directory
$srcDir = Join-Path (Join-Path $repoRoot "src") "ExpenseManagement"

if (-not (Test-Path $srcDir)) {
    Write-Error "Source directory not found at: $srcDir"
    exit 1
}

# Build and publish
if (-not $SkipBuild) {
    Write-Step "Building and publishing application"
    Write-Info "Source directory: $srcDir"
    
    Push-Location $srcDir
    try {
        $publishDir = Join-Path $srcDir "publish"
        
        # Clean previous publish
        if (Test-Path $publishDir) {
            Remove-Item -Recurse -Force $publishDir
        }
        
        Write-Info "Running dotnet publish..."
        dotnet publish -c Release -o ./publish --verbosity quiet
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Build failed"
            exit 1
        }
        Write-Success "Application built successfully"
    } finally {
        Pop-Location
    }
} else {
    Write-Step "Skipping build (SkipBuild flag set)"
}

# Create deployment zip
Write-Step "Creating deployment package"
$publishDir = Join-Path $srcDir "publish"
$zipPath = Join-Path $srcDir "app.zip"

if (-not (Test-Path $publishDir)) {
    Write-Error "Publish directory not found. Please build first or remove -SkipBuild flag."
    exit 1
}

# Remove old zip if exists
if (Test-Path $zipPath) {
    Remove-Item -Force $zipPath
}

Write-Info "Creating zip from: $publishDir"
Compress-Archive -Path (Join-Path $publishDir "*") -DestinationPath $zipPath

if (-not (Test-Path $zipPath)) {
    Write-Error "Failed to create deployment zip"
    exit 1
}

$zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
Write-Success "Deployment package created: $zipSize MB"

# Deploy to Azure
Write-Step "Deploying to Azure App Service"
Write-Info "Deploying to: $WebAppName"

az webapp deploy `
    --resource-group $ResourceGroup `
    --name $WebAppName `
    --src-path $zipPath `
    --type zip `
    --clean true `
    --restart true `
    --output none

if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment failed"
    exit 1
}

Write-Success "Application deployed successfully"

# Configure app settings if requested
if ($ConfigureSettings) {
    Write-Step "Configuring app settings"
    
    $managedIdentityClientId = $null
    $sqlServerFqdn = $null
    
    # Try to get values from deployment context first
    if ($deploymentContext) {
        $managedIdentityClientId = $deploymentContext.managedIdentityClientId
        $sqlServerFqdn = $deploymentContext.sqlServerFqdn
        Write-Info "Using values from deployment context"
    }
    
    # Fall back to Azure deployment outputs if not in context
    if (-not $managedIdentityClientId -or -not $sqlServerFqdn) {
        Write-Info "Retrieving values from Azure deployment outputs"
        $managedIdentityClientId = az deployment group show --resource-group $ResourceGroup --name main --query "properties.outputs.managedIdentityClientId.value" -o tsv
        $sqlServerFqdn = az deployment group show --resource-group $ResourceGroup --name main --query "properties.outputs.sqlServerFqdn.value" -o tsv
    }
    
    if ($managedIdentityClientId -and $sqlServerFqdn) {
        $connectionString = "Server=tcp:$sqlServerFqdn,1433;Initial Catalog=Northwind;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;Authentication=Active Directory Managed Identity;User Id=$managedIdentityClientId;"
        
        az webapp config appsettings set `
            --resource-group $ResourceGroup `
            --name $WebAppName `
            --settings "AZURE_CLIENT_ID=$managedIdentityClientId" "ConnectionStrings__DefaultConnection=$connectionString" `
            --output none
        
        Write-Success "App settings configured"
    } else {
        Write-Warning "Could not retrieve managed identity or SQL server details"
    }
}

# Clean up
Write-Step "Cleaning up"
if (Test-Path $zipPath) {
    Remove-Item -Force $zipPath
    Write-Success "Removed deployment package"
}

# Summary
$webAppUrl = "https://$WebAppName.azurewebsites.net"

Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host "  Deployment Complete!" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Application URLs:" -ForegroundColor White
Write-Host "  Main UI:     $webAppUrl/Index" -ForegroundColor Gray
Write-Host "  Swagger API: $webAppUrl/swagger" -ForegroundColor Gray
Write-Host ""
Write-Host "Note: Navigate to /Index to view the application." -ForegroundColor Yellow
Write-Host ""
