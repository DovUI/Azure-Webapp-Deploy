#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys or updates the full UiPath platform to Azure App Service in a single run.

.DESCRIPTION
    Covers Orchestrator, Identity Server, Resource Catalog, and Webhooks.
    Supports MsDeploy and Kudu ZIP deploy (no msdeploy.exe required), FTP and FTPS,
    interactive Azure login, and resume-from-failure via a local checkpoint file.

    UPDATE mode auto-detects companion service URLs from the Orchestrator's Azure
    App Settings:
      IdentityServer.Integration.Authority  -> identityServerUrl
      ResourceCatalogService.ServiceURL     -> resourceCatalogUrl
      ResourceCatalogService.Integration.Enabled (false = skip Resource Catalog)
      Webhooks.LedgerIntegration.Enabled    (false = skip Webhooks)

.PARAMETER orchPackage
    Path to the Orchestrator Web Deploy package (.zip).

.PARAMETER identityPackage
    Path to UiPath.IdentityServer.Web.zip. Omit to skip Identity Server.

.PARAMETER identityCliPackage
    Path to UiPath.IdentityServer.Migrator.Cli.zip. Required when identityPackage is supplied.

.PARAMETER resourceCatalogPackage
    Path to UiPath.ResourceCatalogService-Win64.zip. Omit to skip Resource Catalog.

.PARAMETER webhooksPackage
    Path to UiPath.WebhookService.Web.zip. Omit to skip Webhooks.

.EXAMPLE
    # Fresh deployment of all services
    .\Publish-UiPath.ps1 `
        -action Deploy `
        -orchPackage            ".\Publish-Orchestrator.zip" `
        -orchResourceGroupName  "my-rg" `
        -orchAppServiceName     "my-orchestrator" `
        -identityPackage        ".\UiPath.IdentityServer.Web.zip" `
        -identityCliPackage     ".\UiPath.IdentityServer.Migrator.Cli.zip" `
        -identityResourceGroupName "my-rg" `
        -identityAppServiceName "my-identity" `
        -identityServerUrl      "https://my-identity.azurewebsites.net/identity" `
        -resourceCatalogPackage ".\UiPath.ResourceCatalogService-Win64.zip" `
        -resourceCatalogResourceGroupName "my-rg" `
        -resourceCatalogAppServiceName "my-resourcecatalog" `
        -resourceCatalogUrl     "https://my-resourcecatalog.azurewebsites.net" `
        -webhooksPackage        ".\UiPath.WebhookService.Web.zip" `
        -webhooksResourceGroupName "my-rg" `
        -webhooksAppServiceName "my-webhooks"

.EXAMPLE
    # Update all services (companion URLs auto-detected from Orchestrator app settings)
    .\Publish-UiPath.ps1 `
        -action Update `
        -orchPackage            ".\Publish-Orchestrator.zip" `
        -orchResourceGroupName  "my-rg" `
        -orchAppServiceName     "my-orchestrator" `
        -identityPackage        ".\UiPath.IdentityServer.Web.zip" `
        -identityCliPackage     ".\UiPath.IdentityServer.Migrator.Cli.zip" `
        -identityResourceGroupName "my-rg" `
        -identityAppServiceName "my-identity" `
        -resourceCatalogPackage ".\UiPath.ResourceCatalogService-Win64.zip" `
        -resourceCatalogResourceGroupName "my-rg" `
        -resourceCatalogAppServiceName "my-resourcecatalog" `
        -webhooksPackage        ".\UiPath.WebhookService.Web.zip" `
        -webhooksResourceGroupName "my-rg" `
        -webhooksAppServiceName "my-webhooks" `
        -confirmBlockClassicExecutions

.EXAMPLE
    # Resume after a failure
    .\Publish-UiPath.ps1 -action Update -orchPackage "..." -orchResourceGroupName "..." `
        -orchAppServiceName "..." -identityPackage "..." -identityCliPackage "..." `
        -identityResourceGroupName "..." -identityAppServiceName "..." -resume
#>
param(
    # =========================================================================
    # Action & deployment method
    # =========================================================================
    [ValidateSet("Deploy","Update")]
    [string] $action = "Deploy",

    # MsDeploy  = use msdeploy.exe (requires Web Deploy V3 installed locally).
    # KuduZipDeploy = push via Kudu REST API over HTTPS; no msdeploy.exe needed.
    [ValidateSet("MsDeploy","KuduZipDeploy")]
    [string] $deployMethod = "MsDeploy",

    # Resume a previous run that stopped mid-way.
    [switch] $resume,

    # Suppress all interactive prompts (for CI/CD pipelines).
    [switch] $unattended,

    # Stop each App Service before deploying and restart it afterward.
    [switch] $stopApplicationBeforePublish,

    # Sign in to Azure US Government cloud instead of Azure Commercial.
    [switch] $azureUSGovernmentLogin,

    # Path for the pre-deployment backup folder.
    # Defaults to .\backups\<orchAppServiceName>-<yyyyMMdd-HHmmss> next to this script.
    # All service app settings and the live Orchestrator dll.config are saved here.
    [string] $backupOutputPath,

    # Skip the pre-deployment backup entirely (not recommended for upgrades).
    [switch] $skipBackup,

    # =========================================================================
    # Orchestrator  (always required)
    # =========================================================================
    [Parameter(Mandatory=$true, HelpMessage="Path to Orchestrator Web Deploy package (.zip)")]
    [ValidateScript({ if(-Not($_ | Test-Path -PathType Leaf)){throw "orchPackage not found: $_"} $true })]
    [string] $orchPackage,

    [Parameter(Mandatory=$true)]
    [string] $orchResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string] $orchAppServiceName,

    [string] $orchProductionSlotName = "Production",
    [string] $orchStandbySlotName,

    [string] $orchConnectionString,
    [string] $orchTestAutomationConnectionString,
    [string] $orchUpdateServerConnectionString,
    [string] $orchInsightsConnectionString,

    [string] $storageType,
    [string] $storageLocation,
    [string] $redisConnectionString,
    [string] $loadBalancerUseRedis,

    [string] $robotsElasticSearchUrl,
    [string] $robotsElasticSearchUsername,
    [string] $robotsElasticSearchPassword,
    [string] $robotsElasticSearchTargets,

    [string] $serverElasticSearchUrl,
    [string] $serverElasticSearchIndex,
    [string] $serverDefaultTargets,
    [string] $serverElasticSearchDiagnosticsUsername,
    [string] $serverElasticSearchDiagnosticsPassword,

    [string] $azureSignalRConnectionString,
    [string] $bucketsAvailableProviders,
    [string] $bucketsFileSystemAllowlist,

    [string] $packagesApiKey,
    [string] $activitiesApiKey,

    [System.Object] $orchAppSettings,

    [string[]] $filesToSkip,
    [string[]] $foldersToSkip = @("\\NuGetPackages","\\NuGetPackages\\Activities","\\Storage","\\PackagesMigration"),

    [bool]   $autoSwap = $true,

    [ValidateScript({ if($_ -and -Not($_ | Test-Path -PathType Leaf)){throw "activitiesPackagePath not found: $_"} $true })]
    [string] $activitiesPackagePath,

    [switch] $testAutomationFeatureEnabled,
    [switch] $updateServerFeatureEnabled,
    [switch] $insightsFeatureEnabled,
    [switch] $confirmBlockClassicExecutions,

    [string] $orchestratorRootUrl,
    [string] $orchParametersOutputPath = "$PSScriptRoot\AzurePublishParameters.json",

    [Parameter(Mandatory=$false, DontShow)]
    [switch] $allowInstallOverClassicFolders,

    # =========================================================================
    # Identity Server  (optional -- omit -identityPackage to skip)
    # =========================================================================
    [ValidateScript({ if($_ -and -Not($_ | Test-Path -PathType Leaf)){throw "identityPackage not found: $_"} $true })]
    [string] $identityPackage,

    [ValidateScript({ if($_ -and -Not($_ | Test-Path -PathType Leaf)){throw "identityCliPackage not found: $_"} $true })]
    [string] $identityCliPackage,

    [string] $identityResourceGroupName,
    [string] $identityAppServiceName,
    [string] $identityProductionSlotName = "Production",
    [string] $identitySlotName,

    # Required for Deploy; auto-detected from IdentityServer.Integration.Authority on Update.
    [string] $identityServerUrl,

    # Public Orchestrator URL passed to the Identity seed migrator.
    # Auto-resolved from Azure on Update; required for Deploy if identityPackage is set.
    [string] $orchestratorUrl,

    # =========================================================================
    # Resource Catalog  (optional -- omit -resourceCatalogPackage to skip)
    # =========================================================================
    [ValidateScript({ if($_ -and -Not($_ | Test-Path -PathType Leaf)){throw "resourceCatalogPackage not found: $_"} $true })]
    [string] $resourceCatalogPackage,

    [string] $resourceCatalogResourceGroupName,
    [string] $resourceCatalogAppServiceName,
    [string] $resourceCatalogProductionSlotName = "Production",
    [string] $resourceCatalogSlotName,

    # Required for Deploy; auto-detected from ResourceCatalogService.ServiceURL on Update.
    [string] $resourceCatalogUrl,

    # =========================================================================
    # Webhooks  (optional -- omit -webhooksPackage to skip)
    # =========================================================================
    [ValidateScript({ if($_ -and -Not($_ | Test-Path -PathType Leaf)){throw "webhooksPackage not found: $_"} $true })]
    [string] $webhooksPackage,

    [string] $webhooksResourceGroupName,
    [string] $webhooksAppServiceName,
    [string] $webhooksProductionSlotName = "Production",
    [string] $webhooksSlotName,

    # =========================================================================
    # Migration parameters (Deploy action only)
    # =========================================================================
    # Passwords for Identity Server 21-4 data migrator (required for Deploy with -identityPackage).
    [string] $hostAdminPassword,
    [string] $defaultTenantAdminPassword,
    # Mark passwords as one-time use (users are forced to change them on first login).
    [switch] $isHostPassOnetime,
    [switch] $isDefaultTenantPassOneTime,

    # Path to UiPath.WebhookService.Migrator.Cli.zip -- supply to run Webhooks migration on Deploy.
    [ValidateScript({ if($_ -and -Not($_ | Test-Path -PathType Leaf)){throw "webhooksCliPackage not found: $_"} $true })]
    [string] $webhooksCliPackage,

    # Path to UiPath.ResourceCatalogService.CLI-Win64.zip -- supply to run RC migration on Deploy.
    [ValidateScript({ if($_ -and -Not($_ | Test-Path -PathType Leaf)){throw "resourceCatalogCliPackage not found: $_"} $true })]
    [string] $resourceCatalogCliPackage,

    # =========================================================================
    # Az module versions
    # =========================================================================
    [System.Version] $azModuleVersion         = "6.0.0",
    [System.Version] $azAccountsModuleVersion = "2.3.0",
    [System.Version] $azWebsitesModuleVersion = "2.6.0"
)

$ErrorActionPreference = "Stop"

# Checkpoint file sits next to this script so it survives temp-folder recreation.
$script:checkpointFile = Join-Path $PSScriptRoot "uipath-deployment-checkpoint.json"
$script:completedSteps = @()

$azModuleLocationBaseDir = "C:\Modules\az_$azModuleVersion"
$azModuleLocation        = "$azModuleLocationBaseDir\az\$azModuleVersion\az.psd1"

# ============================================================================
# ps_utils imports
# ============================================================================
try { Add-PSSnapin WDeploySnapin3.0 -ErrorAction SilentlyContinue } catch {}

foreach ($util in @("ZipUtils.ps1","MiscUtils.ps1","MsDeployUtils.ps1",
                    "AzureDeployUtils.ps1","IdentityDeployUtils.ps1")) {
    $utilPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "ps_utils\$util"))
    if (Test-Path $utilPath) {
        Import-Module $utilPath -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# Section: Azure / module helpers
# ============================================================================

function Import-AzModuleFromLocalMachine {
    if (Get-Module AzureRM) { Remove-Module AzureRM }
    Write-Host "Importing Az module from $azModuleLocation"
    $env:PSModulePath = $azModuleLocationBaseDir + ";" + $env:PSModulePath
    $prev = $Global:VerbosePreference; $Global:VerbosePreference = 'SilentlyContinue'
    Import-Module $azModuleLocation -Verbose:$false
    $Global:VerbosePreference = $prev
}

function Ensure-AzureModule {
    if (Get-Module -Name Az.Accounts) { Write-Verbose "Az already loaded."; return }
    if (Test-Path $azModuleLocation) {
        Import-AzModuleFromLocalMachine; return
    }
    $hasAccounts = Get-Module -Name Az.Accounts  -ListAvailable -Verbose:$false | Where-Object { $_.Version -ge $azAccountsModuleVersion }
    $hasWebsites = Get-Module -Name Az.Websites  -ListAvailable -Verbose:$false | Where-Object { $_.Version -ge $azWebsitesModuleVersion }
    if ($hasAccounts -and $hasWebsites) {
        Import-Module Az -Version $azModuleVersion -Verbose:$false
    } else {
        Write-Host "Installing Az module $azModuleVersion ..." -ForegroundColor Yellow
        if (Get-Module -Name AzureRM -ListAvailable) {
            Install-Module Az -RequiredVersion $azModuleVersion -Force -AllowClobber -Verbose:$false
            if (Get-Module AzureRM) { Remove-Module AzureRM }
            Uninstall-AzureRM
        } else {
            Install-Module Az -RequiredVersion $azModuleVersion -Force -AllowClobber -Verbose:$false
        }
        Import-Module Az -Version $azModuleVersion -Verbose:$false
    }
}

function AuthenticateToAzure {
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if ($ctx -and $ctx.Account) {
        Write-Host "Already signed in as $($ctx.Account.Id) -- skipping re-authentication." -ForegroundColor Green
        return
    }
    Write-Host "Connecting to Azure -- browser/device-code prompt will appear ..."
    $result = if ($azureUSGovernmentLogin) { Connect-AzAccount -Environment AzureUSGovernment } else { Connect-AzAccount }
    if ($result) { Write-Host "Logged in as $($result.Context.Account.Id)." -ForegroundColor Green }
    else         { Write-Error "Azure login failed."; Exit 1 }
}

# Download publish profile for a service into $outputPath.
# Uses slot-level API when $slotName is provided, otherwise app-level.
function Get-ServicePublishProfile([string]$resourceGroupName,[string]$appServiceName,[string]$slotName,[string]$outputPath) {
    Write-Verbose "Downloading publish profile for $appServiceName (slot: $slotName)"
    if ($slotName -and $slotName -ne "Production") {
        Get-AzWebAppSlotPublishingProfile -OutputFile $outputPath -ResourceGroupName $resourceGroupName `
            -Name $appServiceName -Slot $slotName | Out-Null
    } else {
        Get-AzWebAppPublishingProfile -OutputFile $outputPath -ResourceGroupName $resourceGroupName `
            -Name $appServiceName | Out-Null
    }
}

# Read a WD publish settings hashtable from a downloaded .PublishSettings file.
function Read-WDPublishSettings([string]$filePath) {
    if (-not (Test-Path $filePath)) { Write-Error "Publish settings not found: $filePath"; Exit 1 }
    [xml]$xml = Get-Content -Path $filePath
    return @{
        SiteName   = $xml.SelectNodes("//publishData//publishProfile[@publishMethod='MSDeploy']/@msdeploySite").Value
        PublishUrl = $xml.SelectNodes("//publishData//publishProfile[@publishMethod='MSDeploy']/@publishUrl").Value
        UserName   = $xml.SelectNodes("//publishData//publishProfile[@publishMethod='MSDeploy']/@userName").Value
        Password   = $xml.SelectNodes("//publishData//publishProfile[@publishMethod='MSDeploy']/@userPWD").Value
    }
}

# Read the FTP publish profile hashtable.
function Read-FtpPublishProfile([string]$filePath) {
    [xml]$xml = New-Object System.Xml.XmlDocument; $xml.Load($filePath)
    return @{
        FtpPublishUrl = $xml.SelectNodes("//publishProfile[@publishMethod='FTP']/@publishUrl").value
        FtpUsername   = $xml.SelectNodes("//publishProfile[@publishMethod='FTP']/@userName").value
        FtpPassword   = $xml.SelectNodes("//publishProfile[@publishMethod='FTP']/@userPWD").value
    }
}

# Read a single named App Setting from an Azure App Service.
function Get-OrchAppSetting([string]$settingName) {
    $app = Get-AzWebApp -ResourceGroupName $orchResourceGroupName -Name $orchAppServiceName -ErrorAction SilentlyContinue
    if (-not $app) { return $null }
    $setting = $app.SiteConfig.AppSettings | Where-Object { $_.Name -eq $settingName }
    if ($setting) { return $setting.Value } else { return $null }
}

# ============================================================================
# Section: Checkpoint helpers
# ============================================================================

function Initialize-Checkpoint {
    if ($resume -and (Test-Path $script:checkpointFile)) {
        Write-Host "`nLoading checkpoint: $script:checkpointFile" -ForegroundColor Cyan
        $saved = [System.IO.File]::ReadAllText($script:checkpointFile) | ConvertFrom-Json
        $script:completedSteps = if ($saved.CompletedSteps) { @($saved.CompletedSteps) } else { @() }
        # Restore script-scope state
        $s = $saved.State
        foreach ($p in $s.PSObject.Properties) { Set-Variable -Name $p.Name -Value $p.Value -Scope Script }
        # Coerce arrays that JSON may have flattened
        foreach ($arr in @('defaultFolderstoSkip','defaultFilesToSkip','completedSteps')) {
            Set-Variable -Name $arr -Value @($(Get-Variable $arr -Scope Script -ValueOnly)) -Scope Script
        }
        Write-Host "Restored. Completed steps: [$($script:completedSteps -join ' > ')]`n" -ForegroundColor Cyan
    } else {
        $script:completedSteps = @()
        if (-not $resume -and (Test-Path $script:checkpointFile)) {
            Remove-Item $script:checkpointFile -Force
        }
    }
}

function Save-Checkpoint {
    $state = @{
        # --- shared temp ---
        tempDirectory                = $script:tempDirectory
        # --- orchestrator ---
        orch_publishSettingsPath     = $script:orch_publishSettingsPath
        orch_webConfigPath           = $script:orch_webConfigPath
        orch_parametersXmlPath       = $script:orch_parametersXmlPath
        orch_newConfigPath           = $script:orch_newConfigPath
        orch_newConfigName           = $script:orch_newConfigName
        orch_webArchiveContentPath   = $script:orch_webArchiveContentPath
        orch_cliToolPath             = $script:orch_cliToolPath
        orch_productionWebConfigPath = $script:orch_productionWebConfigPath
        orch_hotswap                 = $script:orch_hotswap
        orch_deploymentSlotName      = $script:orch_deploymentSlotName
        orch_fullAppServiceName      = $script:orch_fullAppServiceName
        orch_updateProductionDatabase= $script:orch_updateProductionDatabase
        orch_packagesApiKey          = $script:orch_packagesApiKey
        orch_activitiesApiKey        = $script:orch_activitiesApiKey
        orch_storageType             = $script:orch_storageType
        orch_storageLocation         = $script:orch_storageLocation
        orch_runPackageMigrator      = $script:orch_runPackageMigrator
        orch_instanceKey             = $script:orch_instanceKey
        orch_nugetRepositoryType     = $script:orch_nugetRepositoryType
        orch_packagesUrl             = $script:orch_packagesUrl
        orch_activitiesUrl           = $script:orch_activitiesUrl
        orch_decryption              = $script:orch_decryption
        orch_decryptionKey           = $script:orch_decryptionKey
        orch_validation              = $script:orch_validation
        orch_validationKey           = $script:orch_validationKey
        orch_encryptionKey           = $script:orch_encryptionKey
        orch_redisConnectionString   = $script:orch_redisConnectionString
        orch_loadBalancerUseRedis    = $script:orch_loadBalancerUseRedis
        orch_robotsElasticSearchUrl  = $script:orch_robotsElasticSearchUrl
        orch_robotsElasticSearchUsername = $script:orch_robotsElasticSearchUsername
        orch_robotsElasticSearchPassword = $script:orch_robotsElasticSearchPassword
        orch_robotsElasticSearchTargets  = $script:orch_robotsElasticSearchTargets
        orch_serverElasticSearchUrl  = $script:orch_serverElasticSearchUrl
        orch_serverElasticSearchDiagnosticsUsername = $script:orch_serverElasticSearchDiagnosticsUsername
        orch_serverElasticSearchDiagnosticsPassword = $script:orch_serverElasticSearchDiagnosticsPassword
        orch_serverElasticSearchIndex= $script:orch_serverElasticSearchIndex
        orch_serverDefaultTargets    = $script:orch_serverDefaultTargets
        orch_azureSignalRConnectionString = $script:orch_azureSignalRConnectionString
        orch_bucketsFileSystemAllowlist   = $script:orch_bucketsFileSystemAllowlist
        orch_bucketsAvailableProviders    = $script:orch_bucketsAvailableProviders
        orch_deployMethod            = $script:orch_deployMethod
        orch_defaultFolderstoSkip    = $script:orch_defaultFolderstoSkip
        orch_defaultFilesToSkip      = $script:orch_defaultFilesToSkip
        orch_ftpPublishProfile       = $script:orch_ftpPublishProfile
        orch_defaultParameterXmlValues = $script:orch_defaultParameterXmlValues
        orch_existingProdAppSettings = $script:orch_existingProdAppSettings
        orch_msDeployExe             = $script:orch_msDeployExe
        # --- companion service enablement ---
        deployIdentity               = $script:deployIdentity
        deployResourceCatalog        = $script:deployResourceCatalog
        deployWebhooks               = $script:deployWebhooks
        # --- resolved companion URLs ---
        resolvedIdentityServerUrl    = $script:resolvedIdentityServerUrl
        resolvedResourceCatalogUrl   = $script:resolvedResourceCatalogUrl
        resolvedOrchestratorUrl      = $script:resolvedOrchestratorUrl
        # --- identity ---
        identity_tempDirectory       = $script:identity_tempDirectory
        identity_publishSettingsPath = $script:identity_publishSettingsPath
        identity_cliPath             = $script:identity_cliPath
        identity_deploymentSlotName  = $script:identity_deploymentSlotName
        # --- resource catalog ---
        rc_tempDirectory             = $script:rc_tempDirectory
        rc_publishSettingsPath       = $script:rc_publishSettingsPath
        rc_deploymentSlotName        = $script:rc_deploymentSlotName
        # --- webhooks ---
        wh_tempDirectory             = $script:wh_tempDirectory
        wh_publishSettingsPath       = $script:wh_publishSettingsPath
        wh_deploymentSlotName        = $script:wh_deploymentSlotName
        wh_cliPath                   = $script:wh_cliPath
        # --- resource catalog cli ---
        rc_cliPath                   = $script:rc_cliPath
    }
    $json = @{ Version="1.0"; Timestamp=(Get-Date -Format "o"); CompletedSteps=@($script:completedSteps); State=$state } |
        ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($script:checkpointFile, $json, [System.Text.UTF8Encoding]::new($false))
}

function Remove-Checkpoint {
    if (Test-Path $script:checkpointFile) { Remove-Item $script:checkpointFile -Force }
    Write-Host "Deployment checkpoint cleared." -ForegroundColor Green
}

# Returns $true if the step is already done (caller must skip).
# Returns $false if the step must run (caller executes body then calls End-Step).
function Start-Step([string]$stepName) {
    if ($script:completedSteps -contains $stepName) {
        Write-Host "[SKIP ] $stepName" -ForegroundColor Cyan; return $true
    }
    Write-Host "`n[STEP ] $stepName ..." -ForegroundColor Yellow; return $false
}

function End-Step([string]$stepName) {
    $script:completedSteps += $stepName
    Save-Checkpoint
    Write-Host "[DONE ] $stepName" -ForegroundColor Green
}

# ============================================================================
# Section: Baseline config file generator
# ============================================================================

function New-OrchestratorConfigFiles([string]$tempDirectory) {
    Write-Host "Generating baseline Orchestrator config files in '$tempDirectory' ..." -ForegroundColor Yellow
    $templateXml = @'
<configuration>
  <configSections>
    <section name="nlog" type="NLog.Config.ConfigSectionHandler, NLog" />
    <section name="secureAppSettings" type="System.Configuration.AppSettingsSection, System.Configuration, Version=2.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a" />
    <section name="system.web" type="System.Configuration.IgnoreSection, System.Configuration.ConfigurationManager" allowLocation="false" />
  </configSections>
  <connectionStrings>
    <add name="Default"        providerName="Microsoft.Data.SqlClient" connectionString="Server=.\;Database=UiPath;Integrated Security=True;" />
    <add name="TestAutomation" providerName="Microsoft.Data.SqlClient" connectionString="Server=.\;Database=UiPathTestAutomation;Integrated Security=True;" />
    <add name="UpdateServer"   providerName="Microsoft.Data.SqlClient" connectionString="Server=.\;Database=UiPathUpdateServer;Integrated Security=True;" />
  </connectionStrings>
  <nlog xmlns="http://www.nlog-project.org/schemas/NLog.xsd"
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
        autoReload="true" throwExceptions="false" internalLogLevel="Off">
    <extensions>
      <add assembly="UiPath.Orchestrator.Logs.Elasticsearch" />
      <add assembly="UiPath.Orchestrator.Logs.Elasticsearch.NLogTarget" />
      <add assembly="UiPath.Orchestrator.Logs.DatabaseBulk.NLogTarget" />
      <add assembly="UiPath.Orchestrator.Logs.Insights.NLogTarget" />
    </extensions>
    <targets>
      <default-wrapper xsi:type="UiPrettyExceptionWrapper" />
      <target name="insightsMonitoring" xsi:type="Insights" batchSize="500" queueLimit="10000" retryCount="1"
              host="${ui-insights-host}" api="/api/RealTimeData/robotlog"/>
      <target name="fileLog" xsi:type="AsyncWrapper">
        <target xsi:type="File" name="fileLogInner"
                fileName="${gdc:item=logDirectory:whenEmpty=${basedir}/logs}/logfile.txt"
                layout="${date:format=yyyy-MM-dd HH\:mm\:ss.fff} [${level}] ${logger}${literal:text= request=:when=length('${mdlc:item=Correlation}')&gt;0}${mdlc:item=Correlation} ${message}${onexception:${newline}${ui-pretty-exception}}"
                maxArchiveFiles="7" archiveAboveSize="1048576" archiveEvery="Day" />
      </target>
      <target xsi:type="EventLog" name="eventLog"
              layout="${message}${onexception:${exception:format=tostring:maxInnerExceptionLevel=5:innerFormat=tostring}}"
              source="Orchestrator" log="Application" />
      <target xsi:type="EventLog" name="businessExceptionEventLog"
              layout="${message}${onexception:${exception:format=tostring:maxInnerExceptionLevel=5:innerFormat=tostring}}"
              source="Orchestrator.BusinessException" log="Application" />
      <target name="robotElasticBuffer" xsi:type="BufferingWrapper" flushTimeout="5000">
        <target xsi:type="ElasticSearch" name="robotElastic" uri="" requireAuth="false" username="" password=""
                index="${event-properties:item=indexName}-${date:format=yyyy.MM}" documentType="logEvent"
                includeAllProperties="true" layout="${message}"
                excludedProperties="agentSessionId,tenantId,indexName" />
      </target>
      <target name="serverElasticBuffer" xsi:type="BufferingWrapper" flushTimeout="5000">
        <target xsi:type="ElasticSearch" name="serverElastic" uri="" requireAuth="false" username="" password=""
                index="serverdiagnostics-${date:format=yyyy.MM}" documentType="logEvent"
                includeAllProperties="true" layout="${machinename} ${message}" />
      </target>
      <target xsi:type="AsyncWrapper" name="database" overflowAction="Block" queueLimit="100" batchSize="60">
        <target xsi:type="DatabaseBulk" connectionString="${ui-connection-strings:item=Default}" tableName="[dbo].[Logs]" batchSize="20">
          <parameter dbType="BigInt"           name="OrganizationUnitId" propertyItem="organizationUnitId" />
          <parameter dbType="Int"              name="TenantId"           propertyItem="tenantId" />
          <parameter dbType="DateTime"         name="TimeStamp"          layout="${date:format=yyyy-MM-dd HH\:mm\:ss.fff}" />
          <parameter dbType="Int"              name="Level"              propertyItem="levelOrdinal" />
          <parameter dbType="NVarChar"         name="WindowsIdentity"    propertyItem="windowsIdentity" />
          <parameter dbType="NVarChar"         name="ProcessName"        propertyItem="processName" />
          <parameter dbType="UniqueIdentifier" name="JobKey"             propertyItem="jobId" />
          <parameter dbType="NVarChar"         name="Message" />
          <parameter dbType="NVarChar"         name="RawMessage"         propertyItem="rawMessage" />
          <parameter dbType="NVarChar"         name="RobotName"          propertyItem="robotName" />
          <parameter dbType="BigInt"           name="MachineId"          propertyItem="machineId" />
          <parameter dbType="UniqueIdentifier" name="UserKey"            propertyItem="userKey" />
          <parameter dbType="NVarChar"         name="HostMachineName"    propertyItem="machineName" />
        </target>
      </target>
      <target xsi:type="AsyncWrapper" name="monitoring" overflowAction="Block" queueLimit="100" batchSize="60">
        <target xsi:type="DatabaseBulk" connectionString="${ui-connection-strings:item=Default}" tableName="[stats].[ErrorLogs]" batchSize="20">
          <parameter dbType="BigInt"           name="OrganizationUnitId" propertyItem="organizationUnitId" />
          <parameter dbType="BigInt"           name="TenantId"           propertyItem="tenantId" />
          <parameter dbType="DateTime"         name="TimeStamp"          layout="${date:format=yyyy-MM-dd HH\:mm\:ss.fff}" />
          <parameter dbType="UniqueIdentifier" name="CorrelationId"      propertyItem="Correlation" />
          <parameter dbType="Int"              name="Source"             propertyItem="logSource" />
          <parameter dbType="Int"              name="Level"              propertyItem="levelOrdinal" />
          <parameter dbType="BigInt"           name="RobotId"            propertyItem="robotId" />
          <parameter dbType="NVarChar"         name="ProcessName"        propertyItem="processName" />
          <parameter dbType="UniqueIdentifier" name="JobKey"             propertyItem="jobId" />
          <parameter dbType="BigInt"           name="QueueDefinitionId"  propertyItem="queueId" />
          <parameter dbType="NVarChar"         name="Message" />
        </target>
      </target>
      <target xsi:type="AsyncWrapper" name="insightsRobotLogs" overflowAction="Block" queueLimit="100" batchSize="60">
        <target name="insightsRobotLogs" xsi:type="DatabaseBulk"
                connectionString="${ui-connection-strings:item=Insights}" tableName="[dbo].[RobotLogs]" batchSize="20">
          <parameter dbType="BigInt"           name="OrganizationUnitId" propertyItem="organizationUnitId" />
          <parameter dbType="Int"              name="TenantId"           propertyItem="tenantId" />
          <parameter dbType="DateTime"         name="TimeStamp"          layout="${date:format=yyyy-MM-dd HH\:mm\:ss.fff}" />
          <parameter dbType="NVarChar"         name="WindowsIdentity"    propertyItem="windowsIdentity" />
          <parameter dbType="NVarChar"         name="ProcessName"        propertyItem="processName" />
          <parameter dbType="UniqueIdentifier" name="JobKey"             propertyItem="jobId" />
          <parameter dbType="NVarChar"         name="RawMessage"         propertyItem="rawMessage" />
          <parameter dbType="NVarChar"         name="RobotName"          propertyItem="robotName" />
          <parameter dbType="BigInt"           name="MachineId"          propertyItem="machineId" />
          <parameter dbType="NVarChar"         name="Message" />
          <parameter dbType="Int"              name="LevelOrdinal"       propertyItem="levelOrdinal" />
          <parameter dbType="Int"              name="NumCustomFields"    layout="${ui-robot-logs-num-custom-fields}" />
        </target>
      </target>
    </targets>
    <rules>
      <logger name="Robot.*" ruleName="insightsRobotLogsRule" enabled="false" minlevel="Info" writeTo="insightsRobotLogs">
        <filters defaultAction="Ignore">
          <when condition="level &gt;= LogLevel.Error or ends-with('${message}',' execution ended')" action="Log"/>
        </filters>
      </logger>
      <logger name="BusinessException.*" minlevel="Info" writeTo="businessExceptionEventLog" final="true"/>
      <logger name="Robot.*" ruleName="primaryRobotLogsTarget" writeTo="database,robotElasticBuffer" final="true"/>
      <logger name="Monitoring.*" writeTo="monitoring" minlevel="Warn" final="true"/>
      <logger name="*" minlevel="Info" writeTo="eventLog"/>
      <logger name="*" minlevel="Warn" writeTo="fileLog"/>
    </rules>
  </nlog>
  <appSettings>
    <add key="Features.CredentialStoreHost.Enabled" value="false"/><add key="DeploymentUrl" value="" /><add key="MonitoringUrl" value="" />
    <add key="NotificationHubUrl" value="" /><add key="Logs.RobotLogs.ReadTarget" value="database" /><add key="LoggingUrl" value="" />
    <add key="LoggingIndex" value="logflow" /><add key="QueuesSvcUrl" value="" />
    <add key="TermsAndConditionsRegisterUrl" value="https://www.uipath.com/terms-of-use" />
    <add key="inProgressMaxNumberOfMinutes" value="1440" /><add key="QueuesStatisticsScheduleCron" value="10 0/1 * 1/1 * ? *" />
    <add key="UpdateUncompletedItemsJobCron" value="0 0 0/1 1/1 * ? *" /><add key="Queue.ProcessActivationSchedule" value="0 0/30 * 1/1 * ? *" />
    <add key="Queue.MaxSlaInMinutes" value="129600" /><add key="DailyAlertMailJobCron" value="0 0 7 1/1 * ? *" />
    <add key="NotRespondingRobotsJobCron" value="0 0/1 * 1/1 * ? *" /><add key="Alerts.Email.Enabled" value="false" />
    <add key="NotificationDistributerJobCron" value="0/10 1/1 * 1/1 * ? *" /><add key="PeriodicErrorMailJobCron" value="0 0/10 * 1/1 * ? *" />
    <add key="AggregateLicenseUsageStatsJobCron" value="0 0 0/1 1/1 * ? *" /><add key="SystemJobs.LicenseExpirationAlert.Cron" value="0 0 7 1/1 * ? *" />
    <add key="SystemJobs.LicenseExpirationAlert.DaysBefore" value="180,90,30,14,7,1" /><add key="SystemJobs.PurgeOldErrorLogs.Cron" value="0 0 1 1/1 * ? *" />
    <add key="SystemJobs.JobTriggersFallback.Cron" value="0 0/10 * 1/1 * ? *" /><add key="SystemJobs.JobTriggersTimerCheck.Cron" value="0 0/1 * 1/1 * ? *" />
    <add key="SystemJobs.QueueSlaAlerting.Cron" value="0 7/30 * 1/1 * ? *" />
    <add key="NuGet.Packages.ApiKey" value="49B62823-8342-4ACA-A40B-D8741FB07178" /><add key="NuGet.Activities.ApiKey" value="49B62823-8342-4ACA-A40B-D8741FB07178" />
    <add key="Deployment.Libraries.AllowTenantPublish" value="true" /><add key="Auth.UserLockOut.IsEnabled" value="true" />
    <add key="Auth.UserLockOut.MaxFailedAccessAttemptsBeforeLockout" value="10" /><add key="Auth.UserLockOut.DefaultAccountLockoutSeconds" value="300" />
    <add key="Auth.Password.DefaultExpirationDays" value="0" /><add key="LoadBalancer.UseRedis" value="false" />
    <add key="LoadBalancer.Enabled" value="false" /><add key="LoadBalancer.Redis.ConnectionString" value="localhost:6379" />
    <add key="Plugins.SecureStores" value=""/><add key="CustomTitle" value="" />
    <add key="HelpUrl" value="https://docs.uipath.com/{HELP-LANGUAGE-PLACEHOLDER}/orchestrator/standalone/2024.10/user-guide/introduction" />
    <add key="Database.EnableAutomaticMigrations" value="false"/><add key="Logs.Elasticsearch.MaxResultWindow" value="10000" />
    <add key="SystemJobs.ElasticReloadToken.Cron" value="* 0/19 * ? * * *"/><add key="Webhooks.Enabled" value="true" />
    <add key="Scalability.Heartbeat.PeriodSeconds" value="30" /><add key="Scalability.Heartbeat.FailureThreshold" value="4" />
    <add key="Scalability.SignalR.Enabled" value="true" /><add key="Scalability.SignalR.Transport" value="7" />
    <add key="Scalability.SignalR.AuthenticationEnabled" value="false" /><add key="Features.SmartCardAuthentication.Enabled" value="false" />
    <add key="MediaRecording.Enabled" value="true" /><add key="Storage.Type" value="FileSystem" />
    <add key="Storage.Location" value="RootPath=.\Storage" /><add key="CloudRPA.Instance.Enabled" value="false" />
    <add key="License.ServiceURL" value="https://activate.uipath.com"/><add key="Pagination.Limits.Enabled" value="true" />
    <add key="Triggers.DisableWhenFailedCount" value="10" /><add key="Triggers.DisableWhenFailingSinceDays" value="1" />
    <add key="Buckets.AvailableProviders" value="Orchestrator,Amazon,Azure,Minio,S3Compatible" /><add key="Buckets.FileSystem.Allowlist" value="" />
    <add key="DocsReferenceUri" value="https://docs.uipath.com/orchestrator/reference" />
    <add key="Features.NotifiableUsersCache.Enabled" value="true" /><add key="Features.Queues.ValidateTransitionFromFinalToNew" value="true"/>
    <add key="Features.Queues.ValidateSuccessFailureTransition" value="true"/><add key="VideoRecording.RetentionJobEnabled" value="false" />
    <add key="Telemetry.AppInsights.Key" value="4f1c407b-e9f8-48f5-999a-d7c8e0f4ee20"/>
  </appSettings>
  <secureAppSettings>
    <add key="EncryptionKey" value=""/>
  </secureAppSettings>
  <system.web>
    <machineKey decryption="Auto" decryptionKey="AutoGenerate,IsolateApps" validation="SHA1" validationKey="AutoGenerate,IsolateApps" />
  </system.web>
</configuration>
'@
    foreach ($name in @("UiPath.Orchestrator.dll.config","UiPath.Orchestrator.WebCore.Host.exe.config","Web.config")) {
        $dest = Join-Path $tempDirectory $name
        if (-not (Test-Path $dest)) {
            [System.IO.File]::WriteAllText($dest, $templateXml, [System.Text.UTF8Encoding]::new($false))
            Write-Host "  Generated: $dest" -ForegroundColor Green
        }
    }
}

# ============================================================================
# Section: Deployment helpers (MsDeploy / Kudu)
# ============================================================================

function Invoke-MsDeployPackage([string]$package, $publishSettings, [System.Collections.Hashtable]$parameters,
                                [string[]]$skipFolders, [string[]]$skipFiles) {
    $package    = (Resolve-Path $package).Path
    $site       = $publishSettings.SiteName
    $pubUrl     = $publishSettings.PublishUrl
    $user       = $publishSettings.UserName
    $pass       = $publishSettings.Password
    $msDeployExe = Join-Path ${env:ProgramFiles(x86)} "IIS\Microsoft Web Deploy V3\msdeploy.exe"
    if (-not (Test-Path $msDeployExe)) { Write-Error "msdeploy.exe not found at '$msDeployExe'"; Exit 1 }
    $msDeployArgs = "-verb:sync -source:package='$package' -dest:auto,ComputerName='https://$pubUrl/msdeploy.axd?site=$site',UserName='$user',Password='$pass',AuthType='Basic' -disableLink:AppPoolExtension -disableLink:ContentExtension -disableLink:CertificateExtension"
    [Void][Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem')
    $zipFile = [System.IO.Compression.ZipFile]::OpenRead($package)
    try {
        $hasIisParam = $false
        $paramEntry = $zipFile.Entries | Where-Object { $_.FullName -eq "parameters.xml" }
        if ($paramEntry) {
            $sr = New-Object System.IO.StreamReader($paramEntry.Open())
            try { $hasIisParam = $sr.ReadToEnd() -match 'IIS Web Application Name' } finally { $sr.Close() }
        }
    } finally { $zipFile.Dispose() }
    if ($hasIisParam) { $msDeployArgs += " -setParam:name='IIS Web Application Name',value='$site'" }
    if ($skipFolders) { $skipFolders | ForEach-Object { $msDeployArgs += " -skip:objectName=dirPath,absolutePath='$_'" } }
    if ($skipFiles)   { $skipFiles   | ForEach-Object { $msDeployArgs += " -skip:objectName=filePath,absolutePath='$_'" } }
    if ($parameters)  { $parameters.GetEnumerator() | ForEach-Object { $msDeployArgs += " -setParam:name='$($_.Key)',value='$($_.Value)'" } }
    Write-Host "`nDeploying package on website $($publishSettings.SiteName)" -ForegroundColor Yellow
    Write-Host "`nExecuting: msdeploy.exe $msDeployArgs`n" -ForegroundColor Yellow
    $proc = Start-Process $msDeployExe -ArgumentList $msDeployArgs -Wait -NoNewWindow -PassThru
    if ($proc.ExitCode) {
        Write-Error "msdeploy.exe failed with exit code $($proc.ExitCode)"
        Exit 1
    }
    Write-Host "`nPackage deployed successfully via MsDeploy." -ForegroundColor Green
}

function Apply-WdParametersToConfig([System.Collections.Hashtable]$parameters,[string]$configPath,[string]$parametersXmlPath) {
    if (-not (Test-Path $parametersXmlPath)) { Write-Verbose "parameters.xml not found; skipping WD param injection."; return }
    [xml]$configDoc  = Get-Content $configPath
    $paramsXml = New-Object System.Xml.XmlDocument; $paramsXml.Load($parametersXmlPath)
    $updated = $false
    foreach ($key in $parameters.Keys) {
        $node = $paramsXml.SelectSingleNode("/parameters/parameter[@name='$key']/parameterEntry[@kind='XmlFile']")
        if ($node) {
            $attr = $configDoc.SelectSingleNode($node.match)
            if ($attr) { $attr.Value = $parameters[$key]; $updated = $true }
        }
    }
    if ($updated) { $configDoc.Save($configPath) }
}

# Generic Kudu ZIP deploy -- works for any service package.
# Web Deploy packages (contain archive.xml) are extracted first;
# plain zip archives are posted as-is.
function Invoke-KuduZipDeploy([string]$package, $publishSettings,
                               [System.Collections.Hashtable]$parameters=$null,
                               [string]$webArchiveContentPath=$null,
                               [string]$configName=$null,
                               [string]$parametersXmlPath=$null) {

    $pubUrl = $publishSettings.PublishUrl
    $user   = $publishSettings.UserName
    $pass   = $publishSettings.Password

    [Void][Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem')
    $zipFile = [System.IO.Compression.ZipFile]::OpenRead($package)
    $isWebDeployPkg = $null -ne ($zipFile.Entries | Where-Object { $_.FullName -eq "archive.xml" })
    $zipFile.Dispose()

    $kuduZipPath  = Join-Path ([System.IO.Path]::GetTempPath()) "kudu-$(Get-Date -f 'yyyyMMddhhmmssfff').zip"
    $contentTempDir = Join-Path ([System.IO.Path]::GetTempPath()) "kudu-content-$(Get-Date -f 'yyyyMMddhhmmssfff')"
    New-Item -ItemType Directory -Path $contentTempDir | Out-Null

    try {
        if ($isWebDeployPkg -and $webArchiveContentPath) {
            Write-Host "Extracting web content from Web Deploy package ..."
            Extract-DirectoryFromZip -zip $package -directory $webArchiveContentPath -destination "$contentTempDir/"
            if ($configName -and $parameters -and $parametersXmlPath) {
                $cfgPath = Join-Path $contentTempDir $configName
                if (Test-Path $cfgPath) { Apply-WdParametersToConfig -parameters $parameters -configPath $cfgPath -parametersXmlPath $parametersXmlPath }
            }
            [System.IO.Compression.ZipFile]::CreateFromDirectory($contentTempDir, $kuduZipPath)
        } else {
            Write-Host "Using package directly for Kudu deploy ..."
            Copy-Item $package $kuduZipPath
        }

        $kuduUrl = "https://$pubUrl/api/zipdeploy"
        Write-Host "Posting to $kuduUrl ..." -ForegroundColor Yellow
        $creds   = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${user}:${pass}"))
        $headers = @{ Authorization="Basic $creds"; "Content-Type"="application/zip" }
        $resp    = Invoke-WebRequest -Uri $kuduUrl -Method POST -InFile $kuduZipPath -Headers $headers -UseBasicParsing
        if ($resp.StatusCode -in @(200,202)) { Write-Host "Kudu deploy succeeded. HTTP $($resp.StatusCode)" -ForegroundColor Green }
        else { Write-Error "Kudu deploy returned HTTP $($resp.StatusCode)"; Exit 1 }
    } catch {
        Write-Error "Kudu deploy failed: $($_.Exception.Message)"
        if ($_.Exception.Response) {
            try { $r=New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream()); Write-Error $r.ReadToEnd() } catch {}
        }
        Exit 1
    } finally {
        Remove-Item $contentTempDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $kuduZipPath    -Force          -ErrorAction SilentlyContinue
    }
}

# Routes to MsDeploy or Kudu based on $deployMethod.
function Deploy-ServicePackage([string]$package, $publishSettings,
                                [System.Collections.Hashtable]$parameters=$null,
                                [string[]]$skipFolders=$null, [string[]]$skipFiles=$null,
                                [string]$webArchiveContentPath=$null, [string]$configName=$null,
                                [string]$parametersXmlPath=$null) {
    if ($deployMethod -eq "KuduZipDeploy") {
        Invoke-KuduZipDeploy -package $package -publishSettings $publishSettings `
            -parameters $parameters -webArchiveContentPath $webArchiveContentPath `
            -configName $configName -parametersXmlPath $parametersXmlPath
    } else {
        Invoke-MsDeployPackage -package $package -publishSettings $publishSettings `
            -parameters $parameters -skipFolders $skipFolders -skipFiles $skipFiles
    }
}

# ============================================================================
# Section: File transfer (FTP / FTPS / HTTP)
# ============================================================================

function Download-File([string]$url,[string]$userName,[string]$password,[string]$outputPath) {
    Write-Verbose "Downloading $url -> $outputPath"
    try {
        $isFtps = $url -match '^ftps://'
        if ($isFtps -or $url -match '^ftp://') {
            $normUrl = if ($isFtps) { $url -replace '^ftps://','ftp://' } else { $url }
            $req = [System.Net.FtpWebRequest][System.Net.WebRequest]::Create([System.Uri]$normUrl)
            $req.Method = [System.Net.WebRequestMethods+Ftp]::DownloadFile
            $req.Credentials = New-Object System.Net.NetworkCredential($userName.Normalize(),$password.Normalize())
            $req.EnableSsl = $isFtps
            $resp = $req.GetResponse()
            $rs = $resp.GetResponseStream(); $fs = [System.IO.File]::Create($outputPath)
            $rs.CopyTo($fs); $fs.Close(); $rs.Close(); $resp.Close()
        } else {
            $wc = New-Object System.Net.WebClient
            $wc.Credentials = New-Object System.Net.NetworkCredential($userName.Normalize(),$password.Normalize())
            $wc.DownloadFile($url,$outputPath)
        }
        return $true
    } catch [System.Net.WebException] { Write-Host "Download failed: $($_.Exception.Message)"; return $false }
}

# ============================================================================
# Section: Orchestrator-specific helpers
# ============================================================================

function Get-OrchWDParameters {
    $p = @{ ElasticSearchRequireAuth="false"; elasticSearchDiagnosticsRequireAuth="false" }
    $p.EncryptionKey = if ($action -eq "Deploy") { Generate-EncryptionKey } else { $script:orch_encryptionKey }
    $mk = if ($action -eq "Deploy") { Generate-MachineKeySettings } else {
        @{ decryption=$script:orch_decryption; decryptionKey=$script:orch_decryptionKey; validation=$script:orch_validation; validationKey=$script:orch_validationKey }
    }
    $p.machineKeyDecryption=$mk.decryption; $p.machineKeyDecryptionKey=$mk.decryptionKey
    $p.machineKeyValidation=$mk.validation; $p.machineKeyValidationKey=$mk.validationKey
    if ($script:orch_redisConnectionString) { $p.loadBalancerUseRedis=$script:orch_loadBalancerUseRedis; $p.loadBalancerRedisConnectionString=$script:orch_redisConnectionString }
    if ($script:orch_robotsElasticSearchUrl) {
        $p.ElasticSearchUrl=$script:orch_robotsElasticSearchUrl; $p.ElasticSearchLogger="$script:orch_robotsElasticSearchTargets"
        if ($script:orch_robotsElasticSearchUsername -and $script:orch_robotsElasticSearchPassword) {
            $p.ElasticSearchUsername=$script:orch_robotsElasticSearchUsername; $p.ElasticSearchPassword=$script:orch_robotsElasticSearchPassword; $p.ElasticSearchRequireAuth="true"
        }
    }
    if ($script:orch_serverDefaultTargets) { $p.serverDefaultTargets="$script:orch_serverDefaultTargets" }
    if ($script:orch_serverElasticSearchUrl) {
        $p.elasticSearchDiagnosticsUrl=$script:orch_serverElasticSearchUrl
        if ($script:orch_serverElasticSearchIndex) { $p.elasticSearchDiagnosticsIndex=$script:orch_serverElasticSearchIndex }
        if ($script:orch_serverElasticSearchDiagnosticsUsername -and $script:orch_serverElasticSearchDiagnosticsPassword) {
            $p.elasticSearchDiagnosticsUsername=$script:orch_serverElasticSearchDiagnosticsUsername
            $p.elasticSearchDiagnosticsPassword=$script:orch_serverElasticSearchDiagnosticsPassword; $p.elasticSearchDiagnosticsRequireAuth="true"
        }
    }
    $p.storageType=$script:orch_storageType; $p.storageLocation=$script:orch_storageLocation
    $p.apiKey=$script:orch_packagesApiKey;  $p.activitiesApiKey=$script:orch_activitiesApiKey
    if ($script:orch_azureSignalRConnectionString) { $p.azureSignalRConnectionString=$script:orch_azureSignalRConnectionString }
    if ($script:orch_bucketsFileSystemAllowlist) { $p.bucketsFileSystemAllowlist=$script:orch_bucketsFileSystemAllowlist }
    if ($script:orch_bucketsAvailableProviders)  { $p.bucketsAvailableProviders=$script:orch_bucketsAvailableProviders }
    return $p
}

function Generate-EncryptionKey {
    $e = New-Object System.Security.Cryptography.AesCryptoServiceProvider
    $e.Mode=[System.Security.Cryptography.CipherMode]::CBC; $e.BlockSize=128; $e.KeySize=256; $e.GenerateKey()
    return [System.Convert]::ToBase64String($e.Key)
}

function Generate-MachineKeySettings {
    param([string]$decryptionAlgorithm="AES",[string]$validationAlgorithm="HMACSHA256")
    function BinaryToHex($bytes) {
        $sb=New-Object System.Text.StringBuilder
        foreach($b in $bytes){$sb=$sb.AppendFormat([System.Globalization.CultureInfo]::InvariantCulture,"{0:X2}",$b)}; $sb
    }
    $dec = switch($decryptionAlgorithm){"AES"{New-Object System.Security.Cryptography.AesCryptoServiceProvider}"DES"{New-Object System.Security.Cryptography.DESCryptoServiceProvider}"3DES"{New-Object System.Security.Cryptography.TripleDESCryptoServiceProvider}}
    $dec.GenerateKey(); $dk=(BinaryToHex $dec.Key).ToString(); $dec.Dispose()
    $val = switch($validationAlgorithm){"MD5"{New-Object System.Security.Cryptography.HMACMD5}"SHA1"{New-Object System.Security.Cryptography.HMACSHA1}"HMACSHA256"{New-Object System.Security.Cryptography.HMACSHA256}"HMACSHA512"{New-Object System.Security.Cryptography.HMACSHA512}}
    $vk=(BinaryToHex $val.Key).ToString(); $val.Dispose()
    return @{ decryption=$decryptionAlgorithm.ToUpperInvariant(); decryptionKey=$dk; validation=$validationAlgorithm.ToUpperInvariant(); validationKey=$vk }
}

function Generate-Guid { return ([guid]::NewGuid().Guid) }

function Get-PublishParameters([System.Collections.Hashtable]$wdParams) {
    return @{
        encryptionKey                          = $wdParams.EncryptionKey
        packagesApiKey                         = $wdParams.apiKey
        activitiesApiKey                       = $wdParams.activitiesApiKey
        machineKeyDecryption                   = $wdParams.machineKeyDecryption
        machineKeyDecryptionKey                = $wdParams.machineKeyDecryptionKey
        machineKeyValidation                   = $wdParams.machineKeyValidation
        machineKeyValidationKey                = $wdParams.machineKeyValidationKey
        storageType                            = $wdParams.storageType
        storageLocation                        = $wdParams.storageLocation
        robotsElasticSearchUrl                 = $wdParams.ElasticSearchUrl
        robotsElasticSearchUsername            = $wdParams.ElasticSearchUsername
        robotsElasticSearchPassword            = $wdParams.ElasticSearchPassword
        robotsElasticSearchTargets             = $wdParams.ElasticSearchLogger
        serverElasticSearchUrl                 = $wdParams.elasticSearchDiagnosticsUrl
        serverElasticSearchIndex               = $wdParams.elasticSearchDiagnosticsIndex
        serverDefaultTargets                   = $wdParams.serverDefaultTargets
        serverElasticSearchDiagnosticsUsername = $wdParams.elasticSearchDiagnosticsUsername
        serverElasticSearchDiagnosticsPassword = $wdParams.elasticSearchDiagnosticsPassword
        azureSignalRConnectionString           = $wdParams.azureSignalRConnectionString
        bucketsFileSystemAllowlist             = $wdParams.bucketsFileSystemAllowlist
        bucketsAvailableProviders              = $wdParams.bucketsAvailableProviders
    }
}

function Get-WDParameterValue([string]$paramName,[string]$parametersXmlPath,[string]$webConfigPath) {
    $pXml=New-Object System.Xml.XmlDocument; $pXml.Load($parametersXmlPath)
    $wXml=New-Object System.Xml.XmlDocument; $wXml.Load($webConfigPath)
    $node=$pXml.SelectSingleNode("/parameters/parameter[@name='$paramName']")
    if (!$node) { Write-Warning "No WD parameter '$paramName' in parameters.xml"; return "" }
    $xpath=$node.SelectSingleNode("parameterEntry[@kind='XmlFile']/@match").value
    return $wXml.SelectSingleNode($xpath).value
}

# Reads a setting: checks live Azure App Settings first (via $script:orch_existingProdAppSettings),
# then falls back to the local config file, then to an optional fallback string.
function Get-SettingFromConfig([string]$settingName,[string]$webConfigPath,[string]$fallbackValue=$null) {
    if ($script:orch_existingProdAppSettings -and $script:orch_existingProdAppSettings[$settingName]) {
        return $script:orch_existingProdAppSettings[$settingName]
    }
    $n = Select-Xml -Path $webConfigPath -XPath "//configuration/appSettings/add[@key='$settingName']" |
         Select-Object -ExpandProperty Node -First 1
    $v = if ($n) { $n.value } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
    return $fallbackValue
}

function Get-AppSettingFromAzure([string]$settingName,[string]$rgName,[string]$svcName) {
    $s=(Get-AzWebApp -ResourceGroupName $rgName -Name $svcName -ErrorAction SilentlyContinue).SiteConfig.AppSettings |
        Where-Object {$_.Name -eq $settingName}
    if ($s) { return $s.Value } else { return $null }
}

function Set-AppSlotSettings([System.Collections.Hashtable]$settings,[string]$rgName,[string]$svcName,[string]$slotName) {
    if ($settings) { Set-AzWebAppSlot -AppSettings $settings -Name $svcName -ResourceGroupName $rgName -Slot $slotName }
}

function Read-ExistingSlotAppSettings([string]$rgName,[string]$svcName,[string]$slotName) {
    $existing=(Get-AzWebAppSlot -Name $svcName -ResourceGroupName $rgName -Slot $slotName).SiteConfig.AppSettings
    if (-not $existing) { return @{} }
    $h=New-Object System.Collections.Hashtable
    $existing | ForEach-Object { $h[$_.Name]=$_.Value }
    return $h
}

function Merge-Hashtables([System.Collections.Hashtable]$from,[System.Collections.Hashtable]$to) {
    $r=New-Object System.Collections.Hashtable
    if ($to)   { $to.GetEnumerator()   | ForEach-Object { $r[$_.Name]=$_.Value } }
    if ($from) { $from.GetEnumerator() | ForEach-Object { $r[$_.Name]=$_.Value } }
    return $r
}

function ConvertPsObjectToHashtable($obj) {
    if ($obj -is [System.Collections.Hashtable]) { return $obj }
    $h=New-Object System.Collections.Hashtable
    $obj.PSObject.Properties | ForEach-Object { $h[$_.Name]=if($null -ne $_.Value){$_.Value.ToString()}else{""} }
    return $h
}

function Add-AppSetting([System.Object]$settings,$key,$value) {
    $h = if ($settings) { ConvertPsObjectToHashtable $settings } else { @{} }
    $h[$key]=$value; return $h
}

function Write-ProcessStd {
    param([psobject]$process,[bool]$verboseMessage=$false)
    if (-not [string]::IsNullOrWhiteSpace($process.StdOut)) {
        if ($verboseMessage) { Write-Verbose "StdOut: $($process.StdOut)" }
        else { Write-Host "StdOut: $($process.StdOut)" }
    }
    if (-not [string]::IsNullOrWhiteSpace($process.StdErr)) {
        Write-Host "StdErr: $($process.StdErr)" -ForegroundColor Red
    }
}

function DisplayException($ex) { Write-Host ($ex | Format-List -Force | Out-String) }

# Upsert an appSetting key in a config XML file (add node if missing).
function Set-SettingValue([string]$settingName,[string]$settingValue,[string]$webConfigPath) {
    [xml]$doc = Get-Content $webConfigPath
    $as = $doc.SelectSingleNode("//configuration/appSettings")
    if (-not $as) { Write-Error "Invalid config: no appSettings in $webConfigPath"; return }
    $node = $as.SelectSingleNode("add[@key='$settingName']")
    if ($node) { $node.value = $settingValue }
    else {
        $n = $doc.CreateElement("add")
        $n.SetAttribute("key",$settingName); $n.SetAttribute("value",$settingValue)
        $as.AppendChild($n) | Out-Null
    }
    $doc.Save($webConfigPath)
}

# ============================================================================
# Section: Orchestrator database helpers
# ============================================================================

function Invoke-Executable([string]$exeFile,[string]$exeArgs,[int]$timeoutMs=1800000) {
    $obfArgs=$exeArgs -replace 'password=([^''][^;]+|''[^'']+'')','password=***'
    Write-Host "$exeFile $obfArgs"
    $psi=New-Object System.Diagnostics.ProcessStartInfo
    $psi.CreateNoWindow=$true; $psi.UseShellExecute=$false
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $psi.FileName=$exeFile; $psi.Arguments=$exeArgs
    $proc=New-Object System.Diagnostics.Process; $proc.StartInfo=$psi
    $sbOut=New-Object System.Text.StringBuilder; $sbErr=New-Object System.Text.StringBuilder
    $blk={ if(![string]::IsNullOrEmpty($EventArgs.Data)){$Event.MessageData.AppendLine($EventArgs.Data)} }
    $eOut=Register-ObjectEvent -InputObject $proc -Action $blk -EventName OutputDataReceived -MessageData $sbOut
    $eErr=Register-ObjectEvent -InputObject $proc -Action $blk -EventName ErrorDataReceived  -MessageData $sbErr
    [Void]$proc.Start(); $proc.BeginOutputReadLine(); $proc.BeginErrorReadLine()
    if(-not $proc.WaitForExit($timeoutMs)){$proc.Kill();throw [System.TimeoutException]"$exeFile timed out after $($timeoutMs/1000)s"}
    Unregister-Event -SourceIdentifier $eOut.Name; Unregister-Event -SourceIdentifier $eErr.Name
    return [PSCustomObject]@{ExitCode=$proc.ExitCode;StdOut=$sbOut.ToString().Trim();StdErr=$sbErr.ToString().Trim()}
}

function Run-DatabaseMigrations([string]$databaseType,[string]$connectionString,[string]$orchestratorConnectionString="",[string]$configFilePath) {
    Write-Host "Running $databaseType database migrations ..."
    $migArgs="database upgrade-database --database-type $databaseType --connection-string `"$connectionString`" --configuration-path `"$configFilePath`""
    if ($orchestratorConnectionString) { $migArgs+=" --orchestrator-connection-string `"$orchestratorConnectionString`"" }
    $p=Invoke-Executable -exeFile $script:orch_cliToolPath -exeArgs $migArgs
    Write-Host "Exit: $($p.ExitCode)"
    Write-ProcessStd $p
    if ($p.ExitCode) { throw "Database migration failed ($databaseType), exit $($p.ExitCode)" }

    # Validate the database after migration (non-fatal warnings only)
    Write-Host "Validating $databaseType database ..."
    $vp=Invoke-Executable -exeFile $script:orch_cliToolPath -exeArgs "database validate-database --database-type $databaseType --connection-string `"$connectionString`" --configuration-path `"$configFilePath`""
    Write-Host "Validation exit: $($vp.ExitCode)"
    Write-ProcessStd $vp
    if ($vp.ExitCode) { Write-Host "Database validation detected issues (non-fatal). Continuing." -ForegroundColor Yellow }
}

function Initialize-InternalJobs([string]$databaseType,[string]$connectionString,[string]$configFilePath) {
    Write-Host "Initializing InternalJobs ($databaseType) ..."
    $p=Invoke-Executable -exeFile $script:orch_cliToolPath -exeArgs "database recreate-internal-jobs --database-type $databaseType --connection-string `"$connectionString`" --configuration-path `"$configFilePath`""
    Write-Host "Exit: $($p.ExitCode)"; Write-ProcessStd $p
    if ($p.ExitCode) { throw "InternalJobs init failed, exit $($p.ExitCode)" }
    else { Write-Host "InternalJobs for $databaseType initialized." -ForegroundColor Green }
}

function Invoke-DatabasePreValidations([string]$databaseType,[string]$connectionString,[string]$configFilePath,[bool]$ignoreClassicFoldersError) {
    Write-Host "Pre-validating database ..."
    $p=Invoke-Executable -exeFile $script:orch_cliToolPath -exeArgs "database pre-validate --database-type $databaseType --connection-string `"$connectionString`" --configuration-path `"$configFilePath`""
    Write-Host "Exit: $($p.ExitCode)"; Write-ProcessStd $p $true
    [string[]]$ignoredCodes = @()
    if ($ignoreClassicFoldersError) { $ignoredCodes += "ClassicFoldersPresent" }
    $fatal=0
    if ($p.ExitCode) {
        $errs = $p.StdErr | ConvertFrom-Json
        foreach($e in $errs){
            Write-Host $e.ErrorMessage -ForegroundColor Red
            if ($e.ErrorCode -notin $ignoredCodes) { $fatal=1 }
        }
    }
    if ($fatal) { Write-Error "Database pre-validation failed."; Exit 1 }
}

function Invoke-ExtensionsValidation([string]$configFilePath) {
    Write-Host "Validating extensions ..."
    $p=Invoke-Executable -exeFile $script:orch_cliToolPath -exeArgs "extensions --configuration-path `"$configFilePath`""
    Write-Host "Exit: $($p.ExitCode)"; Write-ProcessStd $p
    if ($p.ExitCode) { Write-Error "Extensions validation failed."; Exit 1 }
}

function Get-PendingMigrations([string]$connectionString,[string]$webConfigPath,[string]$configMigration) {
    $p=Invoke-Executable -exeFile $script:orch_cliToolPath -exeArgs "database get-pending-migrations --database-type $configMigration --connection-string `"$connectionString`" --configuration-path `"$webConfigPath`""
    Write-Verbose "get-pending-migrations exit: $($p.ExitCode)"
    Write-ProcessStd $p $true
    if ($p.ExitCode -ne 0) { throw "get-pending-migrations failed ($configMigration), exit $($p.ExitCode)" }
    if (-not [string]::IsNullOrWhiteSpace($p.StdOut)) {
        if ($p.StdOut -match "Number of pending migrations: (\d+)\.") { return ([int]$Matches[1] -gt 0) }
    }
    return $false
}

# ============================================================================
# Section: Identity Server helpers
# ============================================================================

function Run-IdentityDbMigrator([string]$connectionString,[string]$cliPath) {
    Write-Host "Running Identity DB migrator ..."
    $proc=Start-Process $cliPath -ArgumentList "install -d `"$connectionString`" -r" -Wait -NoNewWindow -PassThru
    if ($proc.ExitCode) { throw "Identity DB migrator failed, exit $($proc.ExitCode)" }
}

function Run-IdentityDataMigrator([string]$orchConnStr,[string]$identityConnStr,[string]$orchConfigPath,
                                   [string]$idServerUrl,[string]$cliPath,
                                   [string]$hostPwd="",[string]$defaultTenantPwd="",
                                   [switch]$hostPassOnetime,[switch]$defaultTenantPassOneTime) {
    Write-Host "Running Identity data migrator (migrate-21-4) ..."
    $hp = $hostPwd        -replace '"','\"'
    $dp = $defaultTenantPwd -replace '"','\"'
    $migArgs="migrate-21-4 -s `"$orchConnStr`" -d `"$identityConnStr`" -b 5000 -w `"$orchConfigPath`" -i `"$idServerUrl`" --hostAdminPassword=`"$hp`" --defaultTenantAdminPassword=`"$dp`""
    if ($hostPassOnetime)          { $migArgs += " -p" }
    if ($defaultTenantPassOneTime) { $migArgs += " -q" }
    $proc=Start-Process $cliPath -ArgumentList $migArgs -Wait -NoNewWindow -PassThru -ErrorAction Stop
    if ($proc.ExitCode) { throw "Identity data migrator (migrate-21-4) failed, exit $($proc.ExitCode)" }
}

function Run-IdentitySeedMigrator([string]$identityConnStr,[string]$orchUrl,[string]$managementUri,[string]$cliPath,[string]$workDir) {
    Write-Host "Running Identity seed migrator ..."
    $cfgFile=Join-Path $workDir "clients_config.json"
    $cliDir=Split-Path $cliPath -Parent
    $seedArgs="seed -o `"$cfgFile`" -d `"$identityConnStr`" -u `"$orchUrl`" -m `"$managementUri`""
    $proc=Start-Process $cliPath -ArgumentList $seedArgs -WorkingDirectory $cliDir -Wait -NoNewWindow -PassThru -ErrorAction Stop
    # Note: clients_config.json is intentionally left for Identity_UpdateOrchSettings to consume on Deploy.
    if ($proc.ExitCode) { throw "Identity seed migrator failed, exit $($proc.ExitCode)" }
}

function Update-IdentityAppSettings([string]$rgName,[string]$svcName,[string]$slotName,
                                     [string]$orchUrl,[string]$rcUrl) {
    Write-Host "Updating Identity Server app settings ..."
    $app=Get-AzWebApp -Name $svcName -ResourceGroupName $rgName
    $existing=@{}; $app.SiteConfig.AppSettings | ForEach-Object { $existing[$_.Name]=$_.Value }

    # Generate DB protection key if not already set
    if ([string]::IsNullOrEmpty($existing["AppSettings__DatabaseProtectionSettings__EncryptionKey2021"])) {
        $kb=New-Object Byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($kb)
        $existing["AppSettings__DatabaseProtectionSettings__EncryptionKey2021"]=[Convert]::ToBase64String($kb)
    }
    $existing["AppSettings__OrchestratorUrl"]    = $orchUrl
    $existing["AppSettings__ResourceCatalogUrl"] = $rcUrl

    Set-AzWebApp -AppSettings $existing -Name $svcName -ResourceGroupName $rgName | Out-Null
    Write-Host "Identity app settings updated." -ForegroundColor Green
}

function Exchange-EncryptionKeys([string]$orchRgName,[string]$orchSvcName,
                                  [string]$idRgName,  [string]$idSvcName,
                                  [string]$orchConfigPath) {
    Write-Host "Exchanging encryption keys between Orchestrator and Identity ..."
    # Identity -> Orchestrator: DatabaseProtectionSettings key
    $idApp=Get-AzWebApp -Name $idSvcName -ResourceGroupName $idRgName
    $idKey=($idApp.SiteConfig.AppSettings | Where-Object {$_.Name -eq "AppSettings__DatabaseProtectionSettings__EncryptionKey2021"}).Value
    if ($idKey) {
        $orchApp=Get-AzWebApp -Name $orchSvcName -ResourceGroupName $orchRgName
        $orchSettings=@{}; $orchApp.SiteConfig.AppSettings | ForEach-Object { $orchSettings[$_.Name]=$_.Value }
        $orchSettings["IdentityServer.EncryptionKey"]=$idKey
        Set-AzWebApp -AppSettings $orchSettings -Name $orchSvcName -ResourceGroupName $orchRgName | Out-Null
        Write-Host "  Copied Identity encryption key -> Orchestrator" -ForegroundColor Green
    }
    # Orchestrator config -> Identity: EncryptionKey
    if (Test-Path $orchConfigPath) {
        $orchEncKey=Get-SettingFromConfig -settingName "EncryptionKey" -webConfigPath $orchConfigPath
        if ($orchEncKey) {
            $idSettings=@{}; $idApp.SiteConfig.AppSettings | ForEach-Object { $idSettings[$_.Name]=$_.Value }
            $idSettings["EncryptionSettings__EncryptionKey"]=$orchEncKey
            Set-AzWebApp -AppSettings $idSettings -Name $idSvcName -ResourceGroupName $idRgName | Out-Null
            Write-Host "  Copied Orchestrator EncryptionKey -> Identity" -ForegroundColor Green
        }
    }
}

# ============================================================================
# Section: Migration helpers  (Deploy action -- companion service post-deploy)
# ============================================================================

# Update the Default connection string in a generated config file with the real SQL string.
function Update-ConfigConnectionString([string]$configPath,[string]$connectionString) {
    if (-not $connectionString -or -not (Test-Path $configPath)) { return }
    [xml]$doc = Get-Content $configPath
    $node = $doc.SelectSingleNode("//connectionStrings/add[@name='Default']")
    if ($node) { $node.SetAttribute("connectionString",$connectionString); $doc.Save($configPath) }
}

# Merge $newSettings into the Azure App Settings of $svcName (upsert, no deletes).
function Update-AzWebAppSettings([string]$rgName,[string]$svcName,[System.Collections.Hashtable]$newSettings) {
    Write-Host "Updating app settings for $svcName ..."
    $app = Get-AzWebApp -Name $svcName -ResourceGroupName $rgName
    $existing = @{}
    $app.SiteConfig.AppSettings | ForEach-Object { $existing[$_.Name] = $_.Value }
    $newSettings.GetEnumerator() | ForEach-Object { $existing[$_.Key] = $_.Value }
    Set-AzWebApp -AppSettings $existing -Name $svcName -ResourceGroupName $rgName | Out-Null
    Write-Host "  App settings updated for $svcName." -ForegroundColor Green
}

# Run the plain 'migrate' command (initial user/tenant migration from Orchestrator -> Identity).
function Run-IdentityDataMigrate([string]$orchConnStr,[string]$identityConnStr,[string]$orchConfigPath,
                                  [string]$idServerUrl,[string]$cliPath) {
    Write-Host "Running Identity data migrator (migrate) ..."
    $migArgs="migrate -s `"$orchConnStr`" -d `"$identityConnStr`" -b 5000 -w `"$orchConfigPath`" -i `"$idServerUrl`""
    $proc=Start-Process $cliPath -ArgumentList $migArgs -Wait -NoNewWindow -PassThru -ErrorAction Stop
    if ($proc.ExitCode) { throw "Identity data migrator (migrate) failed, exit $($proc.ExitCode)" }
}

# Read clients_config.json output by the seed migrator and return all Orchestrator Identity settings.
function Read-OrchestratorSettings([string]$configJsonFilePath,[string]$identityServerUrl) {
    Write-Host "Reading Identity integration settings from $configJsonFilePath ..."
    $json = Get-Content -Raw -Path $configJsonFilePath | ConvertFrom-Json
    $s = @{
        "IdentityServer.Integration.Enabled"                         = "true"
        "IdentityServer.Integration.Authority"                       = $identityServerUrl
        "IdentityServer.Integration.ClientId"                        = $json.OrchestratorClientsConfig.OrchestratorS2SClient.ClientId
        "IdentityServer.Integration.ClientSecret"                    = $json.OrchestratorClientsConfig.OrchestratorS2SClient.ClientSecret
        "IdentityServer.Integration.AccessTokenCacheBufferInSeconds" = "50"
        "IdentityServer.Integration.UserOrchestratorApiAudience"     = "OrchestratorApiUserAccess"
        "IdentityServer.Integration.S2SOrchestratorApiAudience"      = "OrchestratorApiS2sAccess"
        "ExternalAuth.System.OpenIdConnect.Enabled"                  = "true"
        "ExternalAuth.System.OpenIdConnect.Authority"                = $identityServerUrl
        "ExternalAuth.System.OpenIdConnect.ClientId"                 = $json.OrchestratorClientsConfig.OrchestratorOpenIdClient.ClientId
        "ExternalAuth.System.OpenIdConnect.ClientSecret"             = $json.OrchestratorClientsConfig.OrchestratorOpenIdClient.ClientSecret
        "ExternalAuth.System.OpenIdConnect.RedirectUri"              = $json.OrchestratorClientsConfig.OrchestratorOpenIdClient.RedirectUri
        "ExternalAuth.System.OpenIdConnect.PostLogoutRedirectUri"    = $json.OrchestratorClientsConfig.OrchestratorOpenIdClient.PostLogoutUri
        "MultiTenancy.AllowHostToAccessTenantApi"                    = "true"
        "MultiTenancy.TenantResolvers.HttpGlobalIdHeaderEnabled"     = "true"
        "Auth.Ropc.ClientSecret"                                     = $json.OrchestratorClientsConfig.OrchestratorRopcClient.ClientSecret
        "IdentityServer.S2SIntegration.Enabled"                     = "true"
        "IdentityServer.OAuth.Enabled"                               = "true"
    }
    # Remove nulls -- CLI may omit values that are already in the DB
    @($s.Keys | Where-Object { $null -eq $s[$_] }) | ForEach-Object { $s.Remove($_) }
    return $s
}

# ---------- Webhooks ----------

function Init-WebhooksCliTool([string]$cliPackage,[string]$destDir) {
    Write-Host "Extracting Webhooks migration CLI from $cliPackage ..."
    Expand-Archive -Path $cliPackage -DestinationPath $destDir -Force
    $rootFolder = Get-ZipRootFolder $cliPackage
    $script:wh_cliPath = Join-Path (Join-Path $destDir $rootFolder) "WebhookService.Migrate.Cli.exe"
    if (-not (Test-Path $script:wh_cliPath)) {
        $found = Get-ChildItem $destDir -Filter "WebhookService.Migrate.Cli.exe" -Recurse | Select-Object -First 1
        if ($found) { $script:wh_cliPath = $found.FullName }
        else { throw "WebhookService.Migrate.Cli.exe not found in $cliPackage" }
    }
    Write-Host "  Webhooks CLI: $script:wh_cliPath" -ForegroundColor Green
}

function Run-WebhooksSettingsMigrator([string]$orchWebConfigPath,[string]$appSettingsOutputPath) {
    Write-Host "Running Webhooks settings migrator ..."
    Set-Content -Path $appSettingsOutputPath -Value '{}' -Force
    $migArgs="--webConfigFile `"$orchWebConfigPath`" --appSettingsFile `"$appSettingsOutputPath`""
    $proc=Start-Process $script:wh_cliPath -ArgumentList $migArgs -Wait -NoNewWindow -PassThru
    Write-Host "  Webhooks migrator exit code: $($proc.ExitCode)"
    if ($proc.ExitCode) { throw "Webhooks settings migrator failed, exit $($proc.ExitCode)" }
}

# Upload a local file to an Azure App Service via FTP/FTPS (falls back gracefully on error).
function Upload-FileToWebApp([string]$remotePath,[string]$localPath,$ftpProfile) {
    $url = if ($remotePath.StartsWith("/")) { $ftpProfile.FtpPublishUrl + $remotePath }
           else { $ftpProfile.FtpPublishUrl + "/" + $remotePath }
    Write-Verbose "Uploading $localPath -> $url"
    $isFtps = $url -match '^ftps://'
    if ($isFtps -or $url -match '^ftp://') {
        $normUrl = if ($isFtps) { $url -replace '^ftps://','ftp://' } else { $url }
        $req = [System.Net.FtpWebRequest][System.Net.WebRequest]::Create([System.Uri]$normUrl)
        $req.Method = [System.Net.WebRequestMethods+Ftp]::UploadFile
        $req.Credentials = New-Object System.Net.NetworkCredential($ftpProfile.FtpUsername.Normalize(),$ftpProfile.FtpPassword.Normalize())
        $req.EnableSsl = $isFtps
        $bytes = [System.IO.File]::ReadAllBytes($localPath)
        $req.ContentLength = $bytes.Length
        $rs = $req.GetRequestStream(); $rs.Write($bytes,0,$bytes.Length); $rs.Close()
        $resp = $req.GetResponse(); $resp.Close()
    } else {
        $wc = New-Object System.Net.WebClient
        $wc.Credentials = New-Object System.Net.NetworkCredential($ftpProfile.FtpUsername.Normalize(),$ftpProfile.FtpPassword.Normalize())
        $wc.UploadFile($url,$localPath)
    }
    Write-Host "  Uploaded $remotePath to $($ftpProfile.FtpPublishUrl)" -ForegroundColor Green
}

# ---------- Resource Catalog ----------

function Init-ResourceCatalogCli([string]$cliPackage,[string]$destDir) {
    Write-Host "Extracting Resource Catalog CLI from $cliPackage ..."
    $migratorDir = Join-Path $destDir "migrator"
    Expand-Archive -Path $cliPackage -DestinationPath $migratorDir -Force
    $script:rc_cliPath = Join-Path $migratorDir "UiPath.ResourceCatalogService.CLI.exe"
    if (-not (Test-Path $script:rc_cliPath)) {
        $found = Get-ChildItem $migratorDir -Filter "UiPath.ResourceCatalogService.CLI.exe" -Recurse | Select-Object -First 1
        if ($found) { $script:rc_cliPath = $found.FullName }
        else { throw "UiPath.ResourceCatalogService.CLI.exe not found in $cliPackage" }
    }
    Write-Host "  Resource Catalog CLI: $script:rc_cliPath" -ForegroundColor Green
}

function Run-ResourceCatalogImportData([string]$orchConnStr,[string]$rcConnStr,[string]$workDir) {
    Write-Host "Running Resource Catalog CLI --import-data ..."
    $configPath = Join-Path $workDir "config"
    New-Item -ItemType Directory -Path $configPath -Force | Out-Null
    Set-Content -Path (Join-Path $configPath "rcsConnectionString")  -Value $rcConnStr   -Force
    Set-Content -Path (Join-Path $configPath "orchConnectionString") -Value $orchConnStr -Force
    $cliArgs = "--config-file `"$configPath`" --import-data"
    $proc = Start-Process $script:rc_cliPath -ArgumentList $cliArgs -Wait -NoNewWindow -PassThru
    Write-Host "  RC CLI exit code: $($proc.ExitCode)"
    if ($proc.ExitCode) { throw "Resource Catalog CLI --import-data failed, exit $($proc.ExitCode)" }
}

function Set-RcCorsPolicy([string]$rgName,[string]$svcName,[string]$identityServerUrl) {
    $idUri = [System.Uri]$identityServerUrl
    $origin = "{0}://{1}" -f $idUri.Scheme,$idUri.Host
    Write-Host "Setting CORS policy on $svcName -- allowed origin: $origin ..."
    $props = @{ cors = @{ allowedOrigins = @($origin) } }
    try {
        Set-AzResource -ResourceGroupName $rgName -ResourceType "Microsoft.Web/sites/config" `
            -ResourceName "$svcName/web" -Properties $props -ApiVersion "2015-08-01" -Force | Out-Null
        Write-Host "  CORS policy set." -ForegroundColor Green
    } catch {
        Write-Warning "Failed to set CORS policy on $svcName : $($_.Exception.Message)"
    }
}

# ============================================================================
# Section: Zip utilities
# ============================================================================

function Extract-DirectoryFromZip([string]$zip,[string]$directory,[string]$destination,[switch]$preserveStructure) {
    [Void][Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem')
    if (![System.IO.Path]::IsPathRooted($destination)){throw "Destination must be absolute: $destination"}
    if (!(Test-Path $destination)){New-Item -ItemType Directory -Path $destination | Out-Null}
    $zf=[System.IO.Compression.ZipFile]::OpenRead($zip)
    $pat=if($directory.EndsWith('/')){"${directory}*"}else{"${directory}/*"}
    foreach($e in $zf.Entries){
        if($e.FullName -like $pat){
            $isDir=!$e.Name
            $dest=(Join-Path $destination $e.FullName) -replace "\\","/"
            if(!$preserveStructure){$pre=$directory -replace '\*','.+'; $dest=$dest -replace $pre,''}
            if($isDir){if(!(Test-Path $dest)){New-Item -ItemType Directory -Path $dest|Out-Null}}
            else{
                $pd=Split-Path $dest -Parent
                if(!(Test-Path $pd)){New-Item -ItemType Directory -Path $pd|Out-Null}
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e,$dest,$true)
            }
        }
    }
    $zf.Dispose()
}

function Extract-FilesFromZip([string]$zip,[string]$destinationFolder,[string]$filePattern) {
    [Void][Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem')
    if(!(Test-Path $destinationFolder)){New-Item -ItemType Directory -Path $destinationFolder|Out-Null}
    $zf=[System.IO.Compression.ZipFile]::OpenRead($zip)
    foreach($e in $zf.Entries){
        if(!$filePattern -or $e.FullName -like $filePattern){
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e,(Join-Path $destinationFolder $e.Name),$true)
        }
    }
    $zf.Dispose()
}

function Get-ZipRootFolder([string]$zipPath) {
    [Void][Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem')
    $zf=[System.IO.Compression.ZipFile]::OpenRead($zipPath)
    $root=($zf.Entries[0].FullName -split '/')[0]
    $zf.Dispose(); return $root
}

function Remove-ConfigBuilders([string]$configFilePath) {
    try {
        $doc=(Select-Xml -Path $configFilePath -XPath /).Node
        Select-Xml -Xml $doc -XPath "/configuration/configSections/section[@name='configBuilders']"|Select-Object -ExpandProperty Node|ForEach-Object{$_.ParentNode.RemoveChild($_)|Out-Null}
        Select-Xml -Xml $doc -XPath "/configuration/configBuilders"|Select-Object -ExpandProperty Node|ForEach-Object{$_.ParentNode.RemoveChild($_)|Out-Null}
        Select-Xml -Xml $doc -XPath "/configuration/*/@configBuilders"|Select-Object -ExpandProperty Node|ForEach-Object{$_.OwnerElement.RemoveAttributeNode($_)|Out-Null}
        $doc.Save($configFilePath)
    } catch { Write-Host "Warning: could not remove configBuilders from '$configFilePath'" }
}

function Prompt-ForContinuation([string]$message="Do you wish to continue?") {
    $v=""
    while($v.ToLowerInvariant() -notin @("y","n")){$v=Read-Host "`n$message (y/n)"}
    return $v.ToLowerInvariant() -eq "y"
}

# ============================================================================
# Section: Backup helpers
# ============================================================================

# Download a single file from an App Service wwwroot via the Kudu VFS REST API.
# Returns $true on success, $false on failure.
function Get-KuduFile([string]$scmBaseUrl,[string]$userName,[string]$password,
                      [string]$remotePath,[string]$localPath) {
    $url   = "$scmBaseUrl/api/vfs/site/wwwroot/$($remotePath.TrimStart('/'))"
    $creds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${userName}:${password}"))
    $hdrs  = @{ Authorization="Basic $creds"; Accept="application/octet-stream" }
    try {
        Invoke-WebRequest -Uri $url -Headers $hdrs -OutFile $localPath -UseBasicParsing -ErrorAction Stop
        return $true
    } catch {
        Write-Warning "Kudu VFS download failed ($url): $($_.Exception.Message)"
        return $false
    }
}

# Save all Azure App Settings for one service to a JSON file and highlight
# any encryption-sensitive keys in the console output.
function Backup-ServiceAppSettings([string]$rgName,[string]$svcName,[string]$slotName,
                                    [string]$label,[string]$outputDir) {
    Write-Host "  Backing up $label app settings ($svcName) ..." -ForegroundColor Cyan
    try {
        $settings = @{}
        if ($slotName -and $slotName -ne "Production") {
            (Get-AzWebAppSlot -ResourceGroupName $rgName -Name $svcName -Slot $slotName -ErrorAction Stop).SiteConfig.AppSettings |
                ForEach-Object { $settings[$_.Name] = $_.Value }
        } else {
            (Get-AzWebApp -ResourceGroupName $rgName -Name $svcName -ErrorAction Stop).SiteConfig.AppSettings |
                ForEach-Object { $settings[$_.Name] = $_.Value }
        }
        $outFile = Join-Path $outputDir "$label-AppSettings.json"
        $settings | ConvertTo-Json -Depth 5 | Out-File $outFile -Encoding utf8 -Force
        Write-Host "    Saved: $outFile" -ForegroundColor Green

        # Highlight encryption-sensitive keys so the operator sees them immediately
        $encKeys = @($settings.Keys | Where-Object { $_ -imatch 'encrypt|DatabaseProtection' } | Sort-Object)
        if ($encKeys.Count -gt 0) {
            Write-Host "    *** Encryption-sensitive keys in $label :" -ForegroundColor Yellow
            foreach ($k in $encKeys) {
                $v = $settings[$k]
                $masked = if ($v -and $v.Length -gt 8) { $v.Substring(0,4) + "****" + $v.Substring($v.Length-4) }
                          elseif ($v) { "****" }
                          else { "(empty)" }
                Write-Host "      $k  =  $masked" -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Warning "Failed to backup $label app settings: $($_.Exception.Message)"
    }
}

# Download the live UiPath.Orchestrator.dll.config (or Web.config fallback) from
# the Orchestrator App Service wwwroot via Kudu VFS and extract critical key values.
function Backup-OrchestratorDllConfig([string]$publishSettingsPath,[string]$outputDir) {
    Write-Host "  Downloading live Orchestrator config via Kudu VFS ..." -ForegroundColor Cyan
    try {
        $ps      = Read-WDPublishSettings $publishSettingsPath
        # PublishUrl may carry a port suffix (e.g. "app.scm.azurewebsites.net:443") -- strip it.
        $scmBase = "https://$($ps.PublishUrl -replace ':\d+$','')"
        $local   = Join-Path $outputDir "Orchestrator-dll.config"

        $ok = Get-KuduFile -scmBaseUrl $scmBase -userName $ps.UserName -password $ps.Password `
                            -remotePath "UiPath.Orchestrator.dll.config" -localPath $local
        if (-not $ok) {
            # Older deployments use Web.config instead
            $ok = Get-KuduFile -scmBaseUrl $scmBase -userName $ps.UserName -password $ps.Password `
                                -remotePath "Web.config" -localPath $local
        }
        if (-not $ok) {
            Write-Warning "Could not download config file from Orchestrator wwwroot."
            Write-Host "    TIP: Download manually from $scmBase/api/vfs/site/wwwroot/UiPath.Orchestrator.dll.config" -ForegroundColor Yellow
            return
        }
        Write-Host "    Saved: $local" -ForegroundColor Green

        # Parse the XML and surface the keys the operator must protect
        try {
            [xml]$cfg = Get-Content $local
            $encKey = $cfg.SelectSingleNode("//secureAppSettings/add[@key='EncryptionKey']/@value")
            if ($encKey -and $encKey.Value) {
                $v = $encKey.Value
                $masked = if ($v.Length -gt 8) { $v.Substring(0,4) + "****" + $v.Substring($v.Length-4) } else { "****" }
                Write-Host "    *** EncryptionKey (secureAppSettings): $masked" -ForegroundColor Yellow
            } else {
                Write-Host "    *** EncryptionKey not found in secureAppSettings (may be in Azure App Settings)." -ForegroundColor Yellow
            }
            $mk = $cfg.SelectSingleNode("//system.web/machineKey")
            if ($mk) {
                Write-Host "    *** MachineKey decryption    : $($mk.decryption)" -ForegroundColor Yellow
                $dkM = if ($mk.decryptionKey -and $mk.decryptionKey.Length -gt 8) { $mk.decryptionKey.Substring(0,4) + "****" } else { $mk.decryptionKey }
                Write-Host "    *** MachineKey decryptionKey : $dkM" -ForegroundColor Yellow
                $vkM = if ($mk.validationKey -and $mk.validationKey.Length -gt 8) { $mk.validationKey.Substring(0,4) + "****" } else { $mk.validationKey }
                Write-Host "    *** MachineKey validationKey : $vkM" -ForegroundColor Yellow
            }
        } catch {
            Write-Warning "Could not parse downloaded config XML: $($_.Exception.Message)"
        }
    } catch {
        Write-Warning "Backup-OrchestratorDllConfig failed: $($_.Exception.Message)"
    }
}

# Compile a consolidated CriticalKeys-Summary.json from every backed-up file.
# All encryption-sensitive settings from App Settings JSON files and the
# Orchestrator dll.config (EncryptionKey + MachineKey) are collected here.
function Write-CriticalKeysSummary([string]$outputDir) {
    $rows = [System.Collections.Generic.List[object]]::new()

    # Collect from per-service App Settings JSON backups
    foreach ($f in (Get-ChildItem $outputDir -Filter "*-AppSettings.json" -ErrorAction SilentlyContinue)) {
        $svc = $f.BaseName -replace '-AppSettings',''
        try {
            $raw = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $raw.PSObject.Properties |
                Where-Object { $_.Name -imatch 'encrypt|DatabaseProtection' } |
                ForEach-Object { $rows.Add([PSCustomObject]@{ Service=$svc; Key=$_.Name; Value=$_.Value }) }
        } catch { Write-Warning "Could not read $($f.Name) for summary: $($_.Exception.Message)" }
    }

    # Collect from the downloaded Orchestrator config file
    $dllCfg = Join-Path $outputDir "Orchestrator-dll.config"
    if (Test-Path $dllCfg) {
        try {
            [xml]$xml = Get-Content $dllCfg
            $n = $xml.SelectSingleNode("//secureAppSettings/add[@key='EncryptionKey']/@value")
            if ($n -and $n.Value) {
                $rows.Add([PSCustomObject]@{ Service="Orchestrator-DllConfig"; Key="EncryptionKey"; Value=$n.Value })
            }
            $mk = $xml.SelectSingleNode("//system.web/machineKey")
            if ($mk) {
                $rows.Add([PSCustomObject]@{ Service="Orchestrator-DllConfig"; Key="MachineKey.decryption";    Value=$mk.decryption })
                $rows.Add([PSCustomObject]@{ Service="Orchestrator-DllConfig"; Key="MachineKey.decryptionKey"; Value=$mk.decryptionKey })
                $rows.Add([PSCustomObject]@{ Service="Orchestrator-DllConfig"; Key="MachineKey.validation";    Value=$mk.validation })
                $rows.Add([PSCustomObject]@{ Service="Orchestrator-DllConfig"; Key="MachineKey.validationKey"; Value=$mk.validationKey })
            }
        } catch { Write-Warning "Could not parse dll.config for summary: $($_.Exception.Message)" }
    }

    $summaryFile = Join-Path $outputDir "CriticalKeys-Summary.json"
    $rows | ConvertTo-Json -Depth 5 | Out-File $summaryFile -Encoding utf8 -Force
    Write-Host "`n  *** Critical keys summary -> $summaryFile" -ForegroundColor Yellow

    # Print a masked table to the console for quick review
    if ($rows.Count -gt 0) {
        Write-Host "`n  Encryption key inventory (values masked for display):" -ForegroundColor Yellow
        Write-Host ("  {0,-30} {1,-60} {2}" -f "Service","Key","Value(masked)") -ForegroundColor Yellow
        Write-Host ("  " + "-"*100) -ForegroundColor Yellow
        foreach ($r in $rows) {
            $v = $r.Value
            $masked = if ($v -and $v.Length -gt 8) { $v.Substring(0,4) + "****" + $v.Substring($v.Length-4) }
                      elseif ($v) { "****" }
                      else { "(empty)" }
            Write-Host ("  {0,-30} {1,-60} {2}" -f $r.Service, $r.Key, $masked) -ForegroundColor Yellow
        }
    } 
    else {
        Write-Host "(No encryption-sensitive keys found in backup -- verify manually.)" -ForegroundColor Red
    }
}

# Orchestrate the full pre-deployment backup for every active service.
# Called once at the start of Main, before any package deployments or DB changes.
function Backup-AllWebAppSettings {
    if ($skipBackup) {
        Write-Host "[-skip-] Pre-deployment backup skipped (-skipBackup was set)." -ForegroundColor Yellow
        Write-Host "         WARNING: If encryption keys are lost after this upgrade there will be no backup to recover from." -ForegroundColor Red
        return
    }

    $ts  = Get-Date -Format "yyyyMMdd-HHmmss"
    $dir = if ($backupOutputPath) { $backupOutputPath }
           else { Join-Path $PSScriptRoot "backups\$orchAppServiceName-$ts" }

    Write-Host "`n====== Pre-deployment settings backup ======" -ForegroundColor Cyan
    Write-Host "Backup folder: $dir" -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    # Always back up Orchestrator (required parameter -- always present)
    Backup-ServiceAppSettings -rgName $orchResourceGroupName -svcName $orchAppServiceName `
        -slotName $orchProductionSlotName -label "Orchestrator" -outputDir $dir
    # Download the live dll.config from wwwroot -- this is where EncryptionKey lives
    Backup-OrchestratorDllConfig -publishSettingsPath $script:orch_publishSettingsPath -outputDir $dir

    # Identity Server -- EncryptionSettings__EncryptionKey lives here
    if ($script:deployIdentity -and $identityResourceGroupName -and $identityAppServiceName) {
        Backup-ServiceAppSettings -rgName $identityResourceGroupName -svcName $identityAppServiceName `
            -slotName $script:identity_deploymentSlotName -label "IdentityServer" -outputDir $dir
    }

    # Resource Catalog
    if ($script:deployResourceCatalog -and $resourceCatalogResourceGroupName -and $resourceCatalogAppServiceName) {
        Backup-ServiceAppSettings -rgName $resourceCatalogResourceGroupName -svcName $resourceCatalogAppServiceName `
            -slotName $script:rc_deploymentSlotName -label "ResourceCatalog" -outputDir $dir
    }

    # Webhooks
    if ($script:deployWebhooks -and $webhooksResourceGroupName -and $webhooksAppServiceName) {
        Backup-ServiceAppSettings -rgName $webhooksResourceGroupName -svcName $webhooksAppServiceName `
            -slotName $script:wh_deploymentSlotName -label "Webhooks" -outputDir $dir
    }

    # Write the consolidated critical-keys summary
    Write-CriticalKeysSummary -outputDir $dir

    Write-Host "`n====== Backup complete ======" -ForegroundColor Green
    Write-Host "IMPORTANT: Verify $dir\CriticalKeys-Summary.json before proceeding." -ForegroundColor Yellow
    Write-Host "           These values MUST be preserved -- if lost after the upgrade, encryption" -ForegroundColor Yellow
    Write-Host "           of sensitive data in the database will break and cannot be recovered." -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================================
# Section: Set-ScriptConstants  (Orchestrator initialisation)
# ============================================================================

function Set-ScriptConstants {

    $script:orch_msDeployExe = Join-Path ${env:ProgramFiles(x86)} "IIS\Microsoft Web Deploy V3\msdeploy.exe"

    AuthenticateToAzure

    $script:tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "uipath-deploy-$(Get-Date -f 'yyyyMMddhhmmssfff')"
    New-Item -ItemType Directory -Path $script:tempDirectory | Out-Null

    # ---- Orchestrator paths ----
    $script:orch_publishSettingsPath = Join-Path $script:tempDirectory "$orchAppServiceName.PublishSettings"
    $script:orch_webConfigPath       = Join-Path $script:tempDirectory "Web.config"
    $script:orch_parametersXmlPath   = Join-Path $script:tempDirectory "parameters.xml"

    # Extract config type from Orchestrator package
    $payloadTemp=Join-Path $ENV:TEMP "OrchestratorPkg_$(Get-Date -f 'yyyyMMddhhmmssfff')"
    Extract-FilesFromZip -zip $orchPackage -destinationFolder $payloadTemp -filePattern "Content/*/bin/win-x64/publish/UiPath.Orchestrator.dll.config"
    if (Test-Path "$payloadTemp/UiPath.Orchestrator.dll.config") {
        $script:orch_newConfigName         = "UiPath.Orchestrator.dll.config"
        $script:orch_webArchiveContentPath = "Content/*/bin/win-x64/publish/"
    } else {
        Extract-FilesFromZip -zip $orchPackage -destinationFolder $payloadTemp -filePattern "Content/*/obj/Release/Package/PackageTmp/web.config"
        $script:orch_newConfigName         = "Web.config"
        $script:orch_webArchiveContentPath = "Content/*/obj/Release/Package/PackageTmp/"
    }
    Extract-DirectoryFromZip -zip $orchPackage -directory $script:orch_webArchiveContentPath -destination "$payloadTemp/"
    $script:orch_cliToolPath = Join-Path "$payloadTemp/Tools/Cli/" "UiPath.Orchestrator.Cli.exe"
    $script:orch_newConfigPath = Join-Path $payloadTemp $script:orch_newConfigName
    New-OrchestratorConfigFiles -tempDirectory $script:tempDirectory

    $script:orch_defaultFolderstoSkip = @("\\App_Data")
    $script:orch_defaultFilesToSkip   = @()
    $script:orch_hotswap              = $false

    # Publish profile for Orchestrator (production slot first -- to check pending migrations)
    Get-ServicePublishProfile -resourceGroupName $orchResourceGroupName -appServiceName $orchAppServiceName `
        -slotName $orchProductionSlotName -outputPath $script:orch_publishSettingsPath

    $script:orch_updateProductionDatabase = $true

    if ($orchStandbySlotName) {
        $script:orch_ftpPublishProfile = Read-FtpPublishProfile $script:orch_publishSettingsPath
        New-OrchestratorConfigFiles -tempDirectory $script:tempDirectory

        $pubSettings=Read-WDPublishSettings $script:orch_publishSettingsPath
        $orchMigSettings=@{
            SQLDBConnectionString=([xml](Get-Content $script:orch_publishSettingsPath)).SelectNodes("//publishData//publishProfile[@publishMethod='MSDeploy']//databases//add[@name='Default']/@connectionString").value
        }

        $pending=Get-PendingMigrations -connectionString $orchMigSettings.SQLDBConnectionString -webConfigPath $script:orch_webConfigPath -configMigration 'Default'
        if ($pending) { Write-Host "Pending migrations for production database." } else { $script:orch_updateProductionDatabase=$false }

        Get-ServicePublishProfile -resourceGroupName $orchResourceGroupName -appServiceName $orchAppServiceName `
            -slotName $orchStandbySlotName -outputPath $script:orch_publishSettingsPath
        $script:orch_hotswap=$true
    }

    $script:orch_deploymentSlotName = if ($script:orch_hotswap) { $orchStandbySlotName } else { $orchProductionSlotName }
    $script:orch_fullAppServiceName = "$orchAppServiceName-$script:orch_deploymentSlotName"
    $script:orch_ftpPublishProfile  = Read-FtpPublishProfile $script:orch_publishSettingsPath

    # Persist scalar settings to script scope
    $script:orch_storageType=$storageType; $script:orch_storageLocation=$storageLocation
    $script:orch_packagesApiKey=$packagesApiKey; $script:orch_activitiesApiKey=$activitiesApiKey
    $script:orch_redisConnectionString=$redisConnectionString; $script:orch_loadBalancerUseRedis=$loadBalancerUseRedis
    $script:orch_robotsElasticSearchUrl=$robotsElasticSearchUrl; $script:orch_robotsElasticSearchUsername=$robotsElasticSearchUsername
    $script:orch_robotsElasticSearchPassword=$robotsElasticSearchPassword; $script:orch_robotsElasticSearchTargets=$robotsElasticSearchTargets
    $script:orch_serverElasticSearchUrl=$serverElasticSearchUrl; $script:orch_serverElasticSearchDiagnosticsUsername=$serverElasticSearchDiagnosticsUsername
    $script:orch_serverElasticSearchDiagnosticsPassword=$serverElasticSearchDiagnosticsPassword
    $script:orch_serverElasticSearchIndex=$serverElasticSearchIndex; $script:orch_serverDefaultTargets=$serverDefaultTargets
    $script:orch_azureSignalRConnectionString=$azureSignalRConnectionString
    $script:orch_bucketsFileSystemAllowlist=$bucketsFileSystemAllowlist; $script:orch_bucketsAvailableProviders=$bucketsAvailableProviders
    $script:orch_deployMethod=$deployMethod; $script:orch_runPackageMigrator=$false

    Extract-FilesFromZip -zip $orchPackage -destinationFolder $script:tempDirectory -filePattern "parameters.xml"
    $pXml=New-Object System.Xml.XmlDocument; $pXml.Load($script:orch_parametersXmlPath)
    $script:orch_defaultParameterXmlValues=@{}
    $pXml.SelectNodes("/parameters/*") | ForEach-Object { if($_.defaultValue){$script:orch_defaultParameterXmlValues[$_.Name]=$_.defaultValue} if($_.value){$script:orch_defaultParameterXmlValues[$_.Name]=$_.value} }

    if ($redisConnectionString) { $script:orch_loadBalancerUseRedis="true" }
    $script:orch_existingProdAppSettings=Read-ExistingSlotAppSettings -rgName $orchResourceGroupName -svcName $orchAppServiceName -slotName $orchProductionSlotName

    switch ($action) {
        "Update" {
            New-OrchestratorConfigFiles -tempDirectory $script:tempDirectory
            if (!$packagesApiKey) { $script:orch_packagesApiKey=Get-WDParameterValue "apiKey" $script:orch_parametersXmlPath $script:orch_webConfigPath }
            if (!$activitiesApiKey) { $script:orch_activitiesApiKey=Get-WDParameterValue "activitiesApiKey" $script:orch_parametersXmlPath $script:orch_webConfigPath }
            $script:orch_decryption  =Get-WDParameterValue "machineKeyDecryption" $script:orch_parametersXmlPath $script:orch_webConfigPath
            $script:orch_decryptionKey=Get-WDParameterValue "machineKeyDecryptionKey" $script:orch_parametersXmlPath $script:orch_webConfigPath
            $script:orch_validation  =Get-WDParameterValue "machineKeyValidation" $script:orch_parametersXmlPath $script:orch_webConfigPath
            $script:orch_validationKey=Get-WDParameterValue "machineKeyValidationKey" $script:orch_parametersXmlPath $script:orch_webConfigPath
            $script:orch_encryptionKey=Get-WDParameterValue "EncryptionKey" $script:orch_parametersXmlPath $script:orch_webConfigPath
            if (!$storageType) { $script:orch_storageType=Get-WDParameterValue "storageType" $script:orch_parametersXmlPath $script:orch_webConfigPath }
            if (!$script:orch_storageType) { $script:orch_storageType=$script:orch_defaultParameterXmlValues."storageType" }
            if (!$storageLocation) { $script:orch_storageLocation=Get-WDParameterValue "storageLocation" $script:orch_parametersXmlPath $script:orch_webConfigPath }
            if (!$script:orch_storageLocation) { $script:orch_storageLocation=$script:orch_defaultParameterXmlValues."storageLocation" }
            if (!$redisConnectionString) {
                $script:orch_redisConnectionString=Get-WDParameterValue "loadBalancerRedisConnectionString" $script:orch_parametersXmlPath $script:orch_webConfigPath
                if (!$loadBalancerUseRedis) { $script:orch_loadBalancerUseRedis=Get-WDParameterValue "loadBalancerUseRedis" $script:orch_parametersXmlPath $script:orch_webConfigPath }
            }
            if (!$robotsElasticSearchUrl)      { $script:orch_robotsElasticSearchUrl     =Get-WDParameterValue "ElasticSearchUrl"               $script:orch_parametersXmlPath $script:orch_webConfigPath }
            if (!$robotsElasticSearchUsername)  { $script:orch_robotsElasticSearchUsername=Get-WDParameterValue "ElasticSearchUsername"           $script:orch_parametersXmlPath $script:orch_webConfigPath }
            if (!$robotsElasticSearchPassword)  { $script:orch_robotsElasticSearchPassword=Get-WDParameterValue "ElasticSearchPassword"           $script:orch_parametersXmlPath $script:orch_webConfigPath }
            if (!$robotsElasticSearchTargets)   { $script:orch_robotsElasticSearchTargets =Get-WDParameterValue "ElasticSearchLogger"             $script:orch_parametersXmlPath $script:orch_webConfigPath }
            if (!$serverElasticSearchUrl)       { $script:orch_serverElasticSearchUrl     =Get-WDParameterValue "elasticSearchDiagnosticsUrl"     $script:orch_parametersXmlPath $script:orch_webConfigPath }
            if (!$serverElasticSearchDiagnosticsUsername) { $script:orch_serverElasticSearchDiagnosticsUsername=Get-WDParameterValue "elasticSearchDiagnosticsUsername" $script:orch_parametersXmlPath $script:orch_webConfigPath }
            if (!$serverElasticSearchDiagnosticsPassword) { $script:orch_serverElasticSearchDiagnosticsPassword=Get-WDParameterValue "elasticSearchDiagnosticsPassword" $script:orch_parametersXmlPath $script:orch_webConfigPath }
            if (!$serverElasticSearchIndex)     { $script:orch_serverElasticSearchIndex   =Get-WDParameterValue "elasticSearchDiagnosticsIndex"   $script:orch_parametersXmlPath $script:orch_webConfigPath }
            if (!$serverDefaultTargets)         { $script:orch_serverDefaultTargets        =Get-WDParameterValue "serverDefaultTargets"            $script:orch_parametersXmlPath $script:orch_webConfigPath }
            if (!$azureSignalRConnectionString)  { $script:orch_azureSignalRConnectionString=Get-WDParameterValue "azureSignalRConnectionString"   $script:orch_parametersXmlPath $script:orch_webConfigPath }
            if (!$bucketsFileSystemAllowlist)    { $script:orch_bucketsFileSystemAllowlist =Get-WDParameterValue "bucketsFileSystemAllowlist"       $script:orch_parametersXmlPath $script:orch_webConfigPath }
            if (!$bucketsAvailableProviders)     { $script:orch_bucketsAvailableProviders  =Get-WDParameterValue "bucketsAvailableProviders"        $script:orch_parametersXmlPath $script:orch_webConfigPath }
            $nugetType=Get-SettingFromConfig "NuGet.Repository.Type" $script:orch_webConfigPath
            $pkgUrl  =Get-SettingFromConfig "NuGet.Packages.Path"    $script:orch_webConfigPath
            $actUrl  =Get-SettingFromConfig "NuGet.Activities.Path"  $script:orch_webConfigPath
            if (($nugetType -eq "Legacy") -or (!$nugetType -and $pkgUrl -and $actUrl)) {
                $script:orch_runPackageMigrator=$true
                $script:orch_instanceKey=Get-SettingFromConfig "InstanceKey" $script:orch_webConfigPath
                if (!$script:orch_instanceKey) { $script:orch_instanceKey=Generate-Guid }
                $script:orch_nugetRepositoryType=$nugetType; $script:orch_packagesUrl=$pkgUrl; $script:orch_activitiesUrl=$actUrl
            }
        }
        "Deploy" {
            $script:orch_packagesApiKey   = if ($packagesApiKey)   { $packagesApiKey }   else { Generate-Guid }
            $script:orch_activitiesApiKey = if ($activitiesApiKey) { $activitiesApiKey } else { $script:orch_packagesApiKey }
            if (!$storageType)    { $script:orch_storageType    = $script:orch_defaultParameterXmlValues."storageType" }
            if (!$storageLocation){ $script:orch_storageLocation= $script:orch_defaultParameterXmlValues."storageLocation" }
        }
    }

    # ---- Identity Server paths ----
    $script:deployIdentity = ($identityPackage -and $identityAppServiceName -and $identityResourceGroupName)
    if ($script:deployIdentity) {
        $script:identity_tempDirectory       = Join-Path $script:tempDirectory "Identity"
        New-Item -ItemType Directory -Path $script:identity_tempDirectory | Out-Null
        $script:identity_publishSettingsPath = Join-Path $script:identity_tempDirectory "$identityAppServiceName.PublishSettings"
        $script:identity_deploymentSlotName  = if ($identitySlotName) { $identitySlotName } else { $identityProductionSlotName }
        # Extract Identity CLI
        if ($identityCliPackage) {
            $cliDest=Join-Path $script:identity_tempDirectory "DataMigratorCli"
            Expand-Archive -Path $identityCliPackage -DestinationPath $cliDest -Force
            $script:identity_cliPath=Join-Path $cliDest "DataMigratorCli\UiPath.DataMigrator.Cli.exe"
            if (-not (Test-Path $script:identity_cliPath)) {
                # Fallback: find the exe anywhere in the extract
                $found=Get-ChildItem $cliDest -Filter "UiPath.DataMigrator.Cli.exe" -Recurse | Select-Object -First 1
                if ($found) { $script:identity_cliPath=$found.FullName }
            }
        }
        Get-ServicePublishProfile -resourceGroupName $identityResourceGroupName -appServiceName $identityAppServiceName `
            -slotName $script:identity_deploymentSlotName -outputPath $script:identity_publishSettingsPath
    }

    # ---- Resource Catalog paths ----
    $script:deployResourceCatalog = ($resourceCatalogPackage -and $resourceCatalogAppServiceName -and $resourceCatalogResourceGroupName)
    if ($script:deployResourceCatalog) {
        $script:rc_tempDirectory       = Join-Path $script:tempDirectory "ResourceCatalog"
        New-Item -ItemType Directory -Path $script:rc_tempDirectory | Out-Null
        $script:rc_publishSettingsPath = Join-Path $script:rc_tempDirectory "$resourceCatalogAppServiceName.PublishSettings"
        $script:rc_deploymentSlotName  = if ($resourceCatalogSlotName) { $resourceCatalogSlotName } else { $resourceCatalogProductionSlotName }
        Get-ServicePublishProfile -resourceGroupName $resourceCatalogResourceGroupName -appServiceName $resourceCatalogAppServiceName `
            -slotName $script:rc_deploymentSlotName -outputPath $script:rc_publishSettingsPath
    }

    # ---- Webhooks paths ----
    $script:deployWebhooks = ($webhooksPackage -and $webhooksAppServiceName -and $webhooksResourceGroupName)
    if ($script:deployWebhooks) {
        $script:wh_tempDirectory       = Join-Path $script:tempDirectory "Webhooks"
        New-Item -ItemType Directory -Path $script:wh_tempDirectory | Out-Null
        $script:wh_publishSettingsPath = Join-Path $script:wh_tempDirectory "$webhooksAppServiceName.PublishSettings"
        $script:wh_deploymentSlotName  = if ($webhooksSlotName) { $webhooksSlotName } else { $webhooksProductionSlotName }
        Get-ServicePublishProfile -resourceGroupName $webhooksResourceGroupName -appServiceName $webhooksAppServiceName `
            -slotName $script:wh_deploymentSlotName -outputPath $script:wh_publishSettingsPath
    }
}

# ============================================================================
# Section: Validate-Parameters
# ============================================================================

function Validate-Parameters {
    if ($deployMethod -eq "MsDeploy" -and -not (Test-Path $script:orch_msDeployExe)) {
        Write-Error "msdeploy.exe not found at '$($script:orch_msDeployExe)'. Install Web Deploy V3 or use -deployMethod KuduZipDeploy."
        Exit 1
    }
    $validStorage=@("FileSystem","Azure","Minio","Amazon")
    if ($script:orch_storageType -and $validStorage -notcontains $script:orch_storageType) {
        Write-Error "-storageType '$($script:orch_storageType)' is invalid. Valid: $validStorage"; Exit 1
    }
    if ($action -eq "Update") {
        if (-not $script:orch_storageLocation)    { Write-Error "storageLocation is required for Update."; Exit 1 }
        if (-not $script:orch_packagesApiKey)      { Write-Error "packagesApiKey is required for Update."; Exit 1 }
        if (-not $confirmBlockClassicExecutions)   { Write-Error "-confirmBlockClassicExecutions is required for Update."; Exit 1 }
    }
    if ($action -eq "Deploy") {
        if ($script:deployIdentity -and -not $identityServerUrl) {
            Write-Error "-identityServerUrl is required for a Deploy action when -identityPackage is specified."; Exit 1
        }
        if ($script:deployIdentity -and -not $identityCliPackage) {
            Write-Error "-identityCliPackage is required when -identityPackage is specified."; Exit 1
        }
        if ($script:deployResourceCatalog -and -not $resourceCatalogUrl) {
            Write-Error "-resourceCatalogUrl is required for a Deploy action when -resourceCatalogPackage is specified."; Exit 1
        }
    }
    if ($script:orch_bucketsAvailableProviders -like '*FileSystem*' -and -not $script:orch_bucketsFileSystemAllowlist) {
        Write-Error "-bucketsFileSystemAllowlist is required when FileSystem is in -bucketsAvailableProviders."; Exit 1
    }
}

# ============================================================================
# Section: Auto-detect companion URLs from Orchestrator app settings (Update)
# ============================================================================

function Resolve-CompanionUrls {
    # Identity Server URL
    $script:resolvedIdentityServerUrl = if ($identityServerUrl) { $identityServerUrl }
        else { Get-AppSettingFromAzure "IdentityServer.Integration.Authority" $orchResourceGroupName $orchAppServiceName }

    # Resource Catalog URL + enabled flag
    $rcEnabled = Get-AppSettingFromAzure "ResourceCatalogService.Integration.Enabled" $orchResourceGroupName $orchAppServiceName
    if ($rcEnabled -eq "false") {
        Write-Host "ResourceCatalogService.Integration.Enabled = false -- skipping Resource Catalog." -ForegroundColor Yellow
        $script:deployResourceCatalog = $false
    }
    $script:resolvedResourceCatalogUrl = if ($resourceCatalogUrl) { $resourceCatalogUrl }
        else { Get-AppSettingFromAzure "ResourceCatalogService.ServiceURL" $orchResourceGroupName $orchAppServiceName }

    # Webhooks enabled flag
    $whEnabled = Get-AppSettingFromAzure "Webhooks.LedgerIntegration.Enabled" $orchResourceGroupName $orchAppServiceName
    if ($whEnabled -eq "false") {
        Write-Host "Webhooks.LedgerIntegration.Enabled = false -- skipping Webhooks." -ForegroundColor Yellow
        $script:deployWebhooks = $false
    }

    # Orchestrator URL (for Identity seed migrator)
    $script:resolvedOrchestratorUrl = if ($orchestratorUrl) { $orchestratorUrl }
        else { $app=Get-AzWebApp -ResourceGroupName $orchResourceGroupName -Name $orchAppServiceName; "https://$($app.HostNames | Select-Object -First 1)" }

    Write-Host "Resolved URLs:" -ForegroundColor Cyan
    Write-Host "  Orchestrator   : $script:resolvedOrchestratorUrl"
    Write-Host "  Identity Server: $script:resolvedIdentityServerUrl"
    Write-Host "  Resource Catalog: $script:resolvedResourceCatalogUrl"
    Write-Host "  Deploy Identity : $script:deployIdentity"
    Write-Host "  Deploy RC       : $script:deployResourceCatalog"
    Write-Host "  Deploy Webhooks : $script:deployWebhooks"
}

# ============================================================================
# Section: Update-AllDatabases  (Orchestrator)
# ============================================================================

function Update-AllDatabases($migSettings) {
    $cfgPath=$script:orch_webConfigPath
    Write-Host "Setting UpdateServer.ModuleEnabled = $updateServerFeatureEnabled"
    Set-SettingValue -settingName "UpdateServer.ModuleEnabled" -settingValue "$updateServerFeatureEnabled" -webConfigPath $cfgPath
    Write-Host "Setting Insights.ModuleEnabled = $insightsFeatureEnabled"
    Set-SettingValue -settingName "Insights.ModuleEnabled"     -settingValue "$insightsFeatureEnabled"     -webConfigPath $cfgPath

    if ($script:orch_updateProductionDatabase) {
        Run-DatabaseMigrations "Default" $migSettings.SQLDBConnectionString -configFilePath $cfgPath
        if ($testAutomationFeatureEnabled -and $migSettings.SQLTestAutomationDBConnectionString) {
            Run-DatabaseMigrations "TestAutomation" $migSettings.SQLTestAutomationDBConnectionString $migSettings.SQLDBConnectionString $cfgPath
        }
        if ($updateServerFeatureEnabled -and $migSettings.SQLUpdateServerDBConnectionString) {
            Run-DatabaseMigrations "UpdateServer" $migSettings.SQLUpdateServerDBConnectionString -configFilePath $cfgPath
        }
        if ($insightsFeatureEnabled -and $migSettings.SQLInsightsDBConnectionString) {
            Run-DatabaseMigrations "Insights" $migSettings.SQLInsightsDBConnectionString -configFilePath $cfgPath
        }
    } else { Write-Host "Database already up-to-date." }

    Initialize-InternalJobs "Default" $migSettings.SQLDBConnectionString $cfgPath
}

# Build migration settings from publish profile or manual params
function Get-MigrationSettings([string]$publishSettingsPath) {
    if ($publishSettingsPath -and (Test-Path $publishSettingsPath)) {
        [xml]$p=Get-Content -Path $publishSettingsPath
        $ms=@{
            SQLDBConnectionString               =$p.SelectNodes("//publishData//publishProfile[@publishMethod='MSDeploy']//databases//add[@name='Default']/@connectionString").value
            SQLTestAutomationDBConnectionString =$p.SelectNodes("//publishData//publishProfile[@publishMethod='MSDeploy']//databases//add[@name='TestAutomation']/@connectionString").value
            SQLUpdateServerDBConnectionString   =$p.SelectNodes("//publishData//publishProfile[@publishMethod='MSDeploy']//databases//add[@name='UpdateServer']/@connectionString").value
            SQLInsightsDBConnectionString       =$p.SelectNodes("//publishData//publishProfile[@publishMethod='MSDeploy']//databases//add[@name='Insights']/@connectionString").value
        }
        if ($orchConnectionString) { $ms.SQLDBConnectionString=$orchConnectionString }
        return $ms
    }
    return @{
        SQLDBConnectionString               =$orchConnectionString
        SQLTestAutomationDBConnectionString =$orchTestAutomationConnectionString
        SQLUpdateServerDBConnectionString   =$orchUpdateServerConnectionString
        SQLInsightsDBConnectionString       =$orchInsightsConnectionString
    }
}

function Get-IdentityConnectionString([string]$publishSettingsPath) {
    if ($publishSettingsPath -and (Test-Path $publishSettingsPath)) {
        [xml]$p=Get-Content -Path $publishSettingsPath
        return $p.SelectNodes("//publishData//publishProfile[@publishMethod='MSDeploy']//databases//add[@name='Default']/@connectionString").value
    }
    return $null
}

# ============================================================================
# Section: MAIN
# ============================================================================

function Main {

    Ensure-AzureModule
    Initialize-Checkpoint

    # ------------------------------------------------------------------
    # Step 1 - initialise all constants, paths, publish profiles, auth
    # ------------------------------------------------------------------
    if (-not (Start-Step "InitializeConstants")) {
        Set-ScriptConstants
        End-Step "InitializeConstants"
    }

    # ------------------------------------------------------------------
    # Step 2 - validate parameters
    # ------------------------------------------------------------------
    if (-not (Start-Step "ValidateParameters")) {
        Validate-Parameters
        End-Step "ValidateParameters"
    }

    # ------------------------------------------------------------------
    # Step 3 - auto-detect companion URLs (Update mode)
    # ------------------------------------------------------------------
    if ($action -eq "Update") {
        if (-not (Start-Step "ResolveCompanionUrls")) {
            Resolve-CompanionUrls
            End-Step "ResolveCompanionUrls"
        }
    } else {
        # Deploy mode: use provided values directly
        $script:resolvedIdentityServerUrl  = $identityServerUrl
        $script:resolvedResourceCatalogUrl = $resourceCatalogUrl
        $script:resolvedOrchestratorUrl    = if ($orchestratorUrl) { $orchestratorUrl }
            else { $app=Get-AzWebApp -ResourceGroupName $orchResourceGroupName -Name $orchAppServiceName; "https://$($app.HostNames | Select-Object -First 1)" }
    }

    $orchPubSettings  = Read-WDPublishSettings  $script:orch_publishSettingsPath
    $orchMigSettings  = Get-MigrationSettings   $script:orch_publishSettingsPath

    # ------------------------------------------------------------------
    # Step 4 - pre-deployment backup of all service app settings
    #          and live Orchestrator dll.config (EncryptionKey + MachineKey)
    # This runs BEFORE any package deployments or database changes so that
    # a complete recovery reference exists if the upgrade goes wrong.
    # ------------------------------------------------------------------
    if (-not (Start-Step "Backup_AppSettings")) {
        Backup-AllWebAppSettings
        End-Step "Backup_AppSettings"
    }

    # ==================================================================
    # ORCHESTRATOR PIPELINE
    # ==================================================================

    if (-not (Start-Step "Orch_ValidateExtensions")) {
        Invoke-ExtensionsValidation -configFilePath $script:orch_newConfigPath
        End-Step "Orch_ValidateExtensions"
    }

    if ($stopApplicationBeforePublish) {
        if (-not (Start-Step "Orch_StopApplication")) {
            Stop-AzWebAppSlot -ResourceGroupName $orchResourceGroupName -Name $orchAppServiceName -Slot $script:orch_deploymentSlotName | Out-Null
            Write-Host "Stopped $script:orch_fullAppServiceName"; Start-Sleep -Seconds 30
            End-Step "Orch_StopApplication"
        }
    }

    if (-not (Start-Step "Orch_PreValidateDatabase")) {
        Invoke-DatabasePreValidations -databaseType "Default" -connectionString $orchMigSettings.SQLDBConnectionString `
            -configFilePath $script:orch_newConfigPath -ignoreClassicFoldersError ([bool]$allowInstallOverClassicFolders)
        End-Step "Orch_PreValidateDatabase"
    }

    if ($script:orch_runPackageMigrator) {
        Write-Warning "Packages will be migrated from Legacy storage. storageType=$($script:orch_storageType) storageLocation=$($script:orch_storageLocation)"
        if (!$unattended -and !(Prompt-ForContinuation)) { Write-Host "Exiting."; Exit 0 }
        if (-not (Start-Step "Orch_MigratePackagesStart")) {
            Import-Module -Name ".\ps_utils\Migrate-Packages.psm1" -Force `
                -ArgumentList $script:orch_msDeployExe,$script:orch_cliToolPath,$orchPubSettings,$orchMigSettings.SQLDBConnectionString,$script:orch_storageType,$script:orch_storageLocation,$script:orch_activitiesUrl,$script:orch_packagesUrl,$script:orch_instanceKey,$unattended
            Start-PackagesMigration
            End-Step "Orch_MigratePackagesStart"
        }
    }

    if (-not (Start-Step "Orch_DeployPackage")) {
        if (($action -eq "Deploy") -and !$unattended) {
            Write-Warning "Fresh Deploy: all encryption settings will be generated. Do not deploy over an existing site unless intentional."
            if (!(Prompt-ForContinuation)) { Write-Host "Exiting."; Exit 0 }
        }
        $wdParams   = Get-OrchWDParameters
        $skipFolders= $foldersToSkip + $script:orch_defaultFolderstoSkip
        $skipFiles  = $filesToSkip   + $script:orch_defaultFilesToSkip
        Write-Host "WD Parameters:`n$($wdParams|Out-String)" -ForegroundColor Yellow
        if (!$unattended -and !(Prompt-ForContinuation)) { Write-Host "Exiting."; Exit 0 }
        Deploy-ServicePackage -package $orchPackage -publishSettings $orchPubSettings -parameters $wdParams `
            -skipFolders $skipFolders -skipFiles $skipFiles `
            -webArchiveContentPath $script:orch_webArchiveContentPath `
            -configName $script:orch_newConfigName -parametersXmlPath $script:orch_parametersXmlPath
        # Log deployment parameters
        $pubParams = Get-PublishParameters $wdParams
        $pubParams | ConvertTo-Json -Depth 5 | Out-File $orchParametersOutputPath
        Write-Host "Deployment parameters saved to '$orchParametersOutputPath'" -ForegroundColor Yellow
        End-Step "Orch_DeployPackage"
    }

    if (-not (Start-Step "Orch_UpdateDatabases")) {
        if ($action -eq "Deploy") { New-OrchestratorConfigFiles -tempDirectory $script:tempDirectory }
        Update-AllDatabases $orchMigSettings
        End-Step "Orch_UpdateDatabases"
    }

    if ($script:orch_runPackageMigrator) {
        if (-not (Start-Step "Orch_MigratePackagesFinalize")) {
            Finalize-PackagesMigration
            End-Step "Orch_MigratePackagesFinalize"
        }
        $orchAppSettings=Add-AppSetting $orchAppSettings "NuGet.Repository.Type" "Composite"
        $orchAppSettings=Add-AppSetting $orchAppSettings "InstanceKey" $script:orch_instanceKey
    }

    $webAppUrl=if($script:resolvedOrchestratorUrl){$script:resolvedOrchestratorUrl}
        else{$app=Get-AzWebApp -ResourceGroupName $orchResourceGroupName -Name $orchAppServiceName;"https://$($app.HostNames|Select-Object -First 1)"}
    $orchAppSettings=Add-AppSetting $orchAppSettings "OrchestratorRootUrl" $webAppUrl

    if (-not (Start-Step "Orch_ApplyAppSettings")) {
        $existing=Read-ExistingSlotAppSettings -rgName $orchResourceGroupName -svcName $orchAppServiceName -slotName $script:orch_deploymentSlotName
        $merged=if($orchAppSettings){Merge-Hashtables -from (ConvertPsObjectToHashtable $orchAppSettings) -to $existing}else{$existing}
        if ($merged) { Set-AzWebAppSlot -AppSettings $merged -Name $orchAppServiceName -ResourceGroupName $orchResourceGroupName -Slot $script:orch_deploymentSlotName | Out-Null }
        End-Step "Orch_ApplyAppSettings"
    }

    if ($activitiesPackagePath) {
        if (-not (Start-Step "Orch_DeployActivities")) {
            $actTmp=Join-Path $ENV:TEMP "oa_$(Get-Date -f 'yyyyMMddhhmmssffff')"
            Expand-Archive -LiteralPath $activitiesPackagePath -DestinationPath "$actTmp/"
            $legacyDir=Join-Path $actTmp "legacy_$(Get-Date -f 'yyyyMMddhhmmssffff')"
            New-Item $legacyDir -ItemType Directory | Out-Null
            $actDir=Join-Path $legacyDir "Activities"; New-Item $actDir -ItemType Directory | Out-Null
            Get-ChildItem $actTmp | ForEach-Object {
                $info=$_.FullName -match "(.+)\.(\d+\.\d+\.\d+-*.*)$"
                $an=[System.IO.Path]::GetFileNameWithoutExtension($_.Name) -replace "(.+)\.(\d+\.\d+\.\d+-*.*)$","`$1"
                $av=[System.IO.Path]::GetFileNameWithoutExtension($_.Name) -replace "(.+)\.(\d+\.\d+\.\d+-*.*)$","`$2"
                $anDir=Join-Path $actDir $an; if(!(Test-Path $anDir)){New-Item $anDir -ItemType Directory|Out-Null}
                $avDir=Join-Path $anDir $av; if(!(Test-Path $avDir)){New-Item $avDir -ItemType Directory|Out-Null}
                Copy-Item $_.FullName $avDir
            }
            & $script:orch_cliToolPath packages activities --application-path $script:tempDirectory --source-folder $legacyDir
            End-Step "Orch_DeployActivities"
        }
    }

    if ($stopApplicationBeforePublish) {
        if (-not (Start-Step "Orch_StartApplication")) {
            Start-AzWebAppSlot -ResourceGroupName $orchResourceGroupName -Name $orchAppServiceName -Slot $script:orch_deploymentSlotName | Out-Null
            Write-Host "Started $script:orch_fullAppServiceName"
            End-Step "Orch_StartApplication"
        }
    }

    if ($script:orch_hotswap -and -not $stopApplicationBeforePublish) {
        if (-not (Start-Step "Orch_StartStandby")) {
            Start-AzWebAppSlot -ResourceGroupName $orchResourceGroupName -Name $orchAppServiceName -Slot $orchStandbySlotName | Out-Null
            End-Step "Orch_StartStandby"
        }
    }

    if ($autoSwap -and $script:orch_hotswap) {
        if (-not (Start-Step "Orch_SwapSlots")) {
            Switch-AzWebAppSlot -SourceSlotName $orchStandbySlotName -DestinationSlotName $orchProductionSlotName `
                -ResourceGroupName $orchResourceGroupName -Name $orchAppServiceName
            End-Step "Orch_SwapSlots"
        }
        if (-not (Start-Step "Orch_StopStandby")) {
            Stop-AzWebAppSlot -ResourceGroupName $orchResourceGroupName -Name $orchAppServiceName -Slot $orchStandbySlotName | Out-Null
            End-Step "Orch_StopStandby"
        }
    }

    Write-Host "`n====== Orchestrator deployment complete ======`n" -ForegroundColor Green

    # ==================================================================
    # IDENTITY SERVER PIPELINE
    # ==================================================================

    if ($script:deployIdentity) {
        Write-Host "`n====== Deploying Identity Server ======`n" -ForegroundColor Cyan
        $idPubSettings = Read-WDPublishSettings $script:identity_publishSettingsPath
        $idConnStr     = Get-IdentityConnectionString $script:identity_publishSettingsPath

        if ($stopApplicationBeforePublish) {
            if (-not (Start-Step "Identity_StopApplication")) {
                Stop-AzWebAppSlot -ResourceGroupName $identityResourceGroupName -Name $identityAppServiceName `
                    -Slot $script:identity_deploymentSlotName | Out-Null
                Write-Host "Stopped $identityAppServiceName"; Start-Sleep -Seconds 20
                End-Step "Identity_StopApplication"
            }
        }

        if (-not (Start-Step "Identity_DeployPackage")) {
            Deploy-ServicePackage -package $identityPackage -publishSettings $idPubSettings
            End-Step "Identity_DeployPackage"
        }

        if (-not (Start-Step "Identity_RunDbMigrator")) {
            Run-IdentityDbMigrator -connectionString $idConnStr -cliPath $script:identity_cliPath
            End-Step "Identity_RunDbMigrator"
        }

        # Deploy only: initial user/tenant migration from Orchestrator -> Identity Server
        if ($action -eq "Deploy") {
            if (-not (Start-Step "Identity_RunDataMigrate")) {
                Update-ConfigConnectionString $script:orch_webConfigPath $orchMigSettings.SQLDBConnectionString
                Run-IdentityDataMigrate -orchConnStr $orchMigSettings.SQLDBConnectionString `
                    -identityConnStr $idConnStr -orchConfigPath $script:orch_webConfigPath `
                    -idServerUrl $script:resolvedIdentityServerUrl -cliPath $script:identity_cliPath
                End-Step "Identity_RunDataMigrate"
            }
        }

        # Both Deploy and Update: 21-4 data migrator (passes admin passwords for Deploy)
        if (-not (Start-Step "Identity_RunDataMigrator")) {
            Update-ConfigConnectionString $script:orch_webConfigPath $orchMigSettings.SQLDBConnectionString
            $hp = if ($hostAdminPassword)         { $hostAdminPassword         -replace '"','\"' } else { "" }
            $dp = if ($defaultTenantAdminPassword) { $defaultTenantAdminPassword -replace '"','\"' } else { "" }
            Run-IdentityDataMigrator -orchConnStr $orchMigSettings.SQLDBConnectionString `
                -identityConnStr $idConnStr -orchConfigPath $script:orch_webConfigPath `
                -idServerUrl $script:resolvedIdentityServerUrl -cliPath $script:identity_cliPath `
                -hostPwd $hp -defaultTenantPwd $dp `
                -hostPassOnetime:$isHostPassOnetime -defaultTenantPassOneTime:$isDefaultTenantPassOneTime
            End-Step "Identity_RunDataMigrator"
        }

        # Both Deploy and Update: seed migrator (creates/refreshes OAuth client registrations)
        if (-not (Start-Step "Identity_RunSeedMigrator")) {
            $managementUri=$script:resolvedIdentityServerUrl -replace '/identity$',''
            Run-IdentitySeedMigrator -identityConnStr $idConnStr -orchUrl $script:resolvedOrchestratorUrl `
                -managementUri $managementUri -cliPath $script:identity_cliPath `
                -workDir $script:identity_tempDirectory
            End-Step "Identity_RunSeedMigrator"
        }

        # Deploy only: read clients_config.json and write Identity integration settings to Orchestrator
        if ($action -eq "Deploy") {
            if (-not (Start-Step "Identity_UpdateOrchSettings")) {
                $cfgFile = Join-Path $script:identity_tempDirectory "clients_config.json"
                if (Test-Path $cfgFile) {
                    $idIntSettings = Read-OrchestratorSettings -configJsonFilePath $cfgFile -identityServerUrl $script:resolvedIdentityServerUrl
                    Update-AzWebAppSettings -rgName $orchResourceGroupName -svcName $orchAppServiceName -newSettings $idIntSettings
                    Write-Host "Orchestrator updated with Identity Server integration settings." -ForegroundColor Green
                    Remove-Item $cfgFile -Force -ErrorAction SilentlyContinue
                } else {
                    Write-Warning "clients_config.json not found at $cfgFile -- skipping Orchestrator Identity settings update."
                }
                End-Step "Identity_UpdateOrchSettings"
            }
        }

        if (-not (Start-Step "Identity_SetVirtualPath")) {
            $rootFolder=Get-ZipRootFolder $identityPackage
            $props=@{ virtualApplications=@(@{virtualPath="/";physicalPath="site\wwwroot"},@{virtualPath="/identity";physicalPath="site\wwwroot\$rootFolder"}) }
            Set-AzResource -ResourceGroupName $identityResourceGroupName `
                -ResourceType "Microsoft.Web/sites/config" -ResourceName "$identityAppServiceName/web" `
                -Properties $props -ApiVersion "2015-08-01" -Force | Out-Null
            End-Step "Identity_SetVirtualPath"
        }

        if (-not (Start-Step "Identity_UpdateAppSettings")) {
            Update-IdentityAppSettings -rgName $identityResourceGroupName -svcName $identityAppServiceName `
                -slotName $script:identity_deploymentSlotName -orchUrl $script:resolvedOrchestratorUrl `
                -rcUrl $script:resolvedResourceCatalogUrl
            End-Step "Identity_UpdateAppSettings"
        }

        if (-not (Start-Step "Identity_ExchangeEncryptionKeys")) {
            Exchange-EncryptionKeys -orchRgName $orchResourceGroupName -orchSvcName $orchAppServiceName `
                -idRgName $identityResourceGroupName -idSvcName $identityAppServiceName `
                -orchConfigPath $script:orch_webConfigPath
            End-Step "Identity_ExchangeEncryptionKeys"
        }

        if ($stopApplicationBeforePublish) {
            if (-not (Start-Step "Identity_StartApplication")) {
                Start-AzWebAppSlot -ResourceGroupName $identityResourceGroupName -Name $identityAppServiceName `
                    -Slot $script:identity_deploymentSlotName | Out-Null
                Write-Host "Started $identityAppServiceName"
                End-Step "Identity_StartApplication"
            }
        }
        Write-Host "`n====== Identity Server deployment complete ======`n" -ForegroundColor Green
    }

    # ==================================================================
    # RESOURCE CATALOG PIPELINE
    # ==================================================================

    if ($script:deployResourceCatalog) {
        Write-Host "`n====== Deploying Resource Catalog ======`n" -ForegroundColor Cyan
        $rcPubSettings=Read-WDPublishSettings $script:rc_publishSettingsPath

        if ($stopApplicationBeforePublish) {
            if (-not (Start-Step "ResourceCatalog_StopApplication")) {
                Stop-AzWebAppSlot -ResourceGroupName $resourceCatalogResourceGroupName -Name $resourceCatalogAppServiceName `
                    -Slot $script:rc_deploymentSlotName | Out-Null
                Write-Host "Stopped $resourceCatalogAppServiceName"; Start-Sleep -Seconds 20
                End-Step "ResourceCatalog_StopApplication"
            }
        }

        if (-not (Start-Step "ResourceCatalog_DeployPackage")) {
            Deploy-ServicePackage -package $resourceCatalogPackage -publishSettings $rcPubSettings
            End-Step "ResourceCatalog_DeployPackage"
        }

        # Deploy only: run Resource Catalog data import and configure all integrations
        if ($action -eq "Deploy" -and $resourceCatalogCliPackage) {
            if (-not (Start-Step "ResourceCatalog_InitCli")) {
                Init-ResourceCatalogCli -cliPackage $resourceCatalogCliPackage -destDir $script:rc_tempDirectory
                End-Step "ResourceCatalog_InitCli"
            }
            if (-not (Start-Step "ResourceCatalog_ImportData")) {
                $rcConnStr = Get-IdentityConnectionString $script:rc_publishSettingsPath
                Run-ResourceCatalogImportData -orchConnStr $orchMigSettings.SQLDBConnectionString `
                    -rcConnStr $rcConnStr -workDir $script:rc_tempDirectory
                End-Step "ResourceCatalog_ImportData"
            }
            if (-not (Start-Step "ResourceCatalog_UpdateSettings")) {
                $rcConnStr = Get-IdentityConnectionString $script:rc_publishSettingsPath
                # Configure Resource Catalog app settings
                Update-AzWebAppSettings -rgName $resourceCatalogResourceGroupName -svcName $resourceCatalogAppServiceName -newSettings @{
                    "LedgerConfiguration:Subscribers:0:Enabled"                      = "true"
                    "LedgerConfiguration:Subscribers:0:ComponentId"                  = "ResxEventHubSubscriber"
                    "LedgerConfiguration:Subscribers:0:LedgerSubscriberDeliveryType" = "0"
                    "LedgerConfiguration:Subscribers:0:LedgerSubscriberReliability"  = "1"
                    "LedgerConfiguration:Subscribers:0:UseEventNameAsTopicName"      = "true"
                    "LedgerConfiguration:Subscribers:0:ConnectionString"             = $orchMigSettings.SQLDBConnectionString
                    "S2S:Authority"                                                   = $script:resolvedIdentityServerUrl
                    "Delegation:Authority"                                            = $script:resolvedIdentityServerUrl
                    "JWT:Authority"                                                   = $script:resolvedIdentityServerUrl
                    "OrchestratorConfiguration:BaseUrl"                              = $script:resolvedOrchestratorUrl
                }
                # Enable RC integration in Orchestrator
                Update-AzWebAppSettings -rgName $orchResourceGroupName -svcName $orchAppServiceName -newSettings @{
                    "ResourceCatalogService.Integration.Enabled" = "true"
                    "ResourceCatalogService.ServiceURL"          = $script:resolvedResourceCatalogUrl
                }
                End-Step "ResourceCatalog_UpdateSettings"
            }
            if (-not (Start-Step "ResourceCatalog_SetCORS")) {
                Set-RcCorsPolicy -rgName $resourceCatalogResourceGroupName -svcName $resourceCatalogAppServiceName `
                    -identityServerUrl $script:resolvedIdentityServerUrl
                End-Step "ResourceCatalog_SetCORS"
            }
            if (-not (Start-Step "ResourceCatalog_RestartApps")) {
                Write-Host "Restarting Resource Catalog and Orchestrator to apply integration settings ..."
                Stop-AzWebAppSlot  -ResourceGroupName $resourceCatalogResourceGroupName -Name $resourceCatalogAppServiceName -Slot $script:rc_deploymentSlotName | Out-Null
                Start-Sleep -Seconds 20
                Start-AzWebAppSlot -ResourceGroupName $resourceCatalogResourceGroupName -Name $resourceCatalogAppServiceName -Slot $script:rc_deploymentSlotName | Out-Null
                Stop-AzWebAppSlot  -ResourceGroupName $orchResourceGroupName -Name $orchAppServiceName -Slot $script:orch_deploymentSlotName | Out-Null
                Start-Sleep -Seconds 30
                Start-AzWebAppSlot -ResourceGroupName $orchResourceGroupName -Name $orchAppServiceName -Slot $script:orch_deploymentSlotName | Out-Null
                End-Step "ResourceCatalog_RestartApps"
            }
        }

        if ($stopApplicationBeforePublish) {
            if (-not (Start-Step "ResourceCatalog_StartApplication")) {
                Start-AzWebAppSlot -ResourceGroupName $resourceCatalogResourceGroupName -Name $resourceCatalogAppServiceName `
                    -Slot $script:rc_deploymentSlotName | Out-Null
                Write-Host "Started $resourceCatalogAppServiceName"
                End-Step "ResourceCatalog_StartApplication"
            }
        }
        Write-Host "`n====== Resource Catalog deployment complete ======`n" -ForegroundColor Green
    }

    # ==================================================================
    # WEBHOOKS PIPELINE
    # ==================================================================

    if ($script:deployWebhooks) {
        Write-Host "`n====== Deploying Webhooks Service ======`n" -ForegroundColor Cyan
        $whPubSettings=Read-WDPublishSettings $script:wh_publishSettingsPath

        if ($stopApplicationBeforePublish) {
            if (-not (Start-Step "Webhooks_StopApplication")) {
                Stop-AzWebAppSlot -ResourceGroupName $webhooksResourceGroupName -Name $webhooksAppServiceName `
                    -Slot $script:wh_deploymentSlotName | Out-Null
                Write-Host "Stopped $webhooksAppServiceName"; Start-Sleep -Seconds 20
                End-Step "Webhooks_StopApplication"
            }
        }

        if (-not (Start-Step "Webhooks_DeployPackage")) {
            Deploy-ServicePackage -package $webhooksPackage -publishSettings $whPubSettings
            End-Step "Webhooks_DeployPackage"
        }

        # Deploy only: run Webhooks settings migration CLI and wire up app settings
        if ($action -eq "Deploy" -and $webhooksCliPackage) {
            if (-not (Start-Step "Webhooks_InitCli")) {
                $whCliDir = Join-Path $script:wh_tempDirectory "cli"
                New-Item -ItemType Directory -Path $whCliDir -Force | Out-Null
                Init-WebhooksCliTool -cliPackage $webhooksCliPackage -destDir $whCliDir
                End-Step "Webhooks_InitCli"
            }
            if (-not (Start-Step "Webhooks_RunSettingsMigrator")) {
                # Inject real connection string into the temp orch config so migrator reads it correctly
                Update-ConfigConnectionString $script:orch_webConfigPath $orchMigSettings.SQLDBConnectionString
                $whAppSettingsPath = Join-Path $script:wh_tempDirectory "appsettings.azure.json"
                Run-WebhooksSettingsMigrator -orchWebConfigPath $script:orch_webConfigPath -appSettingsOutputPath $whAppSettingsPath
                End-Step "Webhooks_RunSettingsMigrator"
            }
            if (-not (Start-Step "Webhooks_UploadAppSettings")) {
                $whAppSettingsPath = Join-Path $script:wh_tempDirectory "appsettings.azure.json"
                $whFtpProfile = Read-FtpPublishProfile $script:wh_publishSettingsPath
                Upload-FileToWebApp -remotePath "appsettings.azure.json" -localPath $whAppSettingsPath -ftpProfile $whFtpProfile
                End-Step "Webhooks_UploadAppSettings"
            }
            if (-not (Start-Step "Webhooks_UpdateSettings")) {
                # Set connection strings on Webhooks app
                Update-AzWebAppSettings -rgName $webhooksResourceGroupName -svcName $webhooksAppServiceName -newSettings @{
                    "LedgerConfiguration:Subscribers:0:ConnectionString" = $orchMigSettings.SQLDBConnectionString
                    "OrchestratorSqlClientSettings:ConnectionString"     = $orchMigSettings.SQLDBConnectionString
                }
                # Enable Webhooks ledger integration in Orchestrator
                Update-AzWebAppSettings -rgName $orchResourceGroupName -svcName $orchAppServiceName -newSettings @{
                    "Webhooks.LedgerIntegration.Enabled" = "true"
                }
                # Restart Webhooks app to pick up the new appsettings.azure.json
                Write-Host "Restarting Webhooks app to apply settings ..."
                Stop-AzWebAppSlot  -ResourceGroupName $webhooksResourceGroupName -Name $webhooksAppServiceName -Slot $script:wh_deploymentSlotName | Out-Null
                Start-Sleep -Seconds 20
                Start-AzWebAppSlot -ResourceGroupName $webhooksResourceGroupName -Name $webhooksAppServiceName -Slot $script:wh_deploymentSlotName | Out-Null
                End-Step "Webhooks_UpdateSettings"
            }
        }

        if ($stopApplicationBeforePublish) {
            if (-not (Start-Step "Webhooks_StartApplication")) {
                Start-AzWebAppSlot -ResourceGroupName $webhooksResourceGroupName -Name $webhooksAppServiceName `
                    -Slot $script:wh_deploymentSlotName | Out-Null
                Write-Host "Started $webhooksAppServiceName"
                End-Step "Webhooks_StartApplication"
            }
        }
        Write-Host "`n====== Webhooks deployment complete ======`n" -ForegroundColor Green
    }

    # ==================================================================
    # Cleanup
    # ==================================================================
    Write-Host "`nCleaning up temp directory ..."
    Remove-Item $script:tempDirectory -Recurse -Force -ErrorAction SilentlyContinue

    Remove-Checkpoint

    Write-Host "`n============================================" -ForegroundColor Green
    Write-Host "  UiPath platform deployment complete!" -ForegroundColor Green
    Write-Host "============================================`n" -ForegroundColor Green
}

# Entry point
Main
