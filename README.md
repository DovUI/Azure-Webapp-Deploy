# Azure Orchestrator Deploy

ARM template and interactive PowerShell script for provisioning UiPath Orchestrator infrastructure on Azure.

## What It Creates

Given a prefix (e.g. `orch2026`), the template deploys:

| Resource | Name | SKU |
|----------|------|-----|
| App Service Plan | `<prefix>-asp` | S1 Standard |
| Web App (Orchestrator) | `<prefix>` | &mdash; |
| Web App (Identity Server) | `<prefix>-is` | &mdash; |
| Web App (Webhooks) | `<prefix>-wh` | &mdash; |
| Web App (Resource Catalog) | `<prefix>-rc` | &mdash; |
| SQL Database | `<prefix>db` | S1 Standard (20 DTU) |

The SQL database is created on an **existing** SQL Server that you specify. All web apps run on .NET 6.0 with Always On enabled, HTTPS only, and WebSockets.

## Prerequisites

- [Azure CLI](https://aka.ms/azure-cli) installed and authenticated (`az login`)
- An existing Azure SQL Server to host the new database
- A target resource group

## Usage

```powershell
.\Deploy-OrchResources.ps1
```

The script prompts for:

1. **Resource prefix** &mdash; used to name all resources
2. **Resource group** &mdash; where to deploy (default: `Infra-DovB-RG`)
3. **Region** &mdash; for App Service Plan and web apps (default: `East US`)
4. **SQL Server name** &mdash; existing server to host the database
5. **SQL database region** &mdash; must match the SQL server's region

Before deploying, you can run a **what-if** preview to see exactly what Azure will create or change.

### Direct Template Deployment

You can also deploy the ARM template directly with the Azure CLI:

```bash
az deployment group create \
  --resource-group <resource-group> \
  --template-file orch-template.json \
  --parameters prefix=<prefix> \
               location="East US" \
               sqlServerName=<sql-server-name> \
               sqlDatabaseLocation="East US"
```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `prefix` | Yes | &mdash; | Base name for all resources (2-30 chars) |
| `location` | No | East US | Region for App Service Plan and web apps |
| `sqlServerName` | No | &mdash; | Name of the existing SQL server |
| `sqlDatabaseLocation` | No | East US | Must match the SQL server's region |

## Files

- `Deploy-OrchResources.ps1` &mdash; Interactive deployment script with input validation and what-if support
- `orch-template.json` &mdash; ARM template defining all Azure resources
