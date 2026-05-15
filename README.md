# Start/Stop VMs during off-hours (V2) — managed identity fork

The Start/Stop VMs during off-hours feature starts or stops enabled Azure VMs on user-defined schedules, surfaces telemetry through Application Insights, and sends optional emails via action groups. It works with Azure Resource Manager VMs.

This **fork** of [`microsoft/startstopv2-deployments`](https://github.com/microsoft/startstopv2-deployments) replaces all storage shared-key access with **system-assigned managed identity** and runs the Function App on **Flex Consumption (FC1) Linux**. It is intended to be deployed via the included `deploy.ps1` script (or the "Deploy to Azure" buttons further down, which point to the templates in this fork).

Upstream user guide: https://learn.microsoft.com/azure/azure-functions/start-stop-vms/overview

> **Required:** **Owner** permission at the subscription scope is needed during initial deployment so that role assignments for the managed identity can be created.

---

## Quick start (`deploy.ps1`)

### Prerequisites

- PowerShell 7+
- [Azure CLI](https://aka.ms/installazurecliwindows) 2.70.0 or newer
- Owner role on the target subscription
- A region that supports **Flex Consumption FC1** (e.g. `swedencentral`, `eastus`, `eastus2`, `northeurope`, `uksouth`)

### Run it

```powershell
# 1. Sign in
az login
az account set --subscription "<your-subscription-id>"

# 2. Clone this fork
git clone https://github.com/GHogbin/startstopv2-deployments.git
cd startstopv2-deployments

# 3. Deploy
./deploy.ps1 `
    -ResourceGroupName "rg-startstop-v2" `
    -Location "swedencentral" `
    -AlertEmail "you@example.com"
```

### Script parameters

| Parameter | Default | Notes |
| --- | --- | --- |
| `ResourceGroupName` | `rg-startstop-v2` | Created if it does not exist |
| `Location` | `eastus` | Must support Flex Consumption FC1 |
| `FunctionAppNamePrefix` | `ssv2func` | Random 4-digit suffix appended |
| `StorageAccountPrefix` | `ssv2stor` | Random 6-digit suffix appended (lower-cased, max 24 chars) |
| `AlertEmail` | *(empty)* | Recipient on the alert action group |

### What the script deploys

1. Resource group (if missing)
2. [`artifacts/nestedtemplates/AutomationUpdate.json`](artifacts/nestedtemplates/AutomationUpdate.json) — Flex Consumption Function App, storage account, App Insights, Log Analytics workspace, and a system-assigned managed identity granted four data-plane RBAC roles on the storage account:
   - Storage Blob Data Owner
   - Storage Queue Data Contributor
   - Storage Table Data Contributor
   - Storage File Data Privileged Contributor
3. [`artifacts/nestedtemplates/AzDashboard.json`](artifacts/nestedtemplates/AzDashboard.json) — operations dashboard
4. Function code — downloads `StartStopV2.zip` from the upstream release and pushes it via `az functionapp deployment source config-zip`
5. [`artifacts/nestedtemplates/LogicApps.json`](artifacts/nestedtemplates/LogicApps.json) — five scheduler workflows (`Scheduled_start`, `Scheduled_stop`, `Sequenced_start`, `Sequenced_stop`, `AutoStop`). They are created **Disabled** with placeholder target resource groups so you can configure them before they fire.
6. [`artifacts/nestedtemplates/AlertEmail.json`](artifacts/nestedtemplates/AlertEmail.json) — action group and three log search alerts using the modern `scheduledQueryRules` 2023-03-15-preview API

---

## Deploy to Azure (portal)

If you would rather deploy from the portal, the buttons below open the wrapper templates from this fork. They install the same managed-identity / Flex Consumption configuration as `deploy.ps1` (minus the function code zip and Logic Apps — run those separately or use `deploy.ps1`).

### Global Azure

[![Deploy to Azure](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg?sanitize=true)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FGHogbin%2Fstartstopv2-deployments%2Fmain%2Fartifacts%2Fssv2autoupdate.json)

### Azure US Government (Fairfax)

[![Deploy to Azure](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg?sanitize=true)](https://portal.azure.us/?microsoft_azure_marketplace_itemhidekey=cuidCustomDeployment#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FGHogbin%2Fstartstopv2-deployments%2Fmain%2Fartifacts%2Fssv2autoupdateff.json)

> The Premium availability-zone variants (`ssv2autoupdateAz.json` / `ssv2autoupdateffAz.json`) are still present in `artifacts/` but have **not** been converted to Flex Consumption. They have the managed-identity changes only and are not recommended unless you specifically need an Elastic Premium plan.

---

## Post-deployment

### Enable the Logic App schedulers

The Logic Apps are deployed in **Disabled** state with `targetResourceGroups` set to a placeholder. For each `ststv2_vms_*` workflow:

1. Open the workflow in the portal.
2. Update the `targetResourceGroups` parameter (or the action body) to list the resource groups containing the VMs you want to manage.
3. Adjust the schedule (default times are Pacific 06:00 / 18:30, AutoStop every 8h).
4. Enable the workflow.

### Multi-subscription support

To let the Function App act on VMs in additional subscriptions, grant its **managed identity** (not the function name) the `Virtual Machine Contributor` role on each target subscription or resource group. The principal ID is printed at the end of `deploy.ps1`, or:

```powershell
az functionapp identity show -g rg-startstop-v2 -n <functionAppName> --query principalId -o tsv
```

```powershell
az role assignment create `
    --assignee <principalId> `
    --role "Virtual Machine Contributor" `
    --scope "/subscriptions/<otherSubscriptionId>"
```

### Verify alerts

Confirm the `StartStopV2_VM_Notification` action group has the correct email recipient. Three log search alerts (`ScheduledStartStop_AzFunc`, `SequencedStartStop_AzFunc`, `AutoStop_VM_AzFunc`) run every 5 minutes against the Function App's traces.

---

## Updating an existing deployment

To pick up new function code, run the `TriggerAutoUpdate` function manually or let it run on its daily schedule. To pick up infrastructure changes from this fork, re-run `deploy.ps1` against the same resource group — the ARM templates are idempotent.

---

## Known issues

- `CostAnalyticsFunction` and `SavingsAnalyticsFunction` may return `429 Too Many Requests`. These are upstream Microsoft telemetry functions and do not affect VM start/stop functionality.

---

## Differences from upstream

| Area | Upstream (`microsoft/startstopv2-deployments`) | This fork |
| --- | --- | --- |
| Function App plan | Consumption Y1 (Windows) | Flex Consumption FC1 (Linux) |
| Storage auth | Connection strings / shared keys | System-assigned managed identity + RBAC |
| App settings | Colon-separated keys | Double-underscore keys (Flex Consumption requirement) |
| Code deploy | `WEBSITE_RUN_FROM_PACKAGE` URL / MSDeploy | `functionAppConfig.deployment.storage` blob container + `config-zip` |
| Alerts | `microsoft.insights/scheduledQueryRules` 2018-04-16 | `Microsoft.Insights/scheduledQueryRules` 2023-03-15-preview (Common Alert Schema) |
| Schedulers | Created in Function App settings via marketplace UI | Separate `LogicApps.json` template |

---

## Support

This fork is **not supported by Microsoft**. For issues with the underlying Start/Stop V2 solution, see the upstream repo: https://github.com/microsoft/startstopv2-deployments. For issues specific to changes in this fork, open an issue at https://github.com/GHogbin/startstopv2-deployments/issues.

---

## License

This project inherits the MIT license from the upstream repository. See [`LICENSE`](LICENSE) and [`LICENSE-CODE`](LICENSE-CODE).
