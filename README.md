# Start/Stop VMs during off-hours (V2) — managed identity fork

The Start/Stop VMs during off-hours feature starts or stops enabled Azure VMs on user-defined schedules, surfaces telemetry through Application Insights, and sends optional emails via action groups. It works with Azure Resource Manager VMs.

This **fork** of [`microsoft/startstopv2-deployments`](https://github.com/microsoft/startstopv2-deployments) replaces all storage shared-key access with **system-assigned managed identity**. Both the infrastructure (storage account with `allowSharedKeyAccess: false` + RBAC role assignments) and the function code itself have been modified so all queue and table operations go through `DefaultAzureCredential` instead of connection strings.

The Function App runs on a **Windows B1 Basic** plan with the .NET 8 isolated worker runtime. The rebuilt function package (`StartStopV2-MI.zip`) is committed to this repo at the root and is deployed in place of the upstream zip. It is intended to be deployed via the included `deploy.ps1` script (or the "Deploy to Azure" buttons further down, which point to the templates in this fork).

Upstream user guide: https://learn.microsoft.com/azure/azure-functions/start-stop-vms/overview

> **Required:** **Owner** permission at the subscription scope is needed during initial deployment so that role assignments for the managed identity can be created.

---

## Quick start (`deploy.ps1`)

### Prerequisites

- PowerShell 7+
- [Azure CLI](https://aka.ms/installazurecliwindows) 2.70.0 or newer
- Owner role on the target subscription (required to create role assignments for the managed identity)
- Any Azure region that supports App Service Basic (B1) plans

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
| `Location` | `eastus` | Any region with App Service Basic plans |
| `FunctionAppNamePrefix` | `ssv2func` | Random 4-digit suffix appended |
| `StorageAccountPrefix` | `ssv2stor` | Random 6-digit suffix appended (lower-cased, max 24 chars) |
| `AlertEmail` | *(empty)* | Recipient on the alert action group |
| `ScheduleTimeZone` | *(prompted)* | Windows time-zone ID for Logic App recurrence triggers (e.g. `GMT Standard Time`). If omitted, the script prompts interactively and defaults to `Pacific Standard Time`. |

### What the script deploys

1. Resource group (if missing)
2. [`artifacts/nestedtemplates/AutomationUpdate.json`](artifacts/nestedtemplates/AutomationUpdate.json) — Windows B1 App Service plan, .NET 8 isolated Function App, storage account (`allowSharedKeyAccess: false`), App Insights, Log Analytics workspace, and a system-assigned managed identity granted four data-plane RBAC roles on the storage account:
   - Storage Blob Data Owner
   - Storage Queue Data Contributor
   - Storage Table Data Contributor
   - Storage File Data Privileged Contributor
3. [`artifacts/nestedtemplates/AzDashboard.json`](artifacts/nestedtemplates/AzDashboard.json) — operations dashboard
4. Function code — by default `deploy.ps1` still downloads the upstream `StartStopV2.zip`. To deploy the MI-aware build that ships with this fork, push [`StartStopV2-MI.zip`](StartStopV2-MI.zip) after the script finishes:

   ```powershell
   az functionapp deployment source config-zip `
       -g rg-startstop-v2 -n <functionAppName> --src StartStopV2-MI.zip
   ```
5. [`artifacts/nestedtemplates/LogicApps.json`](artifacts/nestedtemplates/LogicApps.json) — five scheduler workflows (`Scheduled_start`, `Scheduled_stop`, `Sequenced_start`, `Sequenced_stop`, `AutoStop`). They are created **Disabled** with placeholder target resource groups so you can configure them before they fire.
6. [`artifacts/nestedtemplates/AlertEmail.json`](artifacts/nestedtemplates/AlertEmail.json) — action group and three log search alerts using the modern `scheduledQueryRules` 2023-03-15-preview API

---

## Deploy to Azure (portal)

If you would rather deploy from the portal, the buttons below open the wrapper templates from this fork. They install the same managed-identity / Windows B1 configuration as `deploy.ps1` (minus the function code zip and Logic Apps — run those separately or use `deploy.ps1`).

### Global Azure

[![Deploy to Azure](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg?sanitize=true)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FGHogbin%2Fstartstopv2-deployments%2Fmain%2Fartifacts%2Fssv2autoupdate.json)

### Azure US Government (Fairfax)

[![Deploy to Azure](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg?sanitize=true)](https://portal.azure.us/?microsoft_azure_marketplace_itemhidekey=cuidCustomDeployment#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FGHogbin%2Fstartstopv2-deployments%2Fmain%2Fartifacts%2Fssv2autoupdateff.json)

> The Premium availability-zone variants (`ssv2autoupdateAz.json` / `ssv2autoupdateffAz.json`) are still present in `artifacts/` but only carry the managed-identity changes — they are not recommended unless you specifically need an Elastic Premium plan.

---

## Post-deployment

### Enable the Logic App schedulers

The Logic Apps are deployed in **Disabled** state with `targetResourceGroups` set to a placeholder. For each `ststv2_vms_*` workflow:

1. Open the workflow in the portal.
2. Update the `targetResourceGroups` parameter (or the action body) to list the resource groups containing the VMs you want to manage.
3. Adjust the schedule (default times are Pacific 06:00 / 18:30, AutoStop every 8h).
4. Enable the workflow.

### Changing start / stop times

The five Logic Apps deployed by [`LogicApps.json`](artifacts/nestedtemplates/LogicApps.json) drive when VMs start and stop. The defaults are:

| Logic App | Default schedule | Action |
| --- | --- | --- |
| `ststv2_vms_Scheduled_start` | Daily 06:00 | Start VMs in `targetResourceGroups` |
| `ststv2_vms_Scheduled_stop` | Daily 18:30 | Stop VMs in `targetResourceGroups` |
| `ststv2_vms_Sequenced_start` | Daily 06:00 | Start VMs honouring sequence tags |
| `ststv2_vms_Sequenced_stop` | Daily 18:30 | Stop VMs honouring sequence tags |
| `ststv2_vms_AutoStop` | Every 8 hours | Evaluate auto-stop alert rules |

The time zone for all schedules defaults to `Pacific Standard Time`.

#### Option 1 — change in the portal (per workflow)

1. Open the Logic App, select **Logic app designer**.
2. Click the **Recurrence** trigger.
3. Edit **Frequency**, **Interval**, **Time zone**, **At these hours**, and **At these minutes**.
4. **Save**.

#### Option 2 — change in code view (raw JSON)

In **Logic app code view**, edit the `triggers.Recurrence.recurrence` block:

```json
"Recurrence": {
  "type": "Recurrence",
  "recurrence": {
    "frequency": "Day",
    "interval": 1,
    "schedule": { "hours": ["7"], "minutes": [30] },
    "timeZone": "GMT Standard Time"
  }
}
```

- `frequency`: `Minute`, `Hour`, `Day`, `Week`, `Month`
- `interval`: integer count of `frequency` units between runs (e.g. `interval: 8` + `frequency: Hour` = every 8 hours, as used by `ststv2_vms_AutoStop`)
- `schedule.hours`: array of 0–23 (24-hour clock)
- `schedule.minutes`: array of 0–59
- `schedule.weekDays`: optional array, e.g. `["Monday","Tuesday","Wednesday","Thursday","Friday"]` to skip weekends
- `timeZone`: any Windows time-zone ID (`Get-TimeZone -ListAvailable | Select Id`), e.g. `Pacific Standard Time`, `GMT Standard Time`, `W. Europe Standard Time`, `Eastern Standard Time`, `AUS Eastern Standard Time`

Example — weekdays only, start 07:30 London time:

```json
"recurrence": {
  "frequency": "Week",
  "interval": 1,
  "schedule": {
    "weekDays": ["Monday","Tuesday","Wednesday","Thursday","Friday"],
    "hours": ["7"],
    "minutes": [30]
  },
  "timeZone": "GMT Standard Time"
}
```

#### Option 3 — change defaults for everyone (template)

Edit [`artifacts/nestedtemplates/LogicApps.json`](artifacts/nestedtemplates/LogicApps.json) directly and re-deploy. Each workflow has its own `triggers.Recurrence.recurrence` block. To change the default time zone for all five at once, override the `scheduleTimeZone` parameter when re-running `deploy.ps1`, or edit its default value in the template.

```powershell
az deployment group create `
    --resource-group rg-startstop-v2 `
    --template-file artifacts/nestedtemplates/LogicApps.json `
    --parameters functionAppName=<functionAppName> `
                 scheduleTimeZone="GMT Standard Time" `
                 logicAppState=Enabled `
                 targetResourceGroups='["/subscriptions/<sub>/resourceGroups/<rg>"]'
```

> Re-deploying the template **overwrites** any changes made in the portal. Treat the template as the source of truth, or stop re-deploying once you've configured per-workflow.

#### Option 4 — disable a schedule entirely

If you only need start (or only need stop), open the unwanted Logic App and set its state to **Disabled**, or remove that resource block from `LogicApps.json` before re-deploying.

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

## Optional extensions

These templates are independent of the core StartStopV2 deployment — you can deploy them on top of an existing installation without redeploying the Function App.

### Cost & Savings workbook

[`artifacts/nestedtemplates/CostSavingsWorkbook.json`](artifacts/nestedtemplates/CostSavingsWorkbook.json) deploys an Azure Monitor Workbook ("StartStopV2 Cost & Savings") pinned to the existing Application Insights instance. It surfaces data the built-in `StartStopV2_Dashboard` does not show.

Sections:

1. **Actual VM cost** — daily trend and top-N table from Azure Cost Management.
2. **Start/Stop activity** — `VmExecutionsAttempted` from Application Insights.
3. **Modeled savings** — `NoPiiVirtualMachineResponsibleSavings` / `NoPiiVirtualMachineResponsibleDownTime`. *These populate only if you mirror the centralized `NoPii*` telemetry to your local App Insights — by default it ships to a Microsoft-owned sink. See [`CentralizedAppInsightsLogger.cs`](decompiled/StartStopAzureFunctions.Logging/CentralizedAppInsightsLogger.cs) in the decompiled source.*
4. **VM inventory** — Resource Graph query showing VMs and power state in the selected scope.

Deploy:

```powershell
az deployment group create `
    --resource-group rg-startstop-v2 `
    --template-file artifacts/nestedtemplates/CostSavingsWorkbook.json `
    --parameters applicationInsightsName=<applicationInsightsName>
```

Open afterwards from **Azure Monitor → Workbooks** (or the resource group).

### VMSS schedulers (`LogicApps.Vmss.json`)

[`artifacts/nestedtemplates/LogicApps.Vmss.json`](artifacts/nestedtemplates/LogicApps.Vmss.json) deploys three tag-driven Logic Apps that start and stop **Virtual Machine Scale Sets** (`Microsoft.Compute/virtualMachineScaleSets`). They do **not** use the StartStopV2 Function App — each workflow queries Azure Resource Graph and calls the VMSS REST API directly using its own system-assigned managed identity.

| Workflow | Default trigger | Acts on VMSS tagged | Action |
| --- | --- | --- | --- |
| `ststv2_vmss_Scheduled_start` | Daily 07:00 (configurable time zone) | `StartStopV2_VMSS = start` or `both` | `…/virtualMachineScaleSets/{n}/start` |
| `ststv2_vmss_Scheduled_stop`  | Daily 19:00 | `StartStopV2_VMSS = stop` or `both` | `…/virtualMachineScaleSets/{n}/deallocate` |
| `ststv2_vmss_AutoStop`        | Every 15 minutes | `StartStopV2_VMSS = autostop` | `…/virtualMachineScaleSets/{n}/deallocate` |

All three are deployed **Disabled** and grant their managed identity the `Virtual Machine Contributor` role on the **current resource group only**. If your VMSS live elsewhere, add scope-appropriate role assignments before enabling.

Deploy:

```powershell
az deployment group create `
    --resource-group rg-startstop-v2 `
    --template-file artifacts/nestedtemplates/LogicApps.Vmss.json
```

Key parameters (see template for full list):

| Parameter | Default | Notes |
| --- | --- | --- |
| `scheduleTimeZone` | `GMT Standard Time` | Windows time-zone ID. |
| `startSchedule` / `stopSchedule` | 07:00 / 19:00 | Recurrence schedule objects (`hours` / `minutes` / `weekDays`). |
| `autoStopRecurrenceMinutes` | `15` | How often the AutoStop workflow scans. |
| `targetSubscriptionIds` | Current subscription | Resource Graph search scope. |
| `targetResourceGroups` | `[]` (all RGs in scope) | Optional array of RG **names** to restrict the search to (case-insensitive). Equivalent to `targetResourceGroups` on the VM Logic Apps. Example: `[ "rg-prod-vmss", "rg-dev-vmss" ]`. |
| `tagName` | `StartStopV2_VMSS` | Tag key on VMSS that opts them in. |
| `assignRbac` | `true` | If false, no role assignments are created — grant the workflow MIs `Virtual Machine Contributor` manually at the right scope. |
| `logicAppState` | `Disabled` | Set to `Enabled` once tested. |

Usage after deployment:

```powershell
# 1. Tag a non-prod VMSS
az tag update --operation Merge `
    --resource-id <vmss-resource-id> `
    --tags StartStopV2_VMSS=autostop

# 2. (If outside rg-startstop-v2) grant the workflow MI access
$mi = az logic workflow show -g rg-startstop-v2 -n ststv2_vmss_AutoStop --query identity.principalId -o tsv
az role assignment create `
    --assignee-object-id $mi --assignee-principal-type ServicePrincipal `
    --role "Virtual Machine Contributor" `
    --scope <target-rg-resource-id>

# 3. Trigger once for testing
az rest --method post `
    --uri "https://management.azure.com/subscriptions/<sub>/resourceGroups/rg-startstop-v2/providers/Microsoft.Logic/workflows/ststv2_vmss_AutoStop/triggers/Recurrence/run?api-version=2019-05-01"

# 4. Enable when satisfied
az resource update -g rg-startstop-v2 -n ststv2_vmss_AutoStop `
    --resource-type Microsoft.Logic/workflows --set properties.state=Enabled
```

> Telemetry: VMSS workflows do not write to `customMetrics` like the VM functions do. Audit trail is available in the Logic App run history and in the Activity Log entries for the start/deallocate operations.

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
| Function App plan | Consumption Y1 (Windows) | Windows B1 Basic, .NET 8 isolated worker |
| Storage account | Shared keys allowed | `allowSharedKeyAccess: false` enforced |
| Storage auth (host) | `AzureWebJobsStorage` connection string | `AzureWebJobsStorage__accountName` + system-assigned MI |
| Storage auth (function code) | Connection strings in `QueueClient` / `TableServiceClient` | `DefaultAzureCredential` against `https://<account>.queue/table.core.windows.net` (rebuilt `StartStopAzureFunctions.dll`) |
| RBAC | None | Storage Blob Data Owner + Queue/Table Data Contributor + File Data Privileged Contributor on the storage account, granted to the Function App MI |
| Alerts | `microsoft.insights/scheduledQueryRules` 2018-04-16 | `Microsoft.Insights/scheduledQueryRules` 2023-03-15-preview (Common Alert Schema) |
| Schedulers | Created in Function App settings via marketplace UI | Separate `LogicApps.json` template, plus optional `LogicApps.Vmss.json` for VM Scale Sets |
| Reporting | `StartStopV2_Dashboard` (operational only) | Plus optional `CostSavingsWorkbook.json` (Cost Management + activity + inventory) |
| Function package | Upstream `StartStopV2.zip` | `StartStopV2-MI.zip` shipped in this repo (decompiled, patched, rebuilt) |

---

## Support

This fork is **not supported by Microsoft**. For issues with the underlying Start/Stop V2 solution, see the upstream repo: https://github.com/microsoft/startstopv2-deployments. For issues specific to changes in this fork, open an issue at https://github.com/GHogbin/startstopv2-deployments/issues.

---

## License

This project inherits the MIT license from the upstream repository. See [`LICENSE`](LICENSE) and [`LICENSE-CODE`](LICENSE-CODE).
