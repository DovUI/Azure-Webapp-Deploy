param(
    [ValidateScript({ if (-Not ($_ | Test-Path -PathType Leaf)) {throw "The DataMigrator file path parameter ( -cliPackage ) is not valid."} return $true })]
    [Parameter(Mandatory = $true, HelpMessage="Path to cli migrator .zip")]
    [string] $cliPackage,

    [ValidateScript({foreach ($key in @("azureAccountApplicationId", "azureAccountPassword", "azureSubscriptionId", "azureAccountTenantId") ) { if (-Not $_.ContainsKey($key)) { throw "Should contain key '$key'." }} return $true })]
    [Parameter(ParameterSetName = 'UseServicePrincipal', Mandatory=$true, HelpMessage="HashTable containing the following string properties { azureAccountApplicationId, azureAccountPassword, azureSubscriptionId, azureAccountTenantId }")]
    [System.Collections.Hashtable] $azureDetails, # { azureAccountApplicationId, azureAccountPassword, azureSubscriptionId, azureAccountTenantId, azureUSGovernmentLogin }
    
    [ValidateScript({foreach ($key in @("resourceGroupName", "appServiceName", "targetSlot") ) { if (-Not $_.ContainsKey($key)) { throw "Should contain key '$key'." }} return $true })]
    [Parameter(Mandatory=$true, HelpMessage="HashTable containing the following string properties { resourceGroupName, appServiceName, targetSlot }")]
    [System.Collections.Hashtable] $orchDetails,  # { resourceGroupName, appServiceName, targetSlot }

    [ValidateScript({foreach ($key in @("resourceGroupName", "appServiceName", "targetSlot") ) { if (-Not $_.ContainsKey($key)) { throw "Should contain key '$key'." }} return $true })]
    [Parameter(Mandatory=$true, HelpMessage="HashTable containing the following string properties { resourceGroupName, appServiceName, targetSlot }")]
    [System.Collections.Hashtable] $identityServerDetails,  # { resourceGroupName, appServiceName, targetSlot }

    [Parameter(Mandatory=$true)]
    [string] $orchestratorUrl, # public orchestrator url

    [Parameter(Mandatory=$true)]
    [string] $identityServerUrl,

    [Parameter(Mandatory = $true)]
    [string] $hostAdminPassword,

    [Parameter(Mandatory = $true)]
    [string] $defaultTenantAdminPassword,

    [switch] $isHostPassOnetime,

    [switch] $isDefaultTenantPassOneTime,
    
    [string] $tmpDirectory,
    
    [switch] $stopApplicationBeforeMigration,

    [switch] $azureUSGovernmentLogin,

    [switch] $unattended,

    [Parameter(ParameterSetName = 'NoAzureAuthentication', Mandatory = $false)]
    [switch] $noAzureAuthentication
)

Add-PSSnapin WDeploySnapin3.0

Import-Module ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".\ps_utils\MsDeployUtils.ps1"             ))) -Force
Import-Module ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".\ps_utils\AzureDeployUtils.ps1"          ))) -Force
Import-Module ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".\ps_utils\IdentityDeployUtils.ps1"       ))) -Force
Import-Module ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".\ps_utils\OrchestratorSettingsUtils.ps1" ))) -Force

function Main {
    Set-ScriptConstants

    if ((-not (Test-Password $hostAdminPassword "Host admin")) -or (-not (Test-Password $defaultTenantAdminPassword "Default tenant admin")))
    {
        exit 1
    }

    Check-InstalledAV
    Init-IdentityTempFolder $script:tempDirectory $cliPackage

    $identityPublishSettings = Read-PublishSettings $script:identityPublishSettingsPath
    $orchPublishSettings     = Read-PublishSettings $script:orchPublishSettingsPath

    $orchFtpPublishSettings = Get-FtpPublishProfile $script:orchPublishSettingsPath

	Prompt-ForContinuation -message "Please download UiPath.Orchestrator.dll.config file to $script:orchWebConfigPath. Yes or No will continue"
<#     try
    {
        Download-WebsiteFile $script:orchWebConfigName $script:orchWebConfigPath $orchFtpPublishSettings
    }
    catch
    {
        Write-Error $_.Exception.Message
        exit 1
    }
 #>
    Stop-WebApplication @orchDetails

    Run-DataMigrator `
        -orchConnectionString $orchPublishSettings.SqlDBConnectionString `
        -identityConnectionString $identityPublishSettings.SqlDBConnectionString `
        -orchWebConfigPath $script:orchWebConfigPath `
        -identityServerUrl $script:identityServerUrl
		
	Run-DataMigrator-21-4 `
        -orchConnectionString $orchPublishSettings.SqlDBConnectionString `
        -identityConnectionString $identityPublishSettings.SqlDBConnectionString `
        -orchWebConfigPath $script:orchWebConfigPath `
        -identityServerUrl $script:identityServerUrl `
        -hostAdminPassword $hostAdminPassword `
        -defaultTenantAdminPassword $defaultTenantAdminPassword `
        -hostPassOnetime $isHostPassOnetime `
        -DefaultTenantPassOneTime $isDefaultTenantPassOneTime

    Remove-ClientConfig $script:clientConfigFile
    $originalPath = pwd

    Run-SeedMigrator `
        -identityConnectionString $identityPublishSettings.SqlDBConnectionString `
        -orchestratorUrl $script:orchestratorUrl `
        -configFile $script:clientConfigFile `
        -managementUri $identityServerUrl.Substring(0, $identityServerUrl.LastIndexOf("/identity"))

    $newSettings = Read-OrchestratorSettings -configJsonFilePath $script:clientConfigFile -identityServerUrl $script:identityServerUrl

    Update-WebSiteSettings -siteDetails $orchDetails -newSettings $newSettings

    # not updating the web.config any more
    # Upload-WebsiteFile "/Web.config" $script:orchWebConfigPath $orchFtpPublishSettings
    
    Start-WebApplication @orchDetails

    Remove-ClientConfig $script:clientConfigFile

    cd $originalPath
    Remove-IdentityTempFolder
}

function Set-ScriptConstants {

    Ensure-Azure
    
    if (!$noAzureAuthentication) {
        $script:azureDetails.azureUSGovernmentLogin = $azureUSGovernmentLogin  
        AuthenticateToAzure @script:azureDetails
    }

    if (!$tmpDirectory)
    {
        $tmpDirectory = [System.IO.Path]::GetTempPath()
    }
    
    $script:tempDirectory = Join-Path $tmpDirectory "azuredeploy-$(Get-Date -f "yyyyMMddhhmmssfff")"
    New-Item -ItemType Directory -Path $script:tempDirectory | Out-Null

    $script:identityPublishSettingsPath = Join-Path $script:tempDirectory "$($identityServerDetails.appServiceName).PublishSettings"
    $script:orchPublishSettingsPath     = Join-Path $script:tempDirectory "$($orchDetails.appServiceName).PublishSettings"
    $script:orchWebConfigPath           = Join-Path $script:tempDirectory "orchestrator.web.config"
    $script:clientConfigFile            = "clients_config.json"
    $script:orchWebConfigName           = "UiPath.Orchestrator.dll.config"

    Download-PublishProfile @script:identityServerDetails -outputPath $script:identityPublishSettingsPath
    Download-PublishProfile @script:orchDetails           -outputPath $script:orchPublishSettingsPath
}

Main
