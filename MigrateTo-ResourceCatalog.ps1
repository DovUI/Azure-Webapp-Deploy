param(
    [ValidateScript({ if (-Not ($_ | Test-Path -PathType Leaf)) {throw "The DataMigrator file path parameter ( -cliPackage ) is not valid."} return $true })]
    [Parameter(Mandatory = $true, HelpMessage="Path to cli migrator .zip")]
    [string] $cliPackage,

    [ValidateScript({foreach ($key in @("azureAccountApplicationId", "azureAccountPassword", "azureSubscriptionId", "azureAccountTenantId") ) { if (-Not $_.ContainsKey($key)) { throw "Should contain key '$key'." }} return $true })]
    [Parameter(ParameterSetName = 'UseServicePrincipal', Mandatory=$true, HelpMessage="HashTable containing the following string properties { azureAccountApplicationId, azureAccountPassword, azureSubscriptionId, azureAccountTenantId }")]
    [System.Collections.Hashtable] $azureDetails, # { azureAccountApplicationId, azureAccountPassword, azureSubscriptionId, azureAccountTenantId }
    
    [ValidateScript({foreach ($key in @("resourceGroupName", "appServiceName", "targetSlot") ) { if (-Not $_.ContainsKey($key)) { throw "Should contain key '$key'." }} return $true })]
    [Parameter(Mandatory=$true, HelpMessage="HashTable containing the following string properties { resourceGroupName, appServiceName, targetSlot }")]
    [System.Collections.Hashtable] $orchDetails,  # { resourceGroupName, appServiceName, targetSlot }

    [ValidateScript({foreach ($key in @("resourceGroupName", "appServiceName", "targetSlot") ) { if (-Not $_.ContainsKey($key)) { throw "Should contain key '$key'." }} return $true })]
    [Parameter(Mandatory=$true, HelpMessage="HashTable containing the following string properties { resourceGroupName, appServiceName, targetSlot }")]
    [System.Collections.Hashtable] $resourceCatalogDetails,  # { resourceGroupName, appServiceName, targetSlot }
    
    [Parameter(Mandatory=$true)]
    [string] $resourceCatalogUrl,

    [Parameter(Mandatory=$true)]
    [string] $identityServerUrl,

    [Parameter(Mandatory=$true)]
    [string] $orchestratorUrl,

    [switch] $azureUSGovernmentLogin,

    [Parameter(ParameterSetName = 'NoAzureAuthentication', Mandatory = $false)]
    [switch] $noAzureAuthentication
)

Add-PSSnapin WDeploySnapin3.0

Import-Module ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".\ps_utils\ZipUtils.ps1"            ))) -Force
Import-Module ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".\ps_utils\MiscUtils.ps1"           ))) -Force
Import-Module ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".\ps_utils\MsDeployUtils.ps1"       ))) -Force
Import-Module ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".\ps_utils\AzureDeployUtils.ps1"    ))) -Force

function Main {
    # connect to Azure
    Ensure-Azure

    if (!$noAzureAuthentication) {
        $script:azureDetails.azureUSGovernmentLogin = $azureUSGovernmentLogin
        AuthenticateToAzure @script:azureDetails
    }

    Set-ScriptConstants

    # extract cli
    Init-TempFolder $script:tempDirectory $cliPackage

    $orchPublishSettings     = Read-PublishSettings $script:orchPublishSettingsPath
    $resourceCatalogPublishSettingsPath = Read-PublishSettings $script:resourceCatalogPublishSettingsPath
    
    Run-CLI -orchConnectionString $orchPublishSettings.SqlDBConnectionString -resourceCatalogConnectionString $resourceCatalogPublishSettingsPath.SqlDBConnectionString

    # set ResourceCatalog app settings variables for Ledger client
    $newSettings = @{
        "LedgerConfiguration:Subscribers:0:Enabled" = "true";
        "LedgerConfiguration:Subscribers:0:ComponentId" =  "ResxEventHubSubscriber";
        "LedgerConfiguration:Subscribers:0:LedgerSubscriberDeliveryType" = "0";
        "LedgerConfiguration:Subscribers:0:LedgerSubscriberReliability" =  "1";
        "LedgerConfiguration:Subscribers:0:UseEventNameAsTopicName" =  "true";
        "LedgerConfiguration:Subscribers:0:ConnectionString"    = $orchPublishSettings.SqlDBConnectionString;
        "S2S:Authority"    = $script:identityServerUrl;
        "Delegation:Authority"    = $script:identityServerUrl;
        "JWT:Authority"    = $script:identityServerUrl;
        "OrchestratorConfiguration:BaseUrl"    = $script:orchestratorUrl;
    }    
    Update-WebSiteSettings -siteDetails $resourceCatalogDetails -newSettings $newSettings

    # set Orchestrator app settings variables for ResourceCatalog
    $newSettings = @{
        "ResourceCatalogService.Integration.Enabled" = "true";
        "ResourceCatalogService.ServiceURL" =  $script:resourceCatalogUrl;
    }    
    Update-WebSiteSettings -siteDetails $orchDetails -newSettings $newSettings

    # set CORS Policies
    $identityServerUri = [System.Uri]$identityServerUrl;
    $allowedOrigins = @("{0}://{1}" -f $identityServerUri.scheme, $identityServerUri.host);
    Set-CORS-Policy -siteDetails $resourceCatalogDetails -allowedCors $allowedOrigins

    # restart ResourceCatalog App
    Stop-WebApplication @resourceCatalogDetails
    Start-WebApplication @resourceCatalogDetails

    # restart Orchestrator App
    Stop-WebApplication @orchDetails
    Start-WebApplication @orchDetails

    # cleanup temporary data
    Remove-TempFolder
}

function Set-ScriptConstants {

    $script:appSettingsName = "appsettings.azure.json" #default value for ASPNETCORE_ENVIRONMENT in Azure is ... 'Azure'
    $script:tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "azuredeploy-$(Get-Date -f "yyyyMMddhhmmssfff")"
    New-Item -ItemType Directory -Path $script:tempDirectory | Out-Null

    $script:resourceCatalogPublishSettingsPath = Join-Path $script:tempDirectory "$($resourceCatalogDetails.appServiceName).PublishSettings"
    $script:orchPublishSettingsPath     = Join-Path $script:tempDirectory "$($orchDetails.appServiceName).PublishSettings"

    Download-PublishProfile @script:resourceCatalogDetails -outputPath $script:resourceCatalogPublishSettingsPath
    Download-PublishProfile @script:orchDetails    -outputPath $script:orchPublishSettingsPath
}

function Init-TempFolder(
    [string] $tempDirectory,
    [string] $cliPackage
) {
    $script:tempDirectory = $tempDirectory
    $script:cliPath = Join-Path $tempDirectory "\migrator"

    Write-Output "`nExtracting cli to: $script:cliPath"
    Expand-Archive -path $cliPackage -destinationpath $script:cliPath

    $script:cliPath = Join-Path $script:cliPath "\UiPath.ResourceCatalogService.CLI.exe"
}

function Remove-TempFolder {
    # Cleans temp folder where migration cli is extracted

    Write-Output ""
    Write-Verbose "Removing temporary folder $($script:tempDirectory)"
    Remove-Item $script:tempDirectory -Recurse -Force
}

function Run-CLI(
    $orchConnectionString,
    $resourceCatalogConnectionString
) {
    $configPath = Join-Path $tempDirectory "\config"
    New-Item -ItemType directory $configPath -Force

    Set-Content -Path $configPath\rcsConnectionString -Value $resourceCatalogConnectionString -Force
    Set-Content -Path $configPath\orchConnectionString -Value $orchConnectionString -Force

    $cliArgs = "--config-file ""$configPath""  --import-data"

    Write-Output "Running cli import-data with arguments: $script:cliPath  $cliArgs"

    $process = Start-Process $script:cliPath -ArgumentList $cliArgs -Wait -NoNewWindow -PassThru -Verbose

    Write-Output "Process CLI import-data exitCode = $($process.ExitCode)"
    
    if($process.ExitCode)
    {
        Write-Error "Run-CLI import-data step exited with error."
        exit 1
    }
}

Main