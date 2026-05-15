# Deploy Start/Stop V2 with Managed Identity

This deployment uses the modified templates with managed identity authentication instead of storage account keys.

## Prerequisites

1. Azure CLI installed and authenticated: `az login`
2. Owner permission at the subscription level
3. A resource group created (or will be created by the script)

## Deployment Steps

### Option 1: Deploy Directly (Recommended for Testing)

The nested template `AutomationUpdate.json` is a complete standalone template. Deploy it directly:

```powershell
# Set your parameters
$resourceGroupName = "rg-startstop-v2"
$location = "eastus"
$functionAppName = "ssv2func-$(Get-Random -Maximum 9999)"  # Must be globally unique
$storageAccountName = "ssv2stor$(Get-Random -Maximum 999999)"  # Must be globally unique, lowercase only
$appInsightsName = "ssv2insights-$(Get-Random -Maximum 9999)"
$workspaceName = "ssv2workspace"

# Create resource group if it doesn't exist
az group create --name $resourceGroupName --location $location

# Deploy the template
az deployment group create `
  --resource-group $resourceGroupName `
  --template-file "artifacts/nestedtemplates/AutomationUpdate.json" `
  --parameters `
    azureFunctionAppName=$functionAppName `
    applicationInsightsName=$appInsightsName `
    applicationInsightsRegion=$location `
    storageAccountName=$storageAccountName `
    workspaceName=$workspaceName `
    workspaceRegion=$location `
    azureCloudEnvironment="AzureGlobalCloud"

# Display deployment details
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "Function App: $functionAppName"
Write-Host "Storage Account: $storageAccountName"
Write-Host "Resource Group: $resourceGroupName"
```

### Option 2: Upload Templates to Azure Storage (For Production)

If you want to use the wrapper template with nested deployments:

```powershell
# 1. Create a storage account for templates
$templateStorageAccount = "sstemplates$(Get-Random -Maximum 999999)"
$templateContainer = "templates"

az storage account create `
  --name $templateStorageAccount `
  --resource-group $resourceGroupName `
  --location $location `
  --sku Standard_LRS

az storage container create `
  --name $templateContainer `
  --account-name $templateStorageAccount `
  --auth-mode login

# 2. Upload templates
az storage blob upload `
  --account-name $templateStorageAccount `
  --container-name $templateContainer `
  --name "AutomationUpdate.json" `
  --file "artifacts/nestedtemplates/AutomationUpdate.json" `
  --auth-mode login

# 3. Generate SAS token
$sasToken = az storage container generate-sas `
  --account-name $templateStorageAccount `
  --name $templateContainer `
  --permissions r `
  --expiry (Get-Date).AddHours(4).ToString("yyyy-MM-ddTHH:mmZ") `
  --auth-mode login `
  --output tsv

# 4. Deploy using the wrapper template (update template to use storage URL)
Write-Host "Template URL: https://$templateStorageAccount.blob.core.windows.net/$templateContainer/AutomationUpdate.json?$sasToken"
```

## Verify Managed Identity Configuration

After deployment, verify that managed identity is configured:

```powershell
# Check Function App identity
az functionapp identity show `
  --name $functionAppName `
  --resource-group $resourceGroupName

# Check role assignments on storage account
az role assignment list `
  --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$storageAccountName" `
  --query "[?principalType=='ServicePrincipal'].{Role:roleDefinitionName, Principal:principalId}"
```

You should see three role assignments:
- Storage Blob Data Contributor
- Storage Queue Data Contributor  
- Storage Table Data Contributor

## Key Differences from Original

✅ **No Storage Keys**: Application settings use account name + managed identity credential  
✅ **RBAC Roles**: Three role assignments grant storage access  
✅ **Environment-Aware**: Government cloud templates include explicit service URIs  
✅ **Secure by Default**: Zero secrets in configuration  

## Troubleshooting

If functions fail to start after deployment:
1. Check that role assignments were created successfully
2. Verify Function App has system-assigned managed identity enabled
3. Allow 1-2 minutes for role assignments to propagate
4. Check Function App logs in Application Insights

## Next Steps

After deployment:
1. Configure VM schedules using Function App configuration
2. Set up action groups for email notifications (if needed)
3. Review Application Insights dashboard
4. Enable multi-subscription support (see main README.md)
