param(
    [ValidateScript({ if (-Not ($_ | Test-Path -PathType Leaf)) {throw "The IdentityServer file path parameter ( -package ) is not valid."} return $true })]
    [Parameter(Mandatory = $true)]
    [string] $package,

    [ValidateScript({ if (-Not ($_ | Test-Path -PathType Leaf)) {throw "The DataMigrator file path parameter ( -cliPackage ) is not valid."} return $true })]
    [Parameter(Mandatory = $true, HelpMessage="Path to cli migrator .zip")]
    [string] $cliPackage,
    
    [ValidateScript({foreach ($key in @("resourceGroupName", "appServiceName", "targetSlot") ) { if (-Not $_.ContainsKey($key)) { throw "Should contain key '$key'." }} return $true })]
    [Parameter(Mandatory=$true, HelpMessage="HashTable containing the following string properties { resourceGroupName, appServiceName, targetSlot }")]
    [System.Collections.Hashtable] $orchDetails,  # { resourceGroupName, appServiceName, targetSlot }
    
    [ValidateScript({foreach ($key in @("resourceGroupName", "appServiceName", "targetSlot") ) { if (-Not $_.ContainsKey($key)) { throw "Should contain key '$key'." }} return $true })]
    [Parameter(Mandatory=$true, HelpMessage="HashTable containing the following string properties { resourceGroupName, appServiceName, targetSlot }")]
    [System.Collections.Hashtable] $identityServerDetails,  # { resourceGroupName, appServiceName, targetSlot }

    [ValidateSet("Deploy", "Update")]
    [string] $action = "Deploy",

    [Parameter(ParameterSetName = 'UseServicePrincipal', Mandatory = $true)]
    [string] $azureAccountApplicationId,

    [Parameter(ParameterSetName = 'UseServicePrincipal', Mandatory = $true)]
    [string] $azureAccountPassword,

    [Parameter(ParameterSetName = 'UseServicePrincipal', Mandatory = $true)]
    [string] $azureSubscriptionId,

    [Parameter(ParameterSetName = 'UseServicePrincipal', Mandatory = $true)]
    [string] $azureAccountTenantId,
    
    [Parameter(Mandatory = $true)]
    [string] $orchestratorUrl, # public orchestrator url

    [Parameter(Mandatory = $true)]
    [string] $resourceCatalogUrl, # public ResourceCatalog url

    [Parameter(Mandatory = $true)]
    [string] $identityServerUrl,

    [string] $deploymentSlotName,

    [string] $productionSlotName = "Production",

    [System.Object] $appSettings,

    [string] $parametersOutputPath = "$PSScriptRoot\AzurePublishParameters.json",
    
    [string] $tmpDirectory,

    [switch] $stopApplicationBeforePublish,

    [Parameter(ParameterSetName = 'UseServicePrincipal', Mandatory = $false)]
    [switch] $azureUSGovernmentLogin,

    [switch] $unattended,

    [Parameter(ParameterSetName = 'NoAzureAuthentication', Mandatory = $false)]
    [switch] $noAzureAuthentication
)

$ErrorActionPreference = "Stop"

# =========== Global variables declaration ===========
#         Declare script level variables here

$script:azureDetails                = $null # hash { azureAccountPassword, azureAccountApplicationId, azureSubscriptionId, azureAccountTenantId, azureUSGovernmentLogin }
$script:appServiceDetails           = $null # hash { targetSlot, fullAppServiceName, appServiceName, resourceGroupName }

$script:identityPublishSettingsPath = $null # [string]
$script:tempDirectory               = $null # [string]

# ====================================================

Add-PSSnapin WDeploySnapin3.0
Import-Module ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".\ps_utils\ZipUtils.ps1"            ))) -Force
Import-Module ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".\ps_utils\MiscUtils.ps1"           ))) -Force
Import-Module ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".\ps_utils\MsDeployUtils.ps1"       ))) -Force
Import-Module ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".\ps_utils\AzureDeployUtils.ps1"    ))) -Force
Import-Module ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".\ps_utils\IdentityDeployUtils.ps1" ))) -Force

function Main {

    Set-ScriptConstants
    
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
    } #>
    
    if ($stopApplicationBeforePublish) 
    {
        Stop-WebApplication @script:appServiceDetails
    }

    Deploy-Package $package $identityPublishSettings

    Run-DbMigrator $identityPublishSettings.SqlDBConnectionString

    if ($action -eq "Update")
    {
        Run-DataMigrator-21-4 `
            -orchConnectionString $orchPublishSettings.SqlDBConnectionString `
            -identityConnectionString $identityPublishSettings.SqlDBConnectionString `
            -orchWebConfigPath $script:orchWebConfigPath `
            -identityServerUrl $script:identityServerUrl `
            -hostAdminPassword "" `
            -defaultTenantAdminPassword ""
            
        $originalPath = pwd
        Run-SeedMigrator `
            -identityConnectionString $identityPublishSettings.SqlDBConnectionString `
            -orchestratorUrl $script:orchestratorUrl `
            -configFile $script:clientConfigFile `
            -managementUri $identityServerUrl.Substring(0, $identityServerUrl.LastIndexOf("/identity"))
            
        Remove-ClientConfig $script:clientConfigFile
        cd $originalPath
}

    # set virtual path based on zip root folder
    $rootFolder = Get-ZipRootFolder $package
    Set-VirtualPath @script:appServiceDetails -virtualPath "/identity" -rootFolder $rootFolder

    # Set Orchestrator & ResourceCatalog URL app settings
    $newSettings = @{
        "AppSettings__OrchestratorUrl" = $orchestratorUrl;
        "AppSettings__ResourceCatalogUrl" = $resourceCatalogUrl;
    }
    
    # Set Database Protection Settings
    Update-DbProtectionSettings -siteDetails $script:appServiceDetails -newSettings $newSettings

    Update-WebSiteSettings -siteDetails $script:appServiceDetails -newSettings $newSettings

    # Copy new settings from Identity to Orchestrator
    #   Identity database encryption key
    $identityToOrchestratorMap = @{"AppSettings__DatabaseProtectionSettings__EncryptionKey2021" = "IdentityServer.EncryptionKey"}
    Copy-NewWebSiteSettings -sourceSiteDetails $identityServerDetails -targetSiteDetails $orchDetails -settingsMap $identityToOrchestratorMap
    
    # Copy new settings from Orchestrator to Identity 
    #   Orchestrator tenant encryption key
    Copy-NewWebSiteSettingsFromXmlFile `
        -sourceXmlFilePath $script:orchWebConfigPath `
        -targetSiteDetails $identityServerDetails `
        -sourceSettingName "EncryptionKey" `
        -targetSettingName "EncryptionSettings__EncryptionKey"


    if ($stopApplicationBeforePublish){
        Start-WebApplication @script:appServiceDetails
    }

    Remove-IdentityTempFolder 
}

function Set-ScriptConstants {

    $script:azureDetails = @{
        azureAccountPassword      = $azureAccountPassword;
        azureAccountApplicationId = $azureAccountApplicationId;
        azureSubscriptionId       = $azureSubscriptionId;
        azureAccountTenantId      = $azureAccountTenantId;
        azureUSGovernmentLogin     = $azureUSGovernmentLogin;
    }

    $script:appServiceDetails = @{
        targetSlot         = $(if ($deploymentSlotName) { $deploymentSlotName } else { $productionSlotName });
        appServiceName     = $identityServerDetails.appServiceName;
        resourceGroupName  = $identityServerDetails.resourceGroupName;
    }

    $script:clientConfigFile = "clients_config.json"

    Ensure-Azure

    if (!$noAzureAuthentication) {
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
    $script:orchWebConfigName           = "UiPath.Orchestrator.dll.config"
    
    Download-PublishProfile @script:appServiceDetails -outputPath $script:identityPublishSettingsPath
    Download-PublishProfile @script:orchDetails       -outputPath $script:orchPublishSettingsPath
}


function Deploy-Package($package, $publishSettings) {

    if (($action -eq "Deploy") -and !$unattended) {

        Write-Warning "`n`nYou are running a fresh deployment.`nThis means that all settings will be generated and pushed to the target Service.`nPlease make sure that you are not deploying over an existing website, to avoid losing any settings.`nIf you are trying to update an existing website, please rerun the script with the -action parameter set to 'Update'.`n"

        if (!(Prompt-ForContinuation)) {
            Write-Output "`nExiting...`n"
            Exit 0
        }
    }

    $wdParameters = Get-WDParameters

    try {

        Write-Output "`nDeploying package $package on website $($publishSettings.SiteName)"

        Write-Output "`nWeb Deploy parameters:"
        Write-Output ($wdParameters | Out-String)

        $msDeployArgs = Build-MsDeployArgs `
            -parameters $wdParameters `
            -publishSettings $publishSettings

        Write-Output "`nExecuting command:`n"
        Write-Output "msdeploy.exe $msDeployArgs`n"

        $shouldContinue = $unattended -or (Prompt-ForContinuation)

        if (!$shouldContinue) {
            Write-Output "`nExiting...`n"
            Exit 0
        }

        Write-Output ""

        $process = Start-MsDeployProcess $msDeployArgs

        if ($process.ExitCode) {
          Write-Error "`nFailed to deploy package $package"
          Exit 1
        }

        Write-Output "`nPackage $package deployed successfully"
    } catch {
        DisplayException $_.Exception
        Exit 1
    }
}

function Get-WDParameters {
    # left for extensions purposes
    return @{ }
}

function Update-DbProtectionSettings(
    $siteDetails, # @{ appServiceName, resourceGroupName }
    $newSettings
) {
    $appService = Get-AzWebApp -Name $siteDetails.appServiceName -ResourceGroupName $siteDetails.resourceGroupName

    $appSettings = $appService.SiteConfig.AppSettings

    $settings = @{}
    ForEach ($setting in $appSettings) {
        $settings[$setting.Name] = $setting.Value
    }

    $currentSetting = $settings["AppSettings__DatabaseProtectionSettings__EncryptionKey2021"]

    if ([string]::IsNullOrEmpty($currentSetting))
    {
        $Key = New-Object Byte[] 32
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($Key)
        $encryptionKey = [Convert]::ToBase64String($Key)
        $newSettings["AppSettings__DatabaseProtectionSettings__EncryptionKey2021"] = $encryptionKey
        Write-Output "Updated DatabaseProtectionSettings for azure website settings"
    }
}

Main