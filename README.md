# UiPath Platform – Azure App Service Deployment

Scripts for deploying and updating the full **UiPath platform** (Orchestrator, Identity Server, Resource Catalog, Webhooks) to **Azure App Service**.

Supports:
- **Kudu ZIP deploy** — HTTPS-only, no `msdeploy.exe` required (ideal for restricted networks)
- **MsDeploy** — Web Deploy V3 via HTTPS (default)
- **FTP and FTPS** — for file uploads where needed
- **Interactive Azure login** — browser or device-code prompt, no service principal required
- **Checkpoint / resume** — failed runs pick up from the last successful step
- **Pre-deployment backup** — all Azure App Settings and the live `UiPath.Orchestrator.dll.config` (including `EncryptionKey` and `MachineKey`) are saved before any changes are made

> **Recommended:** Use **`Publish-UiPath.ps1`** to deploy or update all four services in a single run.
> The individual `Publish-*.ps1` scripts remain available for targeted single-service operations.

---

## Folder structure

```
UipathAzure\
├── Publish-UiPath.ps1                   # All-in-one combined deploy/update script (recommended)
├── Publish-Orchestrator.ps1             # Orchestrator only
├── Publish-IdentityServer.ps1           # Identity Server only
├── Publish-ResourceCatalog.ps1          # Resource Catalog Service only
├── Publish-Webhooks.ps1                 # Webhook Service only
├── MigrateTo-IdentityServer.ps1         # Standalone Identity Server post-deploy migration
├── MigrateTo-ResourceCatalog.ps1        # Standalone Resource Catalog post-deploy migration
├── MigrateTo-Webhooks.ps1               # Standalone Webhooks post-deploy migration
│
├── UiPath.Orchestrator.dll.config       # Baseline config template (embedded/auto-generated)
├── UiPath.ConfigProtector.exe           # Credential encryption utility
│
├── Publish-Orchestrator.zip             # Orchestrator Web Deploy package
├── UiPath.IdentityServer.Web.zip        # Identity Server web package
├── UiPath.IdentityServer.Migrator.Cli.zip      # Identity Server migration CLI
├── UiPath.ResourceCatalogService-Win64.zip     # Resource Catalog web package
├── UiPath.ResourceCatalogService.CLI-Win64.zip # Resource Catalog migration CLI
├── UiPath.WebhookService.Web.zip               # Webhooks web package
├── UiPath.WebhookService.Migrator.Cli.zip      # Webhooks migration CLI
├── UiPathActivities.zip                 # Activities package (optional composite deploy)
│
├── backups\                             # Auto-created pre-deployment backups (one sub-folder per run)
│   └── my-orchestrator-20260409-143022\
│       ├── Orchestrator-AppSettings.json
│       ├── Orchestrator-dll.config
│       ├── IdentityServer-AppSettings.json
│       ├── ResourceCatalog-AppSettings.json
│       ├── Webhooks-AppSettings.json
│       └── CriticalKeys-Summary.json    # Consolidated encryption key inventory
│
└── ps_utils\                            # Shared helper modules (auto-imported)
    ├── AzureDeployUtils.ps1
    ├── IdentityDeployUtils.ps1
    ├── MsDeployUtils.ps1
    ├── MiscUtils.ps1
    ├── ZipUtils.ps1
    ├── Migrate-Packages.psm1
    ├── OrchestratorSettingsUtils.ps1
    ├── WebhooksDeployUtils.ps1
    └── Platform.Configuration.Tool.ps1
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| **PowerShell 5.1 or 7+** | Run as Administrator for module installation |
| **Az PowerShell module ≥ 6.0.0** | Installed automatically if missing |
| **Azure account** | Contributor rights on the target App Service(s) |
| **SQL Server** reachable from the App Service | Connection string in the publish profile |
| **msdeploy.exe** *(MsDeploy method only)* | `%ProgramFiles(x86)%\IIS\Microsoft Web Deploy V3\msdeploy.exe` |

> **No FTP/FTPS required for config files.** All three config variants are auto-generated from the built-in template. Use `-deployMethod KuduZipDeploy` to eliminate `msdeploy.exe` entirely.

---

## Azure sign-in

The scripts use **interactive Azure login** — no service principal credentials needed.

```powershell
# Optional: sign in before running so the script skips the prompt
Connect-AzAccount

# Azure US Government cloud
Connect-AzAccount -Environment AzureUSGovernment
```

If you are already signed in within the same PowerShell session the scripts detect the existing context and skip re-authentication.

For restricted environments without a browser:
```powershell
Connect-AzAccount -UseDeviceAuthentication
```

---

## Publish-UiPath.ps1 — All-in-one deployment

### Fresh deployment (all services)

```powershell
cd "C:\Users\Kenneth.Braun\Documents\UipathAzure"

.\Publish-UiPath.ps1 `
    -action                           Deploy `
    -deployMethod                     KuduZipDeploy `
    -orchPackage                      ".\Publish-Orchestrator.zip" `
    -orchResourceGroupName            "my-rg" `
    -orchAppServiceName               "my-orchestrator" `
    -identityPackage                  ".\UiPath.IdentityServer.Web.zip" `
    -identityCliPackage               ".\UiPath.IdentityServer.Migrator.Cli.zip" `
    -identityResourceGroupName        "my-rg" `
    -identityAppServiceName           "my-identity" `
    -identityServerUrl                "https://my-identity.azurewebsites.net/identity" `
    -hostAdminPassword                "Str0ngP@ssw0rd!" `
    -defaultTenantAdminPassword       "Str0ngP@ssw0rd!" `
    -resourceCatalogPackage           ".\UiPath.ResourceCatalogService-Win64.zip" `
    -resourceCatalogCliPackage        ".\UiPath.ResourceCatalogService.CLI-Win64.zip" `
    -resourceCatalogResourceGroupName "my-rg" `
    -resourceCatalogAppServiceName    "my-resourcecatalog" `
    -resourceCatalogUrl               "https://my-resourcecatalog.azurewebsites.net" `
    -webhooksPackage                  ".\UiPath.WebhookService.Web.zip" `
    -webhooksCliPackage               ".\UiPath.WebhookService.Migrator.Cli.zip" `
    -webhooksResourceGroupName        "my-rg" `
    -webhooksAppServiceName           "my-webhooks"
```

> Supplying `-identityCliPackage`, `-webhooksCliPackage`, and `-resourceCatalogCliPackage` on a Deploy action automatically runs post-deploy migrations — OAuth client seeding, data import, connection string wiring, and Orchestrator App Settings updates.

### Update all services

On Update the script auto-detects companion URLs from the live Orchestrator App Settings:
- `IdentityServer.Integration.Authority` → Identity Server URL
- `ResourceCatalogService.ServiceURL` → Resource Catalog URL
- `ResourceCatalogService.Integration.Enabled` = `false` → skip RC
- `Webhooks.LedgerIntegration.Enabled` = `false` → skip Webhooks

```powershell
.\Publish-UiPath.ps1 `
    -action                           Update `
    -orchPackage                      ".\Publish-Orchestrator.zip" `
    -orchResourceGroupName            "my-rg" `
    -orchAppServiceName               "my-orchestrator" `
    -identityPackage                  ".\UiPath.IdentityServer.Web.zip" `
    -identityCliPackage               ".\UiPath.IdentityServer.Migrator.Cli.zip" `
    -identityResourceGroupName        "my-rg" `
    -identityAppServiceName           "my-identity" `
    -resourceCatalogPackage           ".\UiPath.ResourceCatalogService-Win64.zip" `
    -resourceCatalogResourceGroupName "my-rg" `
    -resourceCatalogAppServiceName    "my-resourcecatalog" `
    -webhooksPackage                  ".\UiPath.WebhookService.Web.zip" `
    -webhooksResourceGroupName        "my-rg" `
    -webhooksAppServiceName           "my-webhooks" `
    -confirmBlockClassicExecutions
```

> `-confirmBlockClassicExecutions` is **required** for Update. It confirms that jobs in classic folders will be blocked during the upgrade window.

### Orchestrator only (skip companion services)

Omit the companion package parameters to deploy only Orchestrator:

```powershell
.\Publish-UiPath.ps1 `
    -action                Deploy `
    -orchPackage           ".\Publish-Orchestrator.zip" `
    -orchResourceGroupName "my-rg" `
    -orchAppServiceName    "my-orchestrator"
```

### Blue/green hot-swap (standby slot)

```powershell
.\Publish-UiPath.ps1 `
    -action                Deploy `
    -orchPackage           ".\Publish-Orchestrator.zip" `
    -orchResourceGroupName "my-rg" `
    -orchAppServiceName    "my-orchestrator" `
    -orchStandbySlotName   "staging"
```

### Resume after a failure

If the script fails a `uipath-deployment-checkpoint.json` file is written next to the script. Re-run with the same parameters plus `-resume` to skip already-completed steps:

```powershell
.\Publish-UiPath.ps1 `
    -action                     Deploy `
    -orchPackage                ".\Publish-Orchestrator.zip" `
    -orchResourceGroupName      "my-rg" `
    -orchAppServiceName         "my-orchestrator" `
    -identityPackage            ".\UiPath.IdentityServer.Web.zip" `
    -identityCliPackage         ".\UiPath.IdentityServer.Migrator.Cli.zip" `
    -identityResourceGroupName  "my-rg" `
    -identityAppServiceName     "my-identity" `
    -identityServerUrl          "https://my-identity.azurewebsites.net/identity" `
    -hostAdminPassword          "Str0ngP@ssw0rd!" `
    -defaultTenantAdminPassword "Str0ngP@ssw0rd!" `
    -resume
```

---

## Publish-UiPath.ps1 — Parameter reference

### Action & deployment method

| Parameter | Default | Description |
|---|---|---|
| `-action` | `Deploy` | `Deploy` (fresh install) or `Update` (upgrade existing) |
| `-deployMethod` | `MsDeploy` | `MsDeploy` — requires msdeploy.exe; `KuduZipDeploy` — HTTPS only, no msdeploy.exe |
| `-resume` | switch | Resume from last successful checkpoint step |
| `-unattended` | switch | Skip all interactive prompts (CI/CD) |
| `-stopApplicationBeforePublish` | switch | Stop the App Service before deploying, restart after |
| `-azureUSGovernmentLogin` | switch | Sign in to Azure US Government cloud |
| `-backupOutputPath` | *(auto)* | Override the backup folder path. Default: `.\backups\<orchAppServiceName>-<yyyyMMdd-HHmmss>` |
| `-skipBackup` | switch | Skip the pre-deployment backup entirely. **Not recommended for upgrades.** |

### Orchestrator (required)

| Parameter | Description |
|---|---|
| `-orchPackage` | Path to Orchestrator Web Deploy `.zip` |
| `-orchResourceGroupName` | Azure resource group |
| `-orchAppServiceName` | App Service name |
| `-orchStandbySlotName` | Deployment slot for blue/green swap (optional) |
| `-orchConnectionString` | SQL connection string override |
| `-orchTestAutomationConnectionString` | Test Automation DB connection string |
| `-orchUpdateServerConnectionString` | Update Server DB connection string |
| `-orchInsightsConnectionString` | Insights DB connection string |
| `-storageType` | `FileSystem`, `Azure`, `Minio`, or `Amazon` |
| `-storageLocation` | Storage path or connection string |
| `-redisConnectionString` | Redis for load-balanced deployments |
| `-robotsElasticSearchUrl` | Robot log Elasticsearch URL |
| `-serverElasticSearchUrl` | Server diagnostics Elasticsearch URL |
| `-azureSignalRConnectionString` | Azure SignalR connection string |
| `-bucketsAvailableProviders` | Comma-separated bucket providers |
| `-bucketsFileSystemAllowlist` | Required when FileSystem is in providers |
| `-activitiesPackagePath` | Activities `.zip` for composite-mode deploy |
| `-orchAppSettings` | Additional Azure App Settings hashtable |
| `-confirmBlockClassicExecutions` | Required for Update — accepts classic folder blocking |
| `-testAutomationFeatureEnabled` | Enable Test Automation DB migrations |
| `-updateServerFeatureEnabled` | Enable Update Server DB migrations |
| `-insightsFeatureEnabled` | Enable Insights DB migrations |

### Identity Server (optional — omit `-identityPackage` to skip)

| Parameter | Description |
|---|---|
| `-identityPackage` | Path to `UiPath.IdentityServer.Web.zip` |
| `-identityCliPackage` | Path to `UiPath.IdentityServer.Migrator.Cli.zip` (required with `-identityPackage`) |
| `-identityResourceGroupName` | Azure resource group |
| `-identityAppServiceName` | App Service name |
| `-identityServerUrl` | Public URL of Identity Server including `/identity` path (required for Deploy) |
| `-orchestratorUrl` | Public URL of Orchestrator (auto-detected if omitted) |

### Resource Catalog (optional — omit `-resourceCatalogPackage` to skip)

| Parameter | Description |
|---|---|
| `-resourceCatalogPackage` | Path to `UiPath.ResourceCatalogService-Win64.zip` |
| `-resourceCatalogCliPackage` | Path to `UiPath.ResourceCatalogService.CLI-Win64.zip` (Deploy migration) |
| `-resourceCatalogResourceGroupName` | Azure resource group |
| `-resourceCatalogAppServiceName` | App Service name |
| `-resourceCatalogUrl` | Public URL of Resource Catalog (required for Deploy; auto-detected for Update) |

### Webhooks (optional — omit `-webhooksPackage` to skip)

| Parameter | Description |
|---|---|
| `-webhooksPackage` | Path to `UiPath.WebhookService.Web.zip` |
| `-webhooksCliPackage` | Path to `UiPath.WebhookService.Migrator.Cli.zip` (Deploy migration) |
| `-webhooksResourceGroupName` | Azure resource group |
| `-webhooksAppServiceName` | App Service name |

### Migration parameters (Deploy action only)

| Parameter | Description |
|---|---|
| `-hostAdminPassword` | Host admin password — min 8 chars, must include digit + lowercase letter |
| `-defaultTenantAdminPassword` | Default tenant admin password (same rules) |
| `-isHostPassOnetime` | Force host admin to change password on first login |
| `-isDefaultTenantPassOneTime` | Force default tenant admin to change password on first login |

---

## Pre-deployment backup

`Publish-UiPath.ps1` automatically runs a backup as **Step 4** — after Azure authentication and constant initialisation but **before any package deployments, database migrations, or App Settings writes**.  Every run that could modify the platform creates a timestamped snapshot so you always have a reliable recovery reference.

### Why this matters

The `EncryptionKey` stored in `UiPath.Orchestrator.dll.config` (`<secureAppSettings>`) and echoed into the Identity Server App Settings is used to encrypt sensitive data in the Orchestrator database (credentials, queues, assets). If it is lost or overwritten during an upgrade, encrypted values in the database become permanently unreadable. The same applies to the `MachineKey` (`decryptionKey` / `validationKey`) used for ASP.NET forms authentication and anti-forgery tokens.

### What is saved

| File | Contents |
|---|---|
| `Orchestrator-AppSettings.json` | All Azure App Settings from the Orchestrator App Service |
| `Orchestrator-dll.config` | Live `UiPath.Orchestrator.dll.config` downloaded from wwwroot via Kudu VFS — contains `EncryptionKey` in `<secureAppSettings>` and `MachineKey` values |
| `IdentityServer-AppSettings.json` | All Azure App Settings from Identity Server — contains `EncryptionSettings__EncryptionKey` and `AppSettings__DatabaseProtectionSettings__EncryptionKey2021` |
| `ResourceCatalog-AppSettings.json` | All Azure App Settings from Resource Catalog *(when deployed)* |
| `Webhooks-AppSettings.json` | All Azure App Settings from Webhooks *(when deployed)* |
| `CriticalKeys-Summary.json` | **Consolidated inventory** of every encryption-sensitive setting across all services and the dll.config. This is the single file to check if something goes wrong. |

### Encryption key inventory (CriticalKeys-Summary.json)

The summary file collects all settings whose name matches `encrypt` or `DatabaseProtection` from every service backup, plus the `EncryptionKey` and `MachineKey` values from the downloaded `Orchestrator-dll.config`. A masked version is also printed to the console during the run for immediate visual verification:

```
Encryption key inventory (values masked for display):
Service                        Key                                                          Value(masked)
----------------------------------------------------------------------------------------------------
Orchestrator-DllConfig         EncryptionKey                                                AbCd****wxYz
Orchestrator-DllConfig         MachineKey.decryption                                        AES
Orchestrator-DllConfig         MachineKey.decryptionKey                                     1A2B****9Z0Y
Orchestrator-DllConfig         MachineKey.validationKey                                     3C4D****7X8W
IdentityServer                 EncryptionSettings__EncryptionKey                            qRsT****mNoP
IdentityServer                 AppSettings__DatabaseProtectionSettings__EncryptionKey2021   uVwX****iJkL
```

### Backup folder location

By default the backup is written to a timestamped sub-folder next to the script:

```
.\backups\<orchAppServiceName>-<yyyyMMdd-HHmmss>\
```

To use a custom location:

```powershell
.\Publish-UiPath.ps1 `
    -action Deploy `
    -orchPackage           ".\Publish-Orchestrator.zip" `
    -orchResourceGroupName "my-rg" `
    -orchAppServiceName    "my-orchestrator" `
    -backupOutputPath      "D:\UiPath-Backups\pre-upgrade-2026-04-09"
```

### Skipping the backup (not recommended)

```powershell
.\Publish-UiPath.ps1 `
    -action Deploy `
    -orchPackage           ".\Publish-Orchestrator.zip" `
    -orchResourceGroupName "my-rg" `
    -orchAppServiceName    "my-orchestrator" `
    -skipBackup
```

> **Warning:** If you skip the backup and the upgrade overwrites or loses an encryption key, there is no automated recovery path. Only skip in CI/CD pipelines where you have an independent backup strategy in place.

### Recovering encryption keys from a backup

If an upgrade corrupts or overwrites an encryption key, locate the most recent backup folder and use the values in `CriticalKeys-Summary.json` to restore:

**Orchestrator EncryptionKey** — lives in `<secureAppSettings>` in `UiPath.Orchestrator.dll.config` on the App Service wwwroot. Use the Kudu console to overwrite the file or update the value via the Azure portal if the key has been promoted to an App Setting.

**Identity Server EncryptionKey** — restore `EncryptionSettings__EncryptionKey` and `AppSettings__DatabaseProtectionSettings__EncryptionKey2021` in the Identity Server App Settings via the Azure portal or:

```powershell
$rg  = "my-rg"
$svc = "my-identity"
$app = Get-AzWebApp -ResourceGroupName $rg -Name $svc
$s   = @{}; $app.SiteConfig.AppSettings | ForEach-Object { $s[$_.Name] = $_.Value }
$s["EncryptionSettings__EncryptionKey"]                                    = "<value from CriticalKeys-Summary.json>"
$s["AppSettings__DatabaseProtectionSettings__EncryptionKey2021"]           = "<value from CriticalKeys-Summary.json>"
Set-AzWebApp -AppSettings $s -ResourceGroupName $rg -Name $svc | Out-Null
```

**MachineKey** — restore `decryptionKey` and `validationKey` in `UiPath.Orchestrator.dll.config` under `<system.web><machineKey .../>`. These values are also captured in the `Orchestrator-dll.config` backup file.

> Keep backup folders in a **secure location**. They contain plain-text encryption keys and database connection strings with credentials.

---

## Deployment methods compared

| | MsDeploy (default) | KuduZipDeploy |
|---|---|---|
| Requires `msdeploy.exe` | **Yes** — Web Deploy V3 | No |
| Requires FTP/FTPS | No | No |
| Protocol | HTTPS (Web Deploy) | HTTPS (Kudu REST API) |
| WD parameter substitution | Via msdeploy `-setParam` flags | Applied directly to config XML before upload |
| Best for | On-prem build agents with IIS tools | Restricted networks / agents without IIS tools |

---

## What the migration steps do

### Identity Server (Deploy only)

| Step | What it does |
|---|---|
| `Identity_RunDataMigrate` | Migrates existing users/tenants from Orchestrator DB → Identity DB (`migrate`) |
| `Identity_RunDataMigrator` | Runs the 21.4 data migration with admin passwords (`migrate-21-4`) — also runs on Update |
| `Identity_RunSeedMigrator` | Seeds OAuth clients; outputs `clients_config.json` — also runs on Update |
| `Identity_UpdateOrchSettings` | Reads `clients_config.json` and writes all `IdentityServer.Integration.*`, `ExternalAuth.*`, `MultiTenancy.*` settings to Orchestrator App Settings |

### Webhooks (Deploy only, requires `-webhooksCliPackage`)

| Step | What it does |
|---|---|
| `Webhooks_InitCli` | Extracts `WebhookService.Migrate.Cli.exe` from the CLI zip |
| `Webhooks_RunSettingsMigrator` | Runs the CLI against the Orchestrator config to generate `appsettings.azure.json` |
| `Webhooks_UploadAppSettings` | Uploads `appsettings.azure.json` to the Webhooks App Service via FTP/FTPS |
| `Webhooks_UpdateSettings` | Sets SQL connection strings on Webhooks, sets `Webhooks.LedgerIntegration.Enabled = true` on Orchestrator, restarts Webhooks |

### Resource Catalog (Deploy only, requires `-resourceCatalogCliPackage`)

| Step | What it does |
|---|---|
| `ResourceCatalog_InitCli` | Extracts `UiPath.ResourceCatalogService.CLI.exe` from the CLI zip |
| `ResourceCatalog_ImportData` | Runs CLI `--import-data` to seed the catalog database |
| `ResourceCatalog_UpdateSettings` | Sets Ledger config, S2S/JWT/Delegation identity authority, and Orchestrator base URL on RC; enables RC integration on Orchestrator |
| `ResourceCatalog_SetCORS` | Sets CORS policy on RC to allow requests from the Identity Server origin |
| `ResourceCatalog_RestartApps` | Restarts RC then Orchestrator to activate all new settings |

---

## How config files are generated

No FTP download of config files is needed. The scripts embed the full Orchestrator config XML template and auto-generate all three variants at runtime:

| File | Used by |
|---|---|
| `UiPath.Orchestrator.dll.config` | .NET Core host |
| `UiPath.Orchestrator.WebCore.Host.exe.config` | ASP.NET Core host |
| `Web.config` | Classic ASP.NET host |

All three share the same XML body. They are written into a temporary folder and cleaned up automatically on successful completion.

---

## Checkpoint / resume

**`Publish-UiPath.ps1`** writes `uipath-deployment-checkpoint.json` next to the script on any step failure.
**`Publish-Orchestrator.ps1`** writes `deployment-checkpoint.json`.

Each checkpoint contains:
- The list of completed step names (`[DONE]` in the console)
- All computed runtime state (temp paths, encryption keys, storage settings, publish profile paths, etc.)

The file is **deleted automatically** on a successful run. To force a full re-run, delete it manually or run without `-resume`.

---

## Publish-Orchestrator.ps1 — Orchestrator only

Use this script when you only need to deploy or update Orchestrator without touching the companion services.

### Deploy

```powershell
cd "C:\Users\Kenneth.Braun\Documents\UipathAzure"

.\Publish-Orchestrator.ps1 `
    -package            ".\Publish-Orchestrator.zip" `
    -action             Deploy `
    -resourceGroupName  "my-rg" `
    -appServiceName     "my-orchestrator"
```

### Deploy via Kudu (no msdeploy.exe)

```powershell
.\Publish-Orchestrator.ps1 `
    -package            ".\Publish-Orchestrator.zip" `
    -action             Deploy `
    -resourceGroupName  "my-rg" `
    -appServiceName     "my-orchestrator" `
    -deployMethod       KuduZipDeploy
```

### Deploy with blue/green slot swap

```powershell
.\Publish-Orchestrator.ps1 `
    -package            ".\Publish-Orchestrator.zip" `
    -action             Deploy `
    -resourceGroupName  "my-rg" `
    -appServiceName     "my-orchestrator" `
    -standbySlotName    "staging"
```

### Update

```powershell
.\Publish-Orchestrator.ps1 `
    -package            ".\Publish-Orchestrator.zip" `
    -action             Update `
    -resourceGroupName  "my-rg" `
    -appServiceName     "my-orchestrator" `
    -confirmBlockClassicExecutions
```

### Resume after failure

```powershell
.\Publish-Orchestrator.ps1 `
    -package            ".\Publish-Orchestrator.zip" `
    -action             Deploy `
    -resourceGroupName  "my-rg" `
    -appServiceName     "my-orchestrator" `
    -resume
```

---

## Companion scripts (individual service deploy)

| Script | Primary parameters |
|---|---|
| `Publish-IdentityServer.ps1` | `-orchDetails`, `-identityServerDetails`, `-cliPackage` |
| `Publish-ResourceCatalog.ps1` | `-orchDetails`, `-resourceCatalogDetails` |
| `Publish-Webhooks.ps1` | `-orchDetails`, `-webhookDetails` |
| `MigrateTo-IdentityServer.ps1` | `-cliPackage`, `-orchDetails`, `-identityServerDetails`, `-hostAdminPassword`, `-defaultTenantAdminPassword` |
| `MigrateTo-ResourceCatalog.ps1` | `-cliPackage`, `-orchDetails`, `-resourceCatalogDetails`, `-resourceCatalogUrl`, `-identityServerUrl`, `-orchestratorUrl` |
| `MigrateTo-Webhooks.ps1` | `-cliPackage`, `-orchDetails`, `-webhookDetails` |

> These standalone scripts require `-azureDetails` (service principal) or `-noAzureAuthentication`. Use `Publish-UiPath.ps1` instead for interactive login and full automation.

---

## Troubleshooting

**Az module not found**
```powershell
Install-Module Az -RequiredVersion 6.0.0 -Force -AllowClobber
```

**`msdeploy.exe` not found**
Install [Web Deploy 3.6](https://www.iis.net/downloads/microsoft/web-deploy) or switch to `-deployMethod KuduZipDeploy`.

**Interactive login prompt does not appear**
Ensure network access to `login.microsoftonline.com`. In headless environments:
```powershell
Connect-AzAccount -UseDeviceAuthentication
```
Then re-run the script — it will detect the active context and skip re-authentication.

**AzureRM conflict**
The script detects AzureRM and automatically uninstalls it before installing Az. If you prefer to do this manually:
```powershell
Uninstall-AzureRM
Install-Module Az -RequiredVersion 6.0.0 -Force -AllowClobber
```

**Script fails mid-run**
Re-run with `-resume`. The console shows `[SKIP]` for completed steps and `[STEP]` for the step that will re-run from the failure point.

**Stale checkpoint from a different deployment**
```powershell
# Publish-UiPath.ps1 checkpoint
Remove-Item ".\uipath-deployment-checkpoint.json" -Force

# Publish-Orchestrator.ps1 checkpoint
Remove-Item ".\deployment-checkpoint.json" -Force
```
Then run without `-resume`.

**Database pre-validation fails with ClassicFoldersPresent**
If you are intentionally deploying over a site with classic folders, add:
```powershell
-allowInstallOverClassicFolders
```

**Webhooks `appsettings.azure.json` upload fails (FTP blocked)**
The file is generated in the temp folder before upload. If FTP is blocked:
1. Note the temp path shown in the console output
2. Manually upload `appsettings.azure.json` to the Webhooks App Service root via the Kudu console (`https://<app>.scm.azurewebsites.net/DebugConsole`)
3. Re-run with `-resume` — the `Webhooks_UploadAppSettings` step will be skipped and `Webhooks_UpdateSettings` will proceed

**Backup step fails — Kudu VFS download of dll.config returns 404**
The script tries `UiPath.Orchestrator.dll.config` first and then falls back to `Web.config`. If neither exists at the wwwroot root (e.g. a non-standard deployment layout), the App Settings JSON files are still saved. Retrieve the config file manually:
```
https://<orchestrator>.scm.azurewebsites.net/api/vfs/site/wwwroot/UiPath.Orchestrator.dll.config
```
Save it into the backup folder as `Orchestrator-dll.config` and run `Write-CriticalKeysSummary` interactively if needed, or inspect the file directly.

**Backup folder already contains a run for today and you want a fresh one**
The timestamp is `yyyyMMdd-HHmmss` so concurrent or rapid successive runs each get a unique folder. If you use `-backupOutputPath`, point to a new empty folder each time to avoid mixing snapshots.

**EncryptionKey appears empty in CriticalKeys-Summary.json**
The `EncryptionKey` may have been moved to an Azure App Setting (overrides the dll.config value at runtime). Check `Orchestrator-AppSettings.json` in the backup folder for a key named `EncryptionKey`. If it is present there, that is the active value — the dll.config entry is unused and can be ignored.
