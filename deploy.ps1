# Deploy Start/Stop V2 with Managed Identity to Azure
# This script deploys the modified Start/Stop V2 solution with managed identity authentication

param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "rg-startstop-v2",
    
    [Parameter(Mandatory=$false)]
    [string]$Location = "eastus",
    
    [Parameter(Mandatory=$false)]
    [string]$FunctionAppNamePrefix = "ssv2func",
    
    [Parameter(Mandatory=$false)]
    [string]$StorageAccountPrefix = "ssv2stor",

    [Parameter(Mandatory=$false)]
    [string]$AlertEmail = ""
)

# Colors for output
function Write-Info { Write-Host $args[0] -ForegroundColor Cyan }
function Write-Success { Write-Host $args[0] -ForegroundColor Green }
function Write-Error { Write-Host $args[0] -ForegroundColor Red }

Write-Info "╔════════════════════════════════════════════════════════════╗"
Write-Info "║   Start/Stop V2 Deployment with Managed Identity          ║"
Write-Info "╚════════════════════════════════════════════════════════════╝"
Write-Host ""

# Check Azure CLI
Write-Info "Checking Azure CLI..."
$azVersion = az version --query '\"azure-cli\"' -o tsv 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Azure CLI not found. Please install from https://aka.ms/installazurecliwindows"
    exit 1
}
Write-Success "✓ Azure CLI version: $azVersion"

# Check authentication
Write-Info "Checking Azure authentication..."
$account = az account show 2>$null | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    Write-Error "Not logged in to Azure. Please run: az login"
    exit 1
}
Write-Success "✓ Logged in as: $($account.user.name)"
Write-Success "✓ Subscription: $($account.name) ($($account.id))"
Write-Host ""

# Generate unique names
$uniqueSuffix = Get-Random -Minimum 1000 -Maximum 9999
$storageUnique = Get-Random -Minimum 100000 -Maximum 999999
$functionAppName = "$FunctionAppNamePrefix-$uniqueSuffix"
$storageAccountName = "$StorageAccountPrefix$storageUnique"
$appInsightsName = "ssv2insights-$uniqueSuffix"
$workspaceName = "ssv2workspace-$uniqueSuffix"

# Validate storage account name (must be 3-24 chars, lowercase and numbers only)
if ($storageAccountName.Length -gt 24) {
    $storageAccountName = $storageAccountName.Substring(0, 24)
}
$storageAccountName = $storageAccountName.ToLower() -replace '[^a-z0-9]', ''

Write-Info "Deployment Configuration:"
Write-Host "  Resource Group: $ResourceGroupName"
Write-Host "  Location: $Location"
Write-Host "  Function App: $functionAppName"
Write-Host "  Storage Account: $storageAccountName"
Write-Host "  App Insights: $appInsightsName"
Write-Host "  Workspace: $workspaceName"
Write-Host ""

# Confirm deployment
$confirmation = Read-Host "Proceed with deployment? (yes/no)"
if ($confirmation -ne "yes") {
    Write-Info "Deployment cancelled."
    exit 0
}
Write-Host ""

# Create resource group
Write-Info "Creating resource group..."
az group create --name $ResourceGroupName --location $Location --output none
if ($LASTEXITCODE -eq 0) {
    Write-Success "✓ Resource group created: $ResourceGroupName"
} else {
    Write-Error "✗ Failed to create resource group"
    exit 1
}

# Deploy template
Write-Info "Deploying Start/Stop V2 resources..."
Write-Host "  This may take 5-10 minutes..."
Write-Host ""

$deploymentName = "ssv2-managedid-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$templateFile = Join-Path $PSScriptRoot "artifacts\nestedtemplates\AutomationUpdate.json"

$deployResult = az deployment group create `
    --name $deploymentName `
    --resource-group $ResourceGroupName `
    --template-file $templateFile `
    --parameters `
        azureFunctionAppName=$functionAppName `
        applicationInsightsName=$appInsightsName `
        applicationInsightsRegion=$Location `
        storageAccountName=$storageAccountName `
        workspaceName=$workspaceName `
        workspaceRegion=$Location `
        azureCloudEnvironment="AzureGlobalCloud" `
    --output json 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Success "✓ Deployment completed successfully!"
} else {
    Write-Error "✗ Deployment failed"
    Write-Host $deployResult
    exit 1
}

# Deploy dashboard
Write-Host ""
Write-Info "Deploying Start/Stop V2 dashboard..."
$dashboardTemplateFile = Join-Path $PSScriptRoot "artifacts\nestedtemplates\AzDashboard.json"
$dashboardDeploymentName = "ssv2-dashboard-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

$dashboardResult = az deployment group create `
    --name $dashboardDeploymentName `
    --resource-group $ResourceGroupName `
    --template-file $dashboardTemplateFile `
    --parameters `
        appInsightName=$appInsightsName `
        appInsightRegion=$Location `
    --output json 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Success "✓ Dashboard deployed successfully!"
} else {
    Write-Error "✗ Dashboard deployment failed (continuing)"
    Write-Host $dashboardResult
}

# Deploy function code package
Write-Host ""
Write-Info "Deploying function code package..."
$functionPackageUrl = "https://raw.githubusercontent.com/microsoft/startstopv2-deployments/main/artifacts/StartStopV2.zip"
$functionPackagePath = Join-Path $PSScriptRoot "StartStopV2.zip"

try {
    Write-Host "  Downloading package from GitHub..."
    Invoke-WebRequest -Uri $functionPackageUrl -OutFile $functionPackagePath -UseBasicParsing
    Write-Success "✓ Package downloaded ($([math]::Round((Get-Item $functionPackagePath).Length / 1MB, 2)) MB)"

    Write-Host "  Publishing to Function App (this can take 1-3 minutes)..."
    $zipResult = az functionapp deployment source config-zip `
        --name $functionAppName `
        --resource-group $ResourceGroupName `
        --src $functionPackagePath 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Success "✓ Function code deployed successfully!"
        Start-Sleep -Seconds 10
        $functions = az functionapp function list --name $functionAppName --resource-group $ResourceGroupName --query "length(@)" -o tsv 2>$null
        if ($functions) { Write-Host "  Active functions: $functions" }
    } else {
        Write-Error "✗ Function code deployment failed"
        Write-Host $zipResult
    }
} catch {
    Write-Error "✗ Failed to download or deploy function package: $_"
}

# Deploy Logic Apps schedulers
Write-Host ""
Write-Info "Deploying scheduler Logic Apps (created Disabled)..."
$logicAppsTemplateFile = Join-Path $PSScriptRoot "artifacts\nestedtemplates\LogicApps.json"
$logicAppsDeploymentName = "ssv2-logicapps-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

$logicAppsResult = az deployment group create `
    --name $logicAppsDeploymentName `
    --resource-group $ResourceGroupName `
    --template-file $logicAppsTemplateFile `
    --parameters `
        functionAppName=$functionAppName `
        location=$Location `
    --output json 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Success "✓ Logic Apps deployed (Disabled). Edit schedules + target resource groups, then enable in portal."
} else {
    Write-Error "✗ Logic Apps deployment failed (continuing)"
    Write-Host $logicAppsResult
}

# Deploy alert rules and action group
Write-Host ""
Write-Info "Deploying alert rules and action group..."
$alertTemplateFile = Join-Path $PSScriptRoot "artifacts\nestedtemplates\AlertEmail.json"
$alertDeploymentName = "ssv2-alerts-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

$alertParams = @(
    "appInsightName=$appInsightsName",
    "appInsightRegion=$Location"
)
if ($AlertEmail) {
    $alertParams += "Email Addresses=$AlertEmail"
    Write-Host "  Recipients: $AlertEmail"
} else {
    Write-Host "  Recipients: (using default from AlertEmail.json)"
}

$alertResult = az deployment group create `
    --name $alertDeploymentName `
    --resource-group $ResourceGroupName `
    --template-file $alertTemplateFile `
    --parameters $alertParams `
    --output json 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Success "✓ Alert rules deployed."
} else {
    Write-Error "✗ Alert rules deployment failed (continuing)"
    Write-Host $alertResult
}

Write-Host ""
Write-Success "╔════════════════════════════════════════════════════════════╗"
Write-Success "║   Deployment Complete!                                     ║"
Write-Success "╚════════════════════════════════════════════════════════════╝"
Write-Host ""

# Display deployment information
Write-Info "Resource Details:"
Write-Host "  Resource Group: $ResourceGroupName"
Write-Host "  Function App: $functionAppName"
Write-Host "  Storage Account: $storageAccountName"
Write-Host "  Application Insights: $appInsightsName"
Write-Host "  Log Analytics Workspace: $workspaceName"
Write-Host ""

# Verify managed identity
Write-Info "Verifying managed identity configuration..."
$identity = az functionapp identity show `
    --name $functionAppName `
    --resource-group $ResourceGroupName `
    --query principalId -o tsv 2>$null

if ($LASTEXITCODE -eq 0 -and $identity) {
    Write-Success "✓ System-assigned managed identity enabled"
    Write-Host "  Principal ID: $identity"
    
    # Check role assignments
    Write-Info "Checking role assignments..."
    Start-Sleep -Seconds 5  # Allow time for role assignments to propagate
    
    $subscriptionId = $account.id
    $storageScope = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$storageAccountName"
    
    $roleAssignments = az role assignment list --scope $storageScope --query "[?principalId=='$identity'].roleDefinitionName" -o tsv
    
    if ($roleAssignments) {
        Write-Success "✓ Role assignments configured:"
        $roleAssignments | ForEach-Object { Write-Host "    - $_" }
    } else {
        Write-Host "  ⚠ Role assignments may still be propagating (this can take 1-2 minutes)"
    }
} else {
    Write-Host "  ⚠ Could not verify managed identity (may still be initializing)"
}

Write-Host ""
Write-Info "Next Steps:"
Write-Host "1. View Function App in portal:"
Write-Host "   https://portal.azure.com/#resource/subscriptions/$($account.id)/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$functionAppName"
Write-Host ""
Write-Host "2. Configure VM schedules in Function App Configuration"
Write-Host ""
Write-Host "3. Review Application Insights dashboard"
Write-Host ""
Write-Host "4. For multi-subscription support, see README.md"
Write-Host ""

Write-Success "Deployment script completed!"
