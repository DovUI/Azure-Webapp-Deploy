param(
    [ValidateScript({ if (-Not ($_ | Test-Path -PathType Leaf)) {throw "The Orchestrator file path parameter ( -package ) is not valid."} return $true })]
    [Parameter(Mandatory = $true)]
    [string] $package,

    [ValidateSet("Deploy", "Update")]
    [string] $action = "Deploy",

    [Parameter(Mandatory = $true)]
    [string] $resourceGroupName,

    [Parameter(Mandatory = $true)]
    [string] $appServiceName,

    [string] $standbySlotName,

    [string] $productionSlotName = "Production",

    [System.Object] $appSettings,

    [string] $website,

    [string] $publishUrl,

    [string] $username,

    [string] $password,

    [string] $ftpPublishUrl,

    [string] $ftpUsername,

    [string] $ftpPassword,

    [string] $connectionString,

    [string] $testAutomationConnectionString,

    [string] $updateServerConnectionString,

    [string] $insightsConnectionString,

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

    [string] $storageType,

    [string] $storageLocation,

    [string] $packagesApiKey,

    [string] $activitiesApiKey,

    [switch] $useQuartzClustered,

    [string[]] $filesToSkip,

    [string[]] $foldersToSkip = @(
        "\\NuGetPackages",
        "\\NuGetPackages\\Activities",
        "\\Storage",
        "\\PackagesMigration"
    ),

    [string] $parametersOutputPath = "$PSScriptRoot\AzurePublishParameters.json",

    [switch] $stopApplicationBeforePublish,

    [ValidateScript({ if (-Not ($_ | Test-Path -PathType Leaf)) {throw "The Activities zip file path parameter ( -activitiesPackagePath ) is not valid."} return $true })]
    [string] $activitiesPackagePath,

    [string] $azureSignalRConnectionString,

    [switch] $testAutomationFeatureEnabled,

    [switch] $updateServerFeatureEnabled,

    [switch] $insightsFeatureEnabled,

    [switch] $unattended,

    [switch] $azureUSGovernmentLogin,

    [System.Version] $azModuleVersion = "6.0.0",

    [System.Version] $azAccountsModuleVersion = "2.3.0",

    [System.Version] $azWebsitesModuleVersion = "2.6.0",

    [bool] $autoSwap = $true,

    [string] $bucketsAvailableProviders,

    [string] $bucketsFileSystemAllowlist,

    [string] $orchestratorRootUrl,

    [Parameter(Mandatory = $false)]
    [switch] $confirmBlockClassicExecutions,

    [Parameter(Mandatory = $false, DontShow)]
    [switch] $allowInstallOverClassicFolders,

    # Deployment method: MsDeploy (default) uses Web Deploy / msdeploy.exe;
    # KuduZipDeploy extracts the package and pushes via Kudu REST API (HTTPS only,
    # no msdeploy.exe required — useful when FTP/FTPS or MsDeploy ports are blocked).
    [ValidateSet("MsDeploy", "KuduZipDeploy")]
    [string] $deployMethod = "MsDeploy",

    # Resume a previous run that failed mid-way.  The script reads
    # deployment-checkpoint.json from $PSScriptRoot, restores all computed state
    # from the last successful step, and skips every step already marked complete.
    # Re-authentication is still required when running in a new PowerShell session.
    [switch] $resume
)

$ErrorActionPreference = "Stop"

# Fixed path so it is always findable regardless of the temp-directory chosen at runtime.
$script:checkpointFile    = Join-Path $PSScriptRoot "deployment-checkpoint.json"
$script:completedSteps    = @()

$azModuleLocationBaseDir = "C:\Modules\az_$azModuleVersion"
$azModuleLocation = "$azModuleLocationBaseDir\az\$azModuleVersion\az.psd1"

function Import-AzModuleFromLocalMachine  {

    if ((Get-Module AzureRM)) {
        Write-Host "Unloading AzureRM Powershell module ... "
        Remove-Module AzureRM
    }

    Write-Host "Importing module $azModuleLocation"
    $env:PSModulePath = $azModuleLocationBaseDir + ";" + $env:PSModulePath

    $currentVerbosityPreference = $Global:VerbosePreference

    $Global:VerbosePreference = 'SilentlyContinue'
    Import-Module $azModuleLocation -Verbose:$false
    $Global:VerbosePreference = $currentVerbosityPreference
}

function Main {

    # Always ensure the Az module is loaded — this is fast if already imported
    # and must happen even on a resume run where Set-ScriptConstants is skipped.
    Ensure-AzureModule

    # Load a prior checkpoint (if -resume) or start fresh.
    Initialize-Checkpoint

    # ------------------------------------------------------------------
    # Step 1 – initialise all script-scope constants, extract the package,
    #           download the publish profile, and authenticate to Azure.
    # ------------------------------------------------------------------
    if (-not (Start-Step "InitializeConstants")) {
        Set-ScriptConstants
        End-Step "InitializeConstants"
    }

    # ------------------------------------------------------------------
    # Step 2 – validate parameters and package extensions.
    # ------------------------------------------------------------------
    if (-not (Start-Step "ValidateParameters")) {
        Validate-Parameters
        End-Step "ValidateParameters"
    }

    if (-not (Start-Step "ValidateExtensions")) {
        Invoke-ExtensionsValidation -configFilePath $script:newConfigPath
        End-Step "ValidateExtensions"
    }

    # ------------------------------------------------------------------
    # Step 3 – optionally stop the web app before deploying.
    # ------------------------------------------------------------------
    if ($stopApplicationBeforePublish) {
        if (-not (Start-Step "StopApplication")) {
            StopWebApplication -slotName $script:deploymentSlotName
            End-Step "StopApplication"
        }
    }

    # Re-parse the publish profile on every run (cheap file read, always needed).
    $publishSettings = Get-PublishSettings $script:publishSettingsPath

    # ------------------------------------------------------------------
    # Step 4 – pre-validate the database schema.
    # ------------------------------------------------------------------
    if (-not (Start-Step "PreValidateDatabase")) {
        Invoke-DatabasePreValidations `
            -databaseType            "Default" `
            -connectionString        $publishSettings.MigrationSettings.SQLDBConnectionString `
            -configFilePath          $script:newConfigPath `
            -ignoreClassicFoldersError $allowInstallOverClassicFolders
        End-Step "PreValidateDatabase"
    }

    # ------------------------------------------------------------------
    # Step 5 – start package migration (only when upgrading from Legacy).
    # ------------------------------------------------------------------
    if ($script:runPackageMigrator) {
        Write-Warning "`n`nPackages and activities will be migrated from FileSystem storage locations: '$script:packagesUrl'(packages), '$script:activitiesUrl'(activities) to storage type '$script:storageType', location $script:storageLocation."
        if (!$unattended) {
            if (!(Prompt-ForContinuation)) {
                Write-Host "`nExiting...`n" -ForegroundColor Yellow
                Exit 0
            }
        }

        if (-not (Start-Step "MigratePackagesStart")) {
            Import-Module -Name '.\ps_utils\Migrate-Packages.psm1' -Force `
                          -ArgumentList $script:msDeployExe, $script:cliPath, $publishSettings.PublishSettings, `
                                        $publishSettings.MigrationSettings.SQLDBConnectionString, `
                                        $script:storageType, $script:storageLocation, `
                                        $script:activitiesUrl, $script:packagesUrl, `
                                        $script:instanceKey, $script:unattended
            Start-PackagesMigration
            End-Step "MigratePackagesStart"
        }
    }

    # ------------------------------------------------------------------
    # Step 6 – deploy the package (MsDeploy or Kudu ZIP deploy).
    # ------------------------------------------------------------------
    if (-not (Start-Step "DeployPackage")) {
        Deploy-Package $package $publishSettings.PublishSettings
        End-Step "DeployPackage"
    }

    Prompt-ForContinuation -message "Upload files"

    # ------------------------------------------------------------------
    # Step 7 – run database migrations.
    # ------------------------------------------------------------------
    if (-not (Start-Step "UpdateDatabases")) {
        Update-AllDatabases $publishSettings
        End-Step "UpdateDatabases"
    }

    # ------------------------------------------------------------------
    # Step 8 – finalise package migration and build app-settings payload.
    # ------------------------------------------------------------------
    if ($script:runPackageMigrator) {
        if (-not (Start-Step "MigratePackagesFinalize")) {
            Finalize-PackagesMigration
            End-Step "MigratePackagesFinalize"
        }
        # Always re-apply migration settings to the local $appSettings variable
        # (it is reset each run, so we must add these even on a resume pass).
        $appSettings = Add-Setting $appSettings "NuGet.Repository.Type" "Composite"
        $appSettings = Add-Setting $appSettings "InstanceKey" $script:instanceKey
    }

    $webAppUrl = if ($orchestratorRootUrl) {
        $orchestratorRootUrl
    } else {
        Get-WebAppUrl -resourceGroupName $resourceGroupName -webAppName $appServiceName
    }
    $appSettings = Add-Setting $appSettings "OrchestratorRootUrl" $webAppUrl

    # ------------------------------------------------------------------
    # Step 9 – push Azure App Settings to the slot.
    # ------------------------------------------------------------------
    if (-not (Start-Step "ApplyAppSettings")) {
        Apply-AppSettings -deployAppSettings $appSettings -slotName $script:deploymentSlotName
        End-Step "ApplyAppSettings"
    }

    # ------------------------------------------------------------------
    # Step 10 – deploy activities package (composite mode, optional).
    # ------------------------------------------------------------------
    if ($activitiesPackagePath) {
        if (-not (Start-Step "DeployActivities")) {
            Deploy-ActivitiesInCompositeMode $publishSettings
            End-Step "DeployActivities"
        }
    }

    # ------------------------------------------------------------------
    # Step 11 – restart the app (or standby slot).
    # ------------------------------------------------------------------
    if ($stopApplicationBeforePublish) {
        if (-not (Start-Step "StartApplication")) {
            StartWebApplication -slotName $script:deploymentSlotName
            End-Step "StartApplication"
        }
    }

    if ($script:hotswap -and -not $stopApplicationBeforePublish) {
        if (-not (Start-Step "StartStandbyApplication")) {
            StartWebApplication -slotName $standbySlotName
            End-Step "StartStandbyApplication"
        }
    }

    # ------------------------------------------------------------------
    # Step 12 – swap deployment slots (optional).
    # ------------------------------------------------------------------
    if ($script:autoSwap -and $script:hotswap) {
        if (-not (Start-Step "SwapSlots")) {
            SwapSlots
            End-Step "SwapSlots"
        }
        if (-not (Start-Step "StopStandbyApplication")) {
            StopWebApplication -slotName $standbySlotName
            End-Step "StopStandbyApplication"
        }
    }

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------
    if ($script:appDomain) {
        [System.AppDomain]::Unload($script:appDomain)
    }

    Write-Host ""
    Write-Verbose "Removing temporary folder $($script:tempDirectory)"
    Remove-Item $script:tempDirectory -Recurse -Force

    # All steps completed — remove the checkpoint so the next run starts fresh.
    Remove-Checkpoint
}

function Set-ScriptConstants {

    if (Test-Path $azModuleLocation) {
        Import-AzModuleFromLocalMachine
    } else {
        # we can't check for Az module in Powershell 5.1 because of https://github.com/PowerShell/PowerShell/pull/8777
        # we will check for Az.Accounts and Az.Websites versions instead which come bundled with the desired Az module version
        $azAccountsModule = (Get-Module -Name Az.Accounts -ListAvailable -Verbose:$false | Where-Object {($_.Version -ge $azAccountsModuleVersion)})
        $azWebsitesModule = (Get-Module -Name Az.Websites -ListAvailable -Verbose:$false | Where-Object {($_.Version -ge $azWebsitesModuleVersion)})
        if ($azAccountsModule -and $azWebsitesModule) {
            Write-Host "Az Powershell module version $azModuleVersion or greater is already installed. Importing module ..."
        } else {
            # check for AzureRM on Powershell 5.1 if Az is not installed
            if ((Get-Module -Name AzureRM -ListAvailable)) {
                Write-Warning "AzureRM module is installed. Having both AzureRM and Az modules installed for PowerShell 5.1 on Windows at the same time is not supported." 
                if (!$unattended -and !(Prompt-ForContinuation -message "Preparing to remove AzureRM Module. Do you wish to continue?")) {
                    Write-Host "`nExiting...`n" -ForegroundColor Yellow
                    Exit 0
                }
                if ((Get-Module -Name AzureRM)) {
                    Write-Host "Unloading AzureRM module from current session"
                    Remove-Module AzureRM
                } else {
                    Write-Host "AzureRM module not loaded in current session."
                }
                # we need Az installed first because Uninstall-AzureRM is bundled in Az.Accounts
                Write-Host "Installing Az Powershell module $azModuleVersion" -ForegroundColor Yellow
                Install-Module Az -RequiredVersion $azModuleVersion -Force -AllowClobber -Verbose:$false
                Write-Host "Uninstalling AzureRM... `n"
                Uninstall-AzureRM
            } else {
                Write-Host "Az Powershell module version $azModuleVersion or later not found. Installing Az Powershell module $azModuleVersion" -ForegroundColor Yellow
                Install-Module Az -RequiredVersion $azModuleVersion -Force -AllowClobber -Verbose:$false
            }
        }
        Import-Module Az -Version $azModuleVersion -Verbose:$false
    }   

    AuthenticateToAzure

    $script:aspNetConfigName = "Web.config"
    $script:aspNetCoreConfigName = "UiPath.Orchestrator.WebCore.Host.exe.config"
    $script:dotNetCoreConfigName = "UiPath.Orchestrator.dll.config"

    $script:msDeployExe = Join-Path ${env:ProgramFiles(x86)} "IIS\Microsoft Web Deploy V3\msdeploy.exe"

    $script:parametersOutputPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $script:parametersOutputPath ))
    $script:appSettingsOutputPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $script:appSettingsOutputPath ))

    $script:workingFolder = Get-Location
    $script:package = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($workingFolder, $script:package ))
    if ($script:cliPath) {
        $script:cliPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($workingFolder, $script:cliPath ))
    }

    $orchestratorPayloadTempDir = Join-Path $ENV:TEMP "OrchestratorMigration_$(Get-Date -Format 'yyyyMMddhhmmssfff')"

    Extract-FilesFromZip -zip $package -destinationFolder $orchestratorPayloadTempDir -filePattern "Content/*/bin/win-x64/publish/$script:dotNetCoreConfigName"
    if (Test-Path "$orchestratorPayloadTempDir/$script:dotNetCoreConfigName")
    {
        # We were able to find an AspNetCore configuration file in the package.
        $script:newConfigName = $script:dotNetCoreConfigName
        $script:webArchiveContentPath = "Content/*/bin/win-x64/publish/"
    }
    else
    {
        Extract-FilesFromZip -zip $package -destinationFolder $orchestratorPayloadTempDir -filePattern "Content/*/obj/Release/Package/PackageTmp/web.config"
        $script:newConfigName = $script:aspNetConfigName
        $script:webArchiveContentPath = "Content/*/obj/Release/Package/PackageTmp/bin/"
    }

    Extract-DirectoryFromZip -zip $package -directory $webArchiveContentPath -destination "$orchestratorPayloadTempDir/"

    $script:cliToolPath = Join-Path "$orchestratorPayloadTempDir/Tools/Cli/" "UiPath.Orchestrator.Cli.exe"
    $script:newConfigPath = Join-Path $orchestratorPayloadTempDir $script:newConfigName
	
    $script:defaultFolderstoSkip = @(
        "\\App_Data"
    )
    $script:defaultFilesToSkip = @()

    $script:tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "azuredeploy-$(Get-Date -f "yyyyMMddhhmmssfff")"

    New-Item -ItemType Directory -Path $script:tempDirectory | Out-Null

    $script:publishSettingsPath = Join-Path $script:tempDirectory "$appServiceName.PublishSettings"
    $script:webConfigPath = Join-Path $script:tempDirectory  "Web.config"
    $script:parametersXmlPath = Join-Path $script:tempDirectory "parameters.xml"
    $script:hotswap = $false

    Download-PublishProfile -outputPath $script:publishSettingsPath -slotName $productionSlotName

    $script:updateProductionDatabase = $true

    if ($standbySlotName) {
        $script:publishSettings = Get-PublishSettings $script:publishSettingsPath
        $script:ftpPublishProfile = Get-FtpPublishProfile $script:publishSettingsPath

        # Auto-generate all three config variants; no FTP/FTPS required.
        New-OrchestratorConfigFiles -tempDirectory $script:tempDirectory

        $script:productionWebConfigPath = Join-Path $script:tempDirectory "Web.Production.config"
        Copy-Item -Path $script:webConfigPath -Destination $script:productionWebConfigPath

        $migrations = Get-PendingMigrations -connectionString $script:publishSettings.MigrationSettings.SQLDBConnectionString -webConfigPath $script:webConfigPath -configMigration 'Default'
        if ($testAutomationFeatureEnabled) {
            $testAutomationMigrations = Get-PendingMigrations -connectionString $script:publishSettings.MigrationSettings.SQLTestAutomationDBConnectionString -webConfigPath $script:webConfigPath -configMigration 'TestAutomation'
        }

        if ($updateServerFeatureEnabled) {
            $updateServerMigrations = Get-PendingMigrations -connectionString $script:publishSettings.MigrationSettings.SQLUpdateServerDBConnectionString -webConfigPath $script:webConfigPath -configMigration 'UpdateServer'
        }

        if ($insightsFeatureEnabled) {
            $insightsMigrations = Get-PendingMigrations -connectionString $script:publishSettings.MigrationSettings.SQLInsightsDBConnectionString -webConfigPath $script:webConfigPath -configMigration 'Insights'
        }

        if ($migrations -or ($testAutomationFeatureEnabled -and $testAutomationMigrations) -or ($updateServerFeatureEnabled -and $updateServerMigrations) -or ($insightsFeatureEnabled -and $insightsMigrations)) {
            Write-Host "Pending migrations for production database"
        } else {
            Write-Host "No pending migrations for production database"
            $script:updateProductionDatabase = $false
        }
        
        Download-PublishProfile -outputPath $script:publishSettingsPath -slotName $standbySlotName
        $script:publishSettings = Get-PublishSettings $script:publishSettingsPath

        $script:hotswap = $true
    }

    $script:deploymentSlotName = if ($script:hotswap) { $standbySlotName } else { $productionSlotName }
    $script:fullAppServiceName = if ($script:hotswap) { "$appServiceName-$standbySlotName" } else { "$appServiceName-$productionSlotName" }
    $script:ftpPublishProfile = Get-FtpPublishProfile $script:publishSettingsPath

    $script:storageType = $storageType
    $script:packagesApiKey = $packagesApiKey
    $script:activitiesApiKey = $activitiesApiKey
    $script:storageLocation = $storageLocation
    $script:redisConnectionString = $redisConnectionString
    $script:loadBalancerUseRedis = $loadBalancerUseRedis
    $script:robotsElasticSearchUrl = $robotsElasticSearchUrl
    $script:robotsElasticSearchUsername = $robotsElasticSearchUsername
    $script:robotsElasticSearchPassword = $robotsElasticSearchPassword
    $script:robotsElasticSearchTargets = $robotsElasticSearchTargets
    $script:serverElasticSearchUrl = $serverElasticSearchUrl
    $script:serverElasticSearchDiagnosticsUsername = $serverElasticSearchDiagnosticsUsername
    $script:serverElasticSearchDiagnosticsPassword = $serverElasticSearchDiagnosticsPassword
    $script:serverElasticSearchIndex = $serverElasticSearchIndex
    $script:serverDefaultTargets = $serverDefaultTargets
    $script:azureSignalRConnectionString = $azureSignalRConnectionString
    $script:runPackageMigrator = $false;
    $script:instanceKey
    $script:bucketsFileSystemAllowlist = $bucketsFileSystemAllowlist
    $script:bucketsAvailableProviders = $bucketsAvailableProviders
    $script:deployMethod = $deployMethod

    Extract-FilesFromZip -zip $package -destinationFolder $script:tempDirectory -filePattern "parameters.xml"
    $script:defaultParameterXmlValues = Get-AllDefaultParameterValues -parametersXmlPath $script:parametersXmlPath
    if ($redisConnectionString) {
        $script:loadBalancerUseRedis = "true"
    }

    $script:existingProdAppSettings = Read-ExistingAppSettings $productionSlotName

    switch ($action) {
        "Update" {
            # Auto-generate all three config variants; no FTP/FTPS required.
            New-OrchestratorConfigFiles -tempDirectory $script:tempDirectory

            if (!($packagesApiKey)) {
                $script:packagesApiKey = (Get-WDParameterValue "apiKey" $script:parametersXmlPath $script:webConfigPath)
            }
            if (!($activitiesApiKey)) {
                $script:activitiesApiKey = (Get-WDParameterValue "activitiesApiKey" $script:parametersXmlPath $script:webConfigPath)
            }
            $script:decryption = (Get-WDParameterValue "machineKeyDecryption" $script:parametersXmlPath $script:webConfigPath)
            $script:decryptionKey = (Get-WDParameterValue "machineKeyDecryptionKey" $script:parametersXmlPath $script:webConfigPath)
            $script:validation = (Get-WDParameterValue "machineKeyValidation" $script:parametersXmlPath $script:webConfigPath)
            $script:validationKey = (Get-WDParameterValue "machineKeyValidationKey" $script:parametersXmlPath $script:webConfigPath)
            $script:encryptionKey = (Get-WDParameterValue "EncryptionKey" $script:parametersXmlPath $script:webConfigPath)

            if (!($storageType)) {
                $script:storageType = (Get-WDParameterValue "storageType" $script:parametersXmlPath $script:webConfigPath)
                if (!($script:storageType)) {
                    $script:storageType = $script:defaultParameterXmlValues."storageType"
                }
            }
            if (!($storageLocation)) {
                $script:storageLocation = (Get-WDParameterValue "storageLocation" $script:parametersXmlPath $script:webConfigPath)
                if (!($script:storageLocation)) {
                    $script:storageLocation = $script:defaultParameterXmlValues."storageLocation"
                }
            }
            if (!($redisConnectionString)) {
                $script:redisConnectionString = (Get-WDParameterValue "loadBalancerRedisConnectionString" $script:parametersXmlPath $script:webConfigPath)
                if (!($loadBalancerUseRedis)) {
                    $script:loadBalancerUseRedis = (Get-WDParameterValue "loadBalancerUseRedis" $script:parametersXmlPath $script:webConfigPath)
                }
            }
            if (!($robotsElasticSearchUrl)) {
                $script:robotsElasticSearchUrl = (Get-WDParameterValue "ElasticSearchUrl" $script:parametersXmlPath $script:webConfigPath)
            }
            if (!($robotsElasticSearchUsername)) {
                $script:robotsElasticSearchUsername = (Get-WDParameterValue "ElasticSearchUsername" $script:parametersXmlPath $script:webConfigPath)
            }
            if (!($robotsElasticSearchPassword)) {
                $script:robotsElasticSearchPassword = (Get-WDParameterValue "ElasticSearchPassword" $script:parametersXmlPath $script:webConfigPath)
            }
            if (!($robotsElasticSearchTargets)) {
                $script:robotsElasticSearchTargets = (Get-WDParameterValue "ElasticSearchLogger" $script:parametersXmlPath $script:webConfigPath)
            }
            if (!($serverElasticSearchUrl)) {
                $script:serverElasticSearchUrl = (Get-WDParameterValue "elasticSearchDiagnosticsUrl" $script:parametersXmlPath $script:webConfigPath)
            }
            if (!($serverElasticSearchDiagnosticsUsername)) {
                $script:serverElasticSearchDiagnosticsUsername = (Get-WDParameterValue "elasticSearchDiagnosticsUsername" $script:parametersXmlPath $script:webConfigPath)
            }
            if (!($serverElasticSearchDiagnosticsPassword)) {
                $script:serverElasticSearchDiagnosticsPassword = (Get-WDParameterValue "elasticSearchDiagnosticsPassword" $script:parametersXmlPath $script:webConfigPath)
            }
            if (!($serverElasticSearchIndex)) {
                $script:serverElasticSearchIndex = (Get-WDParameterValue "elasticSearchDiagnosticsIndex" $script:parametersXmlPath $script:webConfigPath)
            }
            if (!($serverDefaultTargets)) {
                $script:serverDefaultTargets = (Get-WDParameterValue "serverDefaultTargets" $script:parametersXmlPath $script:webConfigPath)
            }
            if (!($azureSignalRConnectionString)) {
                $script:azureSignalRConnectionString = (Get-WDParameterValue "azureSignalRConnectionString" $script:parametersXmlPath $script:webConfigPath)
            }
            if (!($bucketsFileSystemAllowlist)) {
                $script:bucketsFileSystemAllowlist = (Get-WDParameterValue "bucketsFileSystemAllowlist" $script:parametersXmlPath $script:webConfigPath)
            }
            if (!($bucketsAvailableProviders)) {
                $script:bucketsAvailableProviders = (Get-WDParameterValue "bucketsAvailableProviders" $script:parametersXmlPath $script:webConfigPath)
            }

            $script:nugetRepositoryType = Get-SettingValue "NuGet.Repository.Type" $script:webConfigPath
            $script:packagesUrl = Get-SettingValue "NuGet.Packages.Path" $script:webConfigPath
            $script:activitiesUrl = Get-SettingValue "NuGet.Activities.Path" $script:webConfigPath


            if (($script:nugetRepositoryType -eq "Legacy") -or #upgrade from legacy Orchestrator version > 19.4
                #upgrade from legacy Orchestrator version = 18.4.x, where NuGet.Repository.Type is missing
                (!($script:nugetRepositoryType) -and $script:packagesUrl -and $script:activitiesUrl)) {
                    $script:runPackageMigrator = $true
                    $script:instanceKey = Get-SettingValue "InstanceKey" $script:webConfigPath

                    if(!$script:instanceKey) {
                        $script:instanceKey = Generate-Guid
                    }

                    Write-Host "Current Nuget.Repository.Type is Legacy. Will run package migration."
                    Write-Verbose "NuGet.Packages.Path: $packagesUrl"
                    Write-Verbose "NuGet.Activities.Path: $activitiesUrl"
            }
        }
        "Deploy" {
            $script:packagesApiKey = Generate-Guid
            $script:activitiesApiKey = $script:packagesApiKey
            $script:nugetRepositoryType = "Composite"

            if (!$storageType) {
                $script:storageType = $script:defaultParameterXmlValues."storageType"
            }
            if (!$storageLocation) {
                $script:storageLocation = $script:defaultParameterXmlValues."storageLocation"
            }
        }
    }

}

function Validate-Parameters {

    if ($script:deployMethod -eq "MsDeploy" -and !(Test-Path $script:msDeployExe)) {
        Write-Error "No msdeploy.exe found at '$($script:msDeployExe)'"
        Exit 1
    }

    $validStorageTypes = @("FileSystem", "Azure", "Minio", "Amazon")
    if ($script:storageType) {
        if ($validStorageTypes -notcontains $script:storageType) {
            Write-Error "Invalid -storageType parameter value. Valid values are: $validStorageTypes"
            Exit 1
        }
    }

    $validUseLoadBalancerValues = @("true","false")

    if ($script:loadBalancerUseRedis) {
        if ($validUseLoadBalancerValues -notcontains $script:loadBalancerUseRedis) {
            Write-Error "Invalid -loadBalancerUseRedis parameter value. Valid values are: $validUseLoadBalancerValues"
            Exit 1
        }
    }

    if ($action -eq "Update") {

        $updateErrorMessage = "The -{0} parameter is missing from web.config and is required if the -action parameter is set to 'Update'"

        if (!$script:storageLocation) {
            Write-Error ($updateErrorMessage -f "storageLocation")
            Exit 1
        }
        if (!$script:packagesApiKey) {
            Write-Error ($updateErrorMessage -f "packagesApiKey")
            Exit 1
        }
        if (!$script:activitiesApiKey) {
            Write-Error ($updateErrorMessage -f "activitiesApiKey")
            Exit 1
        }
        if (-not $script:confirmBlockClassicExecutions.IsPresent) {
            Write-Error ("You need to agree with blocking the jobs execution in classic folders after update using the -{0} flag" -f "confirmBlockClassicExecutions")
            Exit 1
        }
    }

    if (!(Test-Path $script:publishSettingsPath)) {

        $publishSettingsErrorMessage = "The -{0} parameter is required if the publish file is not present"

        if (!$website) {
            Write-Error ($publishSettingsErrorMessage -f "website")
            Exit 1
        }

        if (!$publishUrl) {
            Write-Error ($publishSettingsErrorMessage -f "publishUrl")
            Exit 1
        }

        if (!$username) {
            Write-Error ($publishSettingsErrorMessage -f "username")
            Exit 1
        }

        if (!$password) {
            Write-Error ($publishSettingsErrorMessage -f "password")
            Exit 1
        }

        if (!$connectionString) {
            Write-Error ($publishSettingsErrorMessage -f "connectionString")
            Exit 1
        }

        if (!$ftpPublishUrl) {
            Write-Error ($publishSettingsErrorMessage -f "ftpPublishUrl")
            Exit 1
        }

        if (!$ftpUsername) {
            Write-Error ($publishSettingsErrorMessage -f "ftpUsername")
            Exit 1
        }

        if (!$ftpPassword) {
            Write-Error ($publishSettingsErrorMessage -f "ftpPassword")
            Exit 1
        }
    }

    if ($runPackageMigrator) {
        if (!$script:storageType -or !$script:storageLocation) {
             Write-Error "Both -storageType and -storageLocation parameters are required if current Nuget.Repository.Type setting is set to Legacy. NuGet packages need to be migrated to a new location."
        }

        if (!$script:packagesUrl -or !$script:activitiesUrl) {
             Write-Error "Both `NuGet.Packages.Path` and `NuGet.Activities.Path` settings are required to be set either in web.config or Application Settings, if current `Nuget.Repository.Type` setting is set to Legacy. NuGet packages need to be migrated from the existing locations."
        }
    }

    if(($script:bucketsAvailableProviders -like '*FileSystem*') -and ($null -eq $script:bucketsFileSystemAllowlist)){
        Write-Error "The -bucketsFileSystemAllowlist is mandatory when -bucketsAvailableProviders contains FileSystem provider"
        Exit 1
    }
}

function AuthenticateToAzure {

    # If an Azure context already exists in this session (e.g. the module was
    # loaded and signed in before the script failed), skip the interactive prompt.
    $existingContext = Get-AzContext -ErrorAction SilentlyContinue
    if ($existingContext -and $existingContext.Account) {
        Write-Host "Already signed in to Azure as $($existingContext.Account.Id) — skipping re-authentication." -ForegroundColor Green
        return
    }

    Write-Host "Connecting to Azure — a browser or device-code prompt will appear for sign-in ..."
    if ($azureUSGovernmentLogin) {
        $loginResult = Connect-AzAccount -Environment AzureUSGovernment
    } else {
        $loginResult = Connect-AzAccount
    }

    if ($loginResult) {
        Write-Host "Logged in to Azure as $($loginResult.Context.Account.Id)." -ForegroundColor Green
    } else {
        Write-Error "Failed to log in to Azure."
        Exit 1
    }
}

function StopWebApplication ([string] $slotName) {

    $stopped = Stop-AzWebAppSlot -ResourceGroupName $resourceGroupName -Name $appServiceName -Slot $slotName.Trim()

    if ($stopped){
        Write-Host "Stopped the application $script:fullAppServiceName"
    } else {
        Write-Error "Could not stop the application $script:fullAppServiceName, aborting."
        Exit 1
    }
    Write-Host "Waiting 30 seconds for $script:fullAppServiceName to shut down completely."
    Start-Sleep -Seconds 30
}

function StartWebApplication([string] $slotName) {

    $started = Start-AzWebAppSlot -ResourceGroupName $resourceGroupName -Name $appServiceName -Slot $slotName

    if ($started){
        Write-host "Started the application $script:fullAppServiceName"
    } else {
        Write-Error "Could not start the application $script:fullAppServiceName, try to start it manually."
    }
}

function Deploy-Package($package, $publishSettings) {

    if (($action -eq "Deploy") -and !$unattended) {

        Write-Warning "`n`nYou are running a fresh deployment.`nThis means that all encryption settings will be generated and pushed to the target website.`nPlease make sure that you are not deploying over an existing website, to avoid losing any settings.`nIf you are trying to update an existing website, please rerun the script with the -action parameter set to 'Update'.`nThe following items will be generated:`n- Encryption key for credential assets`n- NuGet feed API key (for published packages and Activities)`n- Website machine key (IIS)"

        if (!(Prompt-ForContinuation)) {
            Write-Host "`nExiting...`n" -ForegroundColor Yellow
            Exit 0
        }
    }

    $skipFolders = $foldersToSkip + $script:defaultFolderstoSkip
    $skipFiles = $filesToSkip + $script:defaultFilesToSkip

    $wdParameters = Get-WDParameters
    $publishParameters = $null

    try {

        if ($script:deployMethod -eq "KuduZipDeploy") {

            Invoke-KuduZipDeploy -package $package -publishSettings $publishSettings -wdParameters $wdParameters

        } else {

            Write-Host "`nDeploying package $package on website $($publishSettings.SiteName)" -ForegroundColor Yellow

            Write-Host "`nWeb Deploy parameters:" -ForegroundColor Yellow
            Write-Host ($wdParameters | Out-String)

            Write-Host "Folders to skip:`n" -ForegroundColor Yellow
            Write-Host ($skipFolders -join ", ")

            Write-Host "`nFiles to skip:`n" -ForegroundColor Yellow
            Write-Host ($skipFiles -join ", ")

            $msDeployArgs = Build-MsDeployArgs `
                -parameters $wdParameters `
                -skipFolders $skipFolders `
                -skipFiles $skipFiles `
                -publishSettings $publishSettings

            Write-Host "`nExecuting command:`n" -ForegroundColor Yellow
            Write-Host "msdeploy.exe $msDeployArgs`n"

            $shouldContinue = $unattended -or (Prompt-ForContinuation)

            if (!$shouldContinue) {
                Write-Host "`nExiting...`n" -ForegroundColor Yellow
                Exit 0
            }

            $process = Start-Process $script:msDeployExe -ArgumentList $msDeployArgs -Wait -NoNewWindow -PassThru

            if ($process.ExitCode) {
                Write-Error "`nFailed to deploy package $package with $($process.ExitCode)"
                Exit 1
            }

            Write-Host "`nPackage $package deployed successfully" -ForegroundColor Green
        }

        $publishParameters = Get-PublishParameters $wdParameters $applicationSettings
        $publishParameters | ConvertTo-Json -Depth 99 | Out-File $parametersOutputPath

        Write-Host "`nDeployment parameters logged in file '$parametersOutputPath'`n" -ForegroundColor Yellow

    } catch {
        DisplayException $_.Exception
        Exit 1
    }
}

function Build-MsDeployArgs([System.Collections.Hashtable] $parameters, [string[]] $skipFolders, [string[]] $skipFiles, $publishSettings) {

    $site = $publishSettings.SiteName
    $publishUrl = $publishSettings.PublishUrl
    $username = $publishSettings.UserName
    $password = $publishSettings.Password

    $msDeployArgs = "-verb:sync -source:package='$package' -dest:auto,ComputerName='https://$publishUrl/msdeploy.axd?site=$site',UserName='$userName',Password='$password',AuthType='Basic' -disableLink:AppPoolExtension -disableLink:ContentExtension -disableLink:CertificateExtension -setParam:name='IIS Web Application Name',value='$site'"

    $skipFolders | ForEach-Object {
        $msDeployArgs += " -skip:objectName=dirPath,absolutePath='$($_)'"
    }

    $skipFiles | ForEach-Object {
        $msDeployArgs += " -skip:filePath=dirPath,absolutePath='$($_)'"
    }

    $parameters.GetEnumerator() | ForEach-Object {
        $msDeployArgs += " -setParam:name='$($_.Key)',value='$($_.Value)'"
    }

    return $msDeployArgs
}

function Get-WDParameters {

    $wdParameters = @{
        ElasticSearchRequireAuth = "false"
        elasticSearchDiagnosticsRequireAuth = "false"
    }

    $encryptionKeyToSet = if ($action -eq "Deploy") {
        Generate-EncryptionKey
    } else {
        $script:encryptionKey
    }
    $wdParameters.EncryptionKey = $encryptionKeyToSet

    $machineKeySettings = Get-MachineKeySettings
    $wdParameters.machineKeyDecryption = $machineKeySettings.decryption
    $wdParameters.machineKeyDecryptionKey = $machineKeySettings.decryptionKey
    $wdParameters.machineKeyValidation = $machineKeySettings.validation
    $wdParameters.machineKeyValidationKey = $machineKeySettings.validationKey

    if ([boolean]$script:redisConnectionString) {
        $wdParameters.loadBalancerUseRedis = $script:loadBalancerUseRedis
        $wdParameters.loadBalancerRedisConnectionString = $script:redisConnectionString
    }

    if ($script:robotsElasticSearchUrl) {
        $wdParameters.ElasticSearchUrl = $script:robotsElasticSearchUrl
        $wdParameters.ElasticSearchLogger = "$script:robotsElasticSearchTargets"

        if ($script:robotsElasticSearchUsername -and $script:robotsElasticSearchPassword) {
            $wdParameters.ElasticSearchUsername = $script:robotsElasticSearchUsername
            $wdParameters.ElasticSearchPassword = $script:robotsElasticSearchPassword
            $wdParameters.ElasticSearchRequireAuth = "true"
        }
    }

    if ($script:serverDefaultTargets) {
        $wdParameters.serverDefaultTargets = "$script:serverDefaultTargets"
    }

    if ($script:serverElasticSearchUrl) {
        $wdParameters.elasticSearchDiagnosticsUrl = $script:serverElasticSearchUrl

        if ($script:serverElasticSearchIndex) {
            $wdParameters.elasticSearchDiagnosticsIndex = $script:serverElasticSearchIndex
        }

        if ($script:serverElasticSearchDiagnosticsUsername -and $script:serverElasticSearchDiagnosticsPassword) {
            $wdParameters.elasticSearchDiagnosticsUsername = $script:serverElasticSearchDiagnosticsUsername
            $wdParameters.elasticSearchDiagnosticsPassword = $script:serverElasticSearchDiagnosticsPassword
            $wdParameters.elasticSearchDiagnosticsRequireAuth = "true"
        }
    }

    $wdParameters.storageType = $script:storageType
    $wdParameters.storageLocation = $script:storageLocation
    $wdParameters.apiKey = $packagesApiKey
    $wdParameters.activitiesApiKey = $activitiesApiKey

    if ($script:azureSignalRConnectionString) {
        $wdParameters.azureSignalRConnectionString = $script:azureSignalRConnectionString
    }
    if ($script:bucketsFileSystemAllowlist) {
        $wdParameters.bucketsFileSystemAllowlist = $script:bucketsFileSystemAllowlist
    }
    if ($script:bucketsAvailableProviders) {
        $wdParameters.bucketsAvailableProviders = $script:bucketsAvailableProviders
    }
    return $wdParameters
}

function Get-MachineKeySettings() {

    if ($action -eq "Deploy") {
        return (Generate-MachineKeySettings)
    }

    return @{
        decryption = $script:decryption;
        decryptionKey = $script:decryptionKey;
        validation = $script:validation;
        validationKey = $script:validationKey;
    }
}

function Generate-MachineKeySettings {

    [CmdletBinding()]
    param (
        [ValidateSet("AES", "DES", "3DES")]
        [string] $decryptionAlgorithm = 'AES',
        [ValidateSet("MD5", "SHA1", "HMACSHA256", "HMACSHA384", "HMACSHA512")]
        [string] $validationAlgorithm = 'HMACSHA256'
    )

    process {

        function BinaryToHex {

            [CmdLetBinding()]
            param($bytes)

            process {

                $builder = new-object System.Text.StringBuilder

                foreach ($b in $bytes)
                {
                    $builder = $builder.AppendFormat([System.Globalization.CultureInfo]::InvariantCulture, "{0:X2}", $b)
                }

                $builder
            }
        }

        switch ($decryptionAlgorithm) {
            "AES" { $decryptionObject = new-object System.Security.Cryptography.AesCryptoServiceProvider }
            "DES" { $decryptionObject = new-object System.Security.Cryptography.DESCryptoServiceProvider }
            "3DES" { $decryptionObject = new-object System.Security.Cryptography.TripleDESCryptoServiceProvider }
        }

        $decryptionObject.GenerateKey()
        $decryptionKey = BinaryToHex($decryptionObject.Key)
        $decryptionObject.Dispose()

        switch ($validationAlgorithm) {
            "MD5" { $validationObject = new-object System.Security.Cryptography.HMACMD5 }
            "SHA1" { $validationObject = new-object System.Security.Cryptography.HMACSHA1 }
            "HMACSHA256" { $validationObject = new-object System.Security.Cryptography.HMACSHA256 }
            "HMACSHA385" { $validationObject = new-object System.Security.Cryptography.HMACSHA384 }
            "HMACSHA512" { $validationObject = new-object System.Security.Cryptography.HMACSHA512 }
        }

        $validationKey = BinaryToHex($validationObject.Key)

        $validationObject.Dispose()

        return @{
            decryption = $decryptionAlgorithm.ToUpperInvariant();
            decryptionKey = $decryptionKey.ToString();
            validation = $validationAlgorithm.ToUpperInvariant();
            validationKey = $validationKey.ToString();
        }
    }
}
function Generate-EncryptionKey {

    $encrypter = New-Object System.Security.Cryptography.AesCryptoServiceProvider

    $encrypter.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $encrypter.BlockSize = 128
    $encrypter.KeySize = 256

    $encrypter.GenerateKey()

    $generateKey = [System.Convert]::ToBase64String($encrypter.Key)

    return $generateKey
}

function Generate-Guid {

    return ([guid]::NewGuid().Guid)
}

function Get-FtpPublishProfile([string] $publishPath) {

    $publishSettingsXml = New-Object System.Xml.XmlDocument

    $publishSettingsXml.Load($publishPath)

    $publishSettings = @{
        FtpPublishUrl = $publishSettingsXml.SelectNodes("//publishProfile[@publishMethod=`"FTP`"]/@publishUrl").value;
        FtpUsername = $publishSettingsXml.SelectNodes("//publishProfile[@publishMethod=`"FTP`"]/@userName").value;
        FtpPassword = $publishSettingsXml.SelectNodes("//publishProfile[@publishMethod=`"FTP`"]/@userPWD").value;
    }

    return $publishSettings
}

function Get-WDPublishSettings([string] $FileName)
{
    if ($FileName -and (Test-Path $FileName)) {
        [xml]$publishProfile = Get-Content -Path $FileName
        $publishSettings = @{
            SiteName = $publishProfile.SelectNodes("//publishData//publishProfile[@publishMethod=`"MSDeploy`"]/@msdeploySite").Value;
            PublishUrl = $publishProfile.SelectNodes("//publishData//publishProfile[@publishMethod=`"MSDeploy`"]/@publishUrl").Value;
            UserName = $publishProfile.SelectNodes("//publishData//publishProfile[@publishMethod=`"MSDeploy`"]/@userName").Value;
            Password = $publishProfile.SelectNodes("//publishData//publishProfile[@publishMethod=`"MSDeploy`"]/@userPWD").Value;
        }
    } else {
        Write-Warning "Publish settings file $FileName could not be loaded"
        $publishSettings = @{}
    }
    return $publishSettings
}
function Get-PublishSettings($publishPath) {

    $publishSettings = if ($publishPath -and (Test-Path $publishPath)) {
        Get-WDPublishSettings -FileName $publishPath
    } else {
        @{
            SiteName = $website;
            PublishUrl = $publishUrl;
            UserName = $username;
            Password = $password;
        }
    }

    $migrationSettings = @{}

    if ($publishPath -and (Test-Path $publishPath)) {
        [xml]$profile = Get-Content -Path $publishPath
        $migrationSettings = @{
            SQLDBConnectionString = $profile.SelectNodes("//publishData//publishProfile[@publishMethod=`"MSDeploy`"]//databases//add[@name='Default']/@connectionString").value;
            FtpPublishUrl = $profile.SelectNodes("//publishProfile[@publishMethod=`"FTP`"]/@publishUrl").value;
            FtpUsername = $profile.SelectNodes("//publishProfile[@publishMethod=`"FTP`"]/@userName").value;
            FtpPassword = $profile.SelectNodes("//publishProfile[@publishMethod=`"FTP`"]/@userPWD").value;
        }
    } else {
        $migrationSettings = @{
            SQLDBConnectionString = $connectionString;
            FtpPublishUrl = $ftpPublishUrl;
            FtpUsername = $ftpUsername;
            FtpPassword = $ftpPassword;
        }
    }

    if ($testAutomationFeatureEnabled) {
        if ($publishPath -and (Test-Path $publishPath)) {
            $migrationSettings.SQLTestAutomationDBConnectionString = $profile.SelectNodes("//publishData//publishProfile[@publishMethod=`"MSDeploy`"]//databases//add[@name='TestAutomation']/@connectionString").value;
        }
    } else {
        $migrationSettings.SQLTestAutomationDBConnectionString = $testAutomationConnectionString
    }

    if ($updateServerFeatureEnabled) {
        if ($publishPath -and (Test-Path $publishPath)) {
            $migrationSettings.SQLUpdateServerDBConnectionString = $profile.SelectNodes("//publishData//publishProfile[@publishMethod=`"MSDeploy`"]//databases//add[@name='UpdateServer']/@connectionString").value;
        }
    } else {
        $migrationSettings.SQLUpdateServerDBConnectionString = $updateServerConnectionString
    }

    if ($insightsFeatureEnabled) {
        if ($publishPath -and (Test-Path $publishPath)) {
            $migrationSettings.SQLInsightsDBConnectionString = $profile.SelectNodes("//publishData//publishProfile[@publishMethod=`"MSDeploy`"]//databases//add[@name='Insights']/@connectionString").value;
        }
    } else {
        $migrationSettings.SQLInsightsDBConnectionString = $insightsConnectionString
    }

    return @{
        PublishSettings = $publishSettings;
        MigrationSettings = $migrationSettings;
    }
}

function Get-PublishParameters($wdParameters, $appSettings) {

    $publishParameters = @{
        encryptionKey = $wdParameters.EncryptionKey;
        packagesApiKey = $wdParameters.apiKey;
        activitiesApiKey = $wdParameters.activitiesApiKey;

        robotsElasticSearchUrl = $wdParameters.ElasticSearchUrl;
        robotsElasticSearchUsername = $wdParameters.ElasticSearchUsername;
        robotsElasticSearchPassword = $wdParameters.ElasticSearchPassword;
        robotsElasticSearchTargets = $wdParameters.ElasticSearchLogger;
        serverElasticSearchUrl = $wdParameters.elasticSearchDiagnosticsUrl;
        serverElasticSearchIndex = $wdParameters.elasticSearchDiagnosticsIndex;
        serverDefaultTargets = $wdParameters.serverDefaultTargets;
        serverElasticSearchDiagnosticsUsername = $wdParameters.elasticSearchDiagnosticsUsername;
        serverElasticSearchDiagnosticsPassword = $wdParameters.elasticSearchDiagnosticsPassword;
        azureSignalRConnectionString = $wdParameters.azureSignalRConnectionString;
        bucketsFileSystemAllowlist = $wdParameters.bucketsFileSystemAllowlist;
        bucketsAvailableProviders = $wdParameters.bucketsAvailableProviders;
    }

    $publishParameters.machineKeyDecryption = $wdParameters.machineKeyDecryption;
    $publishParameters.machineKeyDecryptionKey = $wdParameters.machineKeyDecryptionKey;
    $publishParameters.machineKeyValidation = $wdParameters.machineKeyValidation;
    $publishParameters.machineKeyValidationKey = $wdParameters.machineKeyValidationKey;
    $publishParameters.storageType = $wdParameters.storageType
    $publishParameters.storageLocation = $wdParameters.storageLocations

    return $publishParameters
}

function Prompt-ForContinuation([string] $message = "Do you wish to continue?") {

    $value = ""

    while (($value.ToLowerInvariant() -notin @("y", "n"))) {
        $value = Read-Host "`n$message (y/n)"
    }

    return ($value.ToLowerInvariant() -eq "y")
}

function Download-ConfigurationFile([string] $outputPath, $ftpPublishProfile) {
	
	

    # If the file is already present (e.g. generated earlier in this run), skip.
    if (Test-Path $outputPath) {
        Write-Verbose "Config file already present at '$outputPath'; skipping generation."
        return
    }

    # Generate all three config variants into the same directory so that
    # $script:webConfigPath (Web.config) and both named host variants are
    # available without any FTP/FTPS connection.
    $dir = Split-Path -Path $outputPath -Parent
    New-OrchestratorConfigFiles -tempDirectory $dir
}

function Download-File($url, $userName, $password, $outputPath) {

    Write-Verbose "Downloading file from URL $url to $outputPath"

    try {
        $isFtps = $url -match '^ftps://'
        if ($isFtps -or $url -match '^ftp://') {
            # FtpWebRequest does not natively accept the ftps:// scheme;
            # substitute ftp:// and enable SSL for FTPS connections.
            $normalizedUrl = if ($isFtps) { $url -replace '^ftps://', 'ftp://' } else { $url }
            $uri = New-Object System.Uri($normalizedUrl)
            $ftpRequest = [System.Net.FtpWebRequest][System.Net.WebRequest]::Create($uri)
            $ftpRequest.Method = [System.Net.WebRequestMethods+Ftp]::DownloadFile
            $ftpRequest.Credentials = New-Object System.Net.NetworkCredential($userName.Normalize(), $password.Normalize())
            $ftpRequest.EnableSsl = $isFtps
            $response = $ftpRequest.GetResponse()
            $responseStream = $response.GetResponseStream()
            $fileStream = [System.IO.File]::Create($outputPath)
            $responseStream.CopyTo($fileStream)
            $fileStream.Close()
            $responseStream.Close()
            $response.Close()
        } else {
            $webClient = New-Object System.Net.WebClient
            $webClient.Credentials = New-Object System.Net.NetworkCredential($userName.Normalize(), $password.Normalize())
            $webClient.DownloadFile($url, $outputPath)
        }
        Write-Host "File downloaded successfully from $url"
        return $true
    }
    catch [System.Net.WebException] {
        Write-Host "File could not be downloaded from $url"
        Write-Host $_.Exception.Message
        return $false
    }
}

function Update-AllDatabases($publishSettings) {
    try {
        if ($action -eq "Deploy") {
            Download-ConfigurationFile $script:webConfigPath $script:ftpPublishProfile
        }

        Write-Host "Adding UpdateServer.ModuleEnabled = $updateServerFeatureEnabled to Web.config"
        Set-SettingValue -settingName "UpdateServer.ModuleEnabled" -settingValue $updateServerFeatureEnabled -webConfigPath $script:webConfigPath

        Write-Host "Adding Insights.ModuleEnabled = $insightsFeatureEnabled to Web.config"
        Set-SettingValue -settingName "Insights.ModuleEnabled" -settingValue $insightsFeatureEnabled -webConfigPath $script:webConfigPath

        if ($script:updateProductionDatabase) {
            Write-Host "Updating Database"

            Run-DatabaseMigrations -databaseType "Default" -connectionString $publishSettings.MigrationSettings.SQLDBConnectionString -configFilePath $script:webConfigPath
            if ($testAutomationFeatureEnabled) {
                # Orchestrator connection string is needed for test automation quartz to background task schedules migration.
                Run-DatabaseMigrations -databaseType "TestAutomation" -connectionString $publishSettings.MigrationSettings.SQLTestAutomationDBConnectionString -orchestratorConnectionString $publishSettings.MigrationSettings.SQLDBConnectionString -configFilePath $script:webConfigPath
            }

            if ($updateServerFeatureEnabled) {
                Run-DatabaseMigrations -databaseType "UpdateServer" -connectionString $publishSettings.MigrationSettings.SQLUpdateServerDBConnectionString -configFilePath $script:webConfigPath
            }

            if ($insightsFeatureEnabled) {
                Run-DatabaseMigrations -databaseType "Insights" -connectionString $publishSettings.MigrationSettings.SQLInsightsDBConnectionString -configFilePath $script:webConfigPath
            }
        } else {
            Write-Host "Database is already up-to-date"
        }

        Write-Host "Initializing InternalJobs"
        Initialize-InternalJobs -databaseType "Default" -connectionString $publishSettings.MigrationSettings.SQLDBConnectionString -configFilePath $script:webConfigPath
    }
    catch {
        Write-Host "An error has occured while trying to configure the database."
        DisplayException $_.Exception
        Exit 1
    }
}

function Deploy-ActivitiesInCompositeMode($publishSettings) {

    $activitiesTempFolder = Extract-ActivitiesToTempFolder
    $activitiesLegacyFolder = Join-Path $activitiesTempFolder "legacy_$(Get-Date -Format 'yyyyMMddhhmmssffff')"

    New-Item -Path $activitiesLegacyFolder -ItemType "Directory" | Out-Null

    Build-LegacyActivitiesFolderStructure $activitiesTempFolder $activitiesLegacyFolder
    Write-Host "Migrating activities from folder $activitiesLegacyFolder"

    try {
        & $cliToolPath packages activities `
        --application-path $script:tempDirectory `
        --source-folder $activitiesLegacyFolder

       # Remove-Item $activitiesTempFolder -Recurse -Force | Out-Null

    } catch {
        DisplayException $_.Exception
        Exit 1
    }
}

function Extract-ActivitiesToTempFolder() {
    $tempDirectory = Join-Path $ENV:TEMP "oa_$(Get-Date -Format 'yyyyMMddhhmmssffff')"

    Expand-Archive -LiteralPath $activitiesPackagePath -DestinationPath "$tempDirectory/"
    return $tempDirectory
}


function Build-LegacyActivitiesFolderStructure($activitiesFolder, $targetFolder) {

    $activityPackages = Get-ChildItem $activitiesFolder

    $legacyActivityPackagesFolder = (Join-Path $targetFolder "Activities")

    New-Item -Path $legacyActivityPackagesFolder -ItemType "Directory" | Out-Null

    foreach ($activityPackage in $activityPackages) {
        Write-Verbose "Analyzing $activityPackage ..."
        $activityInfo = Get-ActivityNameAndVersionFromFilePath $activityPackage.FullName
        $activityName = $activityInfo.Name
        $activityVersion = $activityInfo.Version

        $activityFolder = Join-Path $legacyActivityPackagesFolder "$($activityName)"
        if (!(Test-Path $activityFolder))
        {
            New-Item -Path $activityFolder -ItemType "Directory" | Out-Null
        }

        $activityFolderVersion = Join-Path $activityFolder "$($activityVersion)"
        if (!(Test-Path $activityFolderVersion))
        {
            New-Item -Path $activityFolderVersion  -ItemType "Directory" | Out-Null
        }

        Copy-Item -Path $activityPackage.FullName -Destination $activityFolderVersion
    }
}

function Get-ActivityNameAndVersionFromFilePath($filePath) {

    $fileNameWithoutExtension = [System.IO.Path]::GetFileNameWithoutExtension($filePath)

    $nameAndVersionPattern = "(.+)\.(\d+\.\d+\.\d+-*.*)`$"

    $name = $fileNameWithoutExtension -replace $nameAndVersionPattern,"`$1"
    $version = $fileNameWithoutExtension -replace $nameAndVersionPattern,"`$2"

    $activityInfo = @{
        Name = $name;
        Version = $version;
    }

    return $activityInfo
}

function Extract-DirectoryFromZip {
    param(
        [Parameter(Mandatory = $true, Position = 1)]
        [string] $zip,

        [Parameter(Mandatory = $true, Position = 2)]
        [string] $directory,

        [Parameter(Mandatory = $true, Position = 3)]
        [string] $destination,

        [switch] $preserveStructure
    )

    [Void][Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem')

    if (![System.IO.Path]::IsPathRooted($destination))
    {
        throw "The destination path must be an absolute path ($destination)"
    }

    if (!(Test-Path $destination))
    {
        New-Item -ItemType Directory -Path $destination | Out-Null
    }

    [System.IO.Compression.ZipArchive] $zipFile = [System.IO.Compression.ZipFile]::OpenRead($zip)

    $directoryPattern = if ($directory.EndsWith('/')) {
        $directory + '*'
    } else {
        $directory + '/*'
    }

    foreach ($entry in $zipFile.Entries)
    {
        if ($entry.FullName -like $directoryPattern)
        {
            $entryIsDirectory = !$entry.Name
            $entryDestination = (Join-Path $destination $($entry.FullName)) -replace "\\","/"

            if (!$preserveStructure)
            {
                $prefixPattern = $directory -replace '\*','.+'

                $entryDestination = $entryDestination -replace $prefixPattern,''
            }

            if ($entryIsDirectory)
            {
                if (!(Test-Path $entryDestination))
                {
                    New-Item -ItemType Directory -Path $entryDestination | Out-Null
                }
            }
            else
            {
                $entryDestinationDirectory = Split-Path -Path $entryDestination -Parent

                if (!(Test-Path $entryDestinationDirectory))
                {
                    New-Item -ItemType Directory -Path $entryDestinationDirectory | Out-Null
                }

                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $entryDestination, $true)
            }

        }
    }
}

function Extract-FilesFromZip {
    param(
        [Parameter(Mandatory = $true, Position = 1)]  #there are no folders inside archive, only files
        [string] $zipPath,

        [Parameter(Mandatory = $true, Position = 2)]
        [string] $destinationFolder,

        [string] $filePattern
    )

    [Void][Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem')

    if (![System.IO.Path]::IsPathRooted($destinationFolder))
    {
        throw "The destination path must be an absolute path ($destinationFolder)"
    }

    if (!(Test-Path $destinationFolder))
    {
        New-Item -ItemType Directory -Path $destinationFolder | Out-Null
    }

    [System.IO.Compression.ZipArchive] $zipFile = [System.IO.Compression.ZipFile]::OpenRead($zipPath)

    foreach ($entry in $zipFile.Entries)
    {
        if (!$filePattern -or $entry.FullName -like $filePattern){
            $entryDestination = Join-Path $destinationFolder $($entry.Name)

            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $entryDestination, $true)
        }
    }
}

function Get-PendingMigrations {
    param(
        [Parameter(Mandatory = $true)]
        [string] $connectionString,

        [Parameter(Mandatory = $true)]
        [string] $webConfigPath,

        [Parameter(Mandatory = $true)][ValidateSet('Default', 'TestAutomation', 'UpdateServer', 'Insights')]
        [string] $configMigration
    )

    try {
        $migrationsTypeMessage = ""
        $arguments = "database get-pending-migrations --database-type $configMigration --connection-string `"$connectionString`" --configuration-path `"$webConfigPath`""

        $getMigrationsProcess = Invoke-Executable -exeFile $cliToolPath -args $arguments

        Write-Verbose "Process finished. Exit code: $($getMigrationsProcess.ExitCode)"
        Write-ProcessStd $getMigrationsProcess $true

        if($getMigrationsProcess.ExitCode -ne 0) {
            Write-Host "Process finished with error." -ForegroundColor Red
            throw "Getting pending migrations $migrationsTypeMessage failed. Returned exit code $($getMigrationsProcess.ExitCode)";
        }
        else {
            Write-Verbose "Process finished successfully."
            if (-not [string]::IsNullOrWhitespace($getMigrationsProcess.StdOut)) {
                if ($getMigrationsProcess.StdOut -match "Number of pending migrations: (\d+)\.") {
                    if (($Matches[1] -as [int]) -gt 0) {
                        Write-Verbose "Found pending database migrations $migrationsTypeMessage."
                        return $true
                    }
                }
            }

            Write-Verbose "No $configMigration Migrations $migrationsTypeMessage pending."
            return $false
        }
    }
    catch {
        DisplayException $_.Exception.Message
        Write-Error "An error has occured while trying to get pending $configMigration database migrations."
    }
}

function Run-DatabaseMigrations ($databaseType, $connectionString, $orchestratorConnectionString = $null, $configFilePath) {

    Write-Host "Running database migrations"

    $migrationArguments = "database upgrade-database --database-type $databaseType --connection-string `"$connectionString`" --configuration-path `"$configFilePath`""
    if (! [string]::IsNullOrEmpty($orchestratorConnectionString)) {
        $migrationArguments += "--orchestrator-connection-string `"$orchestratorConnectionString`""
    }

    $migrationProcess = Invoke-Executable -exeFile $cliToolPath `
                                          -args $migrationArguments

    Write-Host "Process finished. Exit code: $($migrationProcess.ExitCode)"
    Write-ProcessStd $migrationProcess
    if($migrationProcess.ExitCode -ne 0) {
        Write-Host "Process finished with error." -ForegroundColor Red
        throw "Database migration returned exit code $($migrationProcess.ExitCode)";
    }
    else {
        Write-Host "Process finished successfully."
    }

    Write-Host "Validating database"
    $validationProcess = Invoke-Executable -exeFile $cliToolPath `
                                           -args "database validate-database --database-type $databaseType --connection-string `"$connectionString`" --configuration-path `"$configFilePath`""

    Write-Host "Process finished. Exit code: $($validationProcess.ExitCode)"
    Write-ProcessStd $validationProcess
    if($validationProcess.ExitCode -ne 0) {
        Write-Host "Some issues were detected while validating the database. This error is not fatal. Publish will continue. Exit code: $($validationProcess.ExitCode)" -ForegroundColor Yellow
    }
}

function Initialize-InternalJobs ($databaseType, $connectionString, $configFilePath) {
    Write-Host "Initializing InternalJobs for $databaseType"
    $initJobsProcess = Invoke-Executable -exeFile $cliToolPath `
                                         -args "database recreate-internal-jobs --database-type $databaseType --connection-string `"$connectionString`" --configuration-path `"$configFilePath`""

    Write-Host "Process finished. Exit code: $($initJobsProcess.ExitCode)"
    Write-ProcessStd $initJobsProcess
    if($initJobsProcess.ExitCode -ne 0) {
        Write-Host "Process finished with error." -ForegroundColor Red
        throw "Initializing InternalJobs returned exit code $($initJobsProcess.ExitCode)";
    }
    else {
        Write-Host "InternalJobs for $databaseType initialized."
    }
}

function Invoke-Executable {
    # Runs the specified executable and captures its exit code, stdout
    # and stderr.
    # Returns: custom object.
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [String]$exeFile,
        [Parameter(Mandatory=$false)]
        [String[]]$args,
        [Parameter(Mandatory=$false)]
        [String]$verb,
        [Parameter(Mandatory=$false)]
        [Int]$timeoutMilliseconds=1800000 #30min
    )

    # When containing ';', the password must be quoted.
    $obfuscatedArgs = $args -replace 'password=([^''][^;]+|''[^'']+'')','password=***'
    
    Write-Host $exeFile $obfuscatedArgs

    # Setting process invocation parameters.
    $oPsi = New-Object -TypeName System.Diagnostics.ProcessStartInfo
    $oPsi.CreateNoWindow = $true
    $oPsi.UseShellExecute = $false
    $oPsi.RedirectStandardOutput = $true
    $oPsi.RedirectStandardError = $true
    $oPsi.FileName = $exeFile
    if (! [String]::IsNullOrEmpty($args)) {
        $oPsi.Arguments = $args
    }
    if (! [String]::IsNullOrEmpty($verb)) {
        $oPsi.Verb = $verb
    }

    # Creating process object.
    $oProcess = New-Object -TypeName System.Diagnostics.Process
    $oProcess.StartInfo = $oPsi

    # Creating string builders to store stdout and stderr.
    $oStdOutBuilder = New-Object -TypeName System.Text.StringBuilder
    $oStdErrBuilder = New-Object -TypeName System.Text.StringBuilder

    # Adding event handers for stdout and stderr.
    $sScripBlock = {
        if (! [String]::IsNullOrEmpty($EventArgs.Data)) {
            $Event.MessageData.AppendLine($EventArgs.Data)
        }
    }
    $oStdOutEvent = Register-ObjectEvent -InputObject $oProcess `
        -Action $sScripBlock -EventName 'OutputDataReceived' `
        -MessageData $oStdOutBuilder
    $oStdErrEvent = Register-ObjectEvent -InputObject $oProcess `
        -Action $sScripBlock -EventName 'ErrorDataReceived' `
        -MessageData $oStdErrBuilder

    # Starting process.
    [Void]$oProcess.Start()
    $oProcess.BeginOutputReadLine()
    $oProcess.BeginErrorReadLine()
    $bRet=$oProcess.WaitForExit($TimeoutMilliseconds)
    if (-Not $bRet)
    {
        $oProcess.Kill();
        throw [System.TimeoutException] ($exeFile + " was killed due to timeout after " + ($TimeoutMilliseconds/1000) + " sec ")
    }
    # Unregistering events to retrieve process output.
    Unregister-Event -SourceIdentifier $oStdOutEvent.Name
    Unregister-Event -SourceIdentifier $oStdErrEvent.Name

    $oResult = New-Object -TypeName PSObject -Property ([Ordered]@{
        "ExeFile"  = $exeFile;
        "Args"     = $args -join " ";
        "ExitCode" = $oProcess.ExitCode;
        "StdOut"   = $oStdOutBuilder.ToString().Trim();
        "StdErr"   = $oStdErrBuilder.ToString().Trim()
    })

    return $oResult
}

function DisplayException($ex) {
    Write-Host $ex | Format-List -Force
}

function Download-PublishProfile([string] $outputPath, [string] $slotName) {

    Get-AzWebAppSlotPublishingProfile -OutputFile $outputPath -ResourceGroupName $resourceGroupName -Name $appServiceName -Slot $slotName | Out-Null

}

function Download-WebsiteFile([string] $websiteFilePath, [string] $outputPath, $publishProfile) {

    $fileUrl = if ($websiteFilePath.StartsWith("/")) {
        $publishProfile.FtpPublishUrl + $websiteFilePath
    } else {
        $publishProfile.FtpPublishUrl + "/" + $websiteFilePath
    }

    Download-File -url $fileUrl -userName $publishProfile.FtpUsername -password $publishProfile.FtpPassword -outputPath $outputPath
}

function Get-AllDefaultParameterValues([string] $parametersXmlPath) {

    $parametersXml = New-Object System.Xml.XmlDocument
    $parametersXml.Load($parametersXmlPath)

    $parameterNodes = $parametersXml.SelectNodes("/parameters/*")

    $paramsWithDefaultValues = @{}
    $parameterNodes.GetEnumerator() | foreach-object {
        if ($_.defaultValue) {
            $paramsWithDefaultValues."$($_.Name)" = $_.defaultValue
        }
        if ($_.value) {
            $paramsWithDefaultValues."$($_.Name)" = $_.value
        }
    }
    return $paramsWithDefaultValues
}

function Get-WDParameterValue([string] $parameterName, [string] $parametersXmlPath, [string] $webConfigPath) {

    $parametersXml = New-Object System.Xml.XmlDocument
    $webConfigXml = New-Object System.Xml.XmlDocument

    $parametersXml.Load($parametersXmlPath)
    $webConfigXml.Load($webConfigPath)

    $parameterNode = $parametersXml.SelectSingleNode("/parameters/parameter[@name='$parameterName']")

    if (!$parameterNode) {
        Write-Warning "No WD parameter named $parameterName was found in parameters.xml file '$parametersXmlPath'"
        return ""
    } else {
        $parameterXpath = $parameterNode.SelectSingleNode("parameterEntry[@kind='XmlFile']/`@match").value
        $parameterValue = $webConfigXml.SelectSingleNode($parameterXpath).value

        return $parameterValue
    }
}

function Get-WebConfigSettingValue([string] $settingName, [string] $webConfigPath) {
    $settingValue
    $webConfigXml = New-Object System.Xml.XmlDocument

    $webConfigXml.Load($webConfigPath)
    $settingNode = Select-Xml -Path $webConfigPath -XPath "//configuration/appSettings/add[@key='$settingName']" | Select-Object -ExpandProperty Node -First 1

    if($settingNode) {
        $settingValue = $settingNode.value
    }

    return $settingValue
}

function Get-SettingValue([string] $settingName, [string] $webConfigPath, [string] $fallbackValue) {
    if ($existingProdAppSettings."$settingName") {
        return $existingProdAppSettings."$settingName"
    }
    $webConfigValue = Get-WebConfigSettingValue $settingName $webConfigPath

    if (![string]::IsNullOrWhitespace($webConfigValue)) {
        $webConfigValue = ($webConfigValue | Out-String).Trim()
        return $webConfigValue
    }
    return $fallbackValue
}

function Set-SettingValue {
    param (
        [Parameter(Mandatory = $true)]
        [string] $settingName,
        [Parameter(Mandatory = $true)]
        [string] $settingValue,
        [Parameter(Mandatory = $true)]
        [string] $webConfigPath
    )

    $appSettingPath = "//configuration/appSettings"

    [xml] $configurationDocument = Get-Content $webConfigPath
    $appSettingsNode = $configurationDocument.SelectSingleNode($appSettingPath)

    if($appSettingsNode -eq $null)
    {
        Write-Error "Invalid configuration file, AppSettings does not exists"
        Exit 1
    }

    $nodeToUpdate = $configurationDocument.SelectSingleNode("$appSettingPath/add[@key='$settingName']")

    if($nodeToUpdate -ne $null) {
        $nodeToUpdate.Value = $settingValue
    }
    else {
        $newSettingNode = $configurationDocument.CreateNode("element", "add", "")
        $newSettingNode.SetAttribute("key", $settingName)
        $newSettingNode.SetAttribute("value", $settingValue)
        $appSettingsNode = $configurationDocument.SelectSingleNode($appSettingPath).AppendChild($newSettingNode)
    }

    $configurationDocument.Save($webConfigPath)
}

function Set-AppSettings([System.Collections.Hashtable] $settings, [string]$slotName) {

    if ($settings) {
        Set-AzWebAppSlot -AppSettings $settings -Name $appServiceName -ResourceGroupName $resourceGroupName -slot $slotName
   }
}

function Read-ExistingAppSettings([string] $slotName){
    $existingAppSettings = (Get-AzWebAppSlot -Name $appServiceName -ResourceGroupName $resourceGroupName -slot $slotName).SiteConfig.AppSettings

    if ($existingAppSettings) {
        $existingAppSettingsHash = New-Object System.Collections.Hashtable
        $existingAppSettings.GetEnumerator() | ForEach-Object {
            $existingAppSettingsHash."$($_.Name)" = $_.Value
        } | Out-Null
    }

    return $existingAppSettingsHash
}

function Add-Setting([System.Object] $deployAppSettings, $settingName, $settingValue) {
    if ($deployAppSettings) {
        $appSettingsHash = ConvertTo-Hashtable $deployAppSettings
        $appSettingsHash[$settingName]= $settingValue
    } else{
        $appSettingsHash = @{
            $settingName = $settingValue
        }
    }
    return $appSettingsHash
}

function Apply-AppSettings([System.Object] $deployAppSettings, [string] $slotName){
    $existingAppSettings = Read-ExistingAppSettings -slotName $slotName

    if ($deployAppSettings) {
        $appSettingsHash = ConvertTo-Hashtable $deployAppSettings
        Write-Host "`nSetting the following Application Settings: " -ForegroundColor Yellow
        $mergedAppSettings = if ($existingAppSettings) {
            Merge-Hashtables -from $appSettingsHash -to $existingAppSettings
            } else {
            $appSettingsHash
            }
        Write-Host ($mergedAppSettings | Out-String)
        Set-AppSettings -settings $mergedAppSettings -slotName $slotName
    } else {
        Write-Host "`nNo new Application Settings added. Current App Settings set on $appServiceName " -ForegroundColor Yellow
        Write-Host ($existingAppSettings | Out-String)
    }
}

function SwapSlots()
{
    Write-Host "Swapping slot $standbySlotName with $productionSlotName ... " -ForegroundColor Yellow

    Switch-AzWebAppSlot -SourceSlotName $standbySlotName.Trim() -DestinationSlotName $productionSlotName -ResourceGroupName $resourceGroupName -Name $appServiceName

}

function Convert-StringToBoolean([Parameter(ValueFromPipeline = $true)][string] $value) {
    return ($value.ToLowerInvariant() -eq "true")
}

function Read-JsonAsHashtable($filePath) {

    $fileContent = [System.IO.File]::ReadAllText($filePath)
    $psCustomObject = ConvertFrom-Json -InputObject $fileContent
    $hashtable = ConvertTo-Hashtable $psCustomObject

    return $hashtable
}

function ConvertTo-Hashtable($object) {

    $type = $object.GetType()

    if ($type -eq [System.Collections.Hashtable]) {
        return (New-StringHashtableFromPropertyEnumerator ($object.GetEnumerator()))
    } else {

        if ($type -eq [System.Management.Automation.PSCustomObject]) {
            return (New-StringHashtableFromPropertyEnumerator ($object.PSObject.Properties))
        } else {
            throw "Cannot convert object of type $type to [System.Collections.Hashtable]"
        }
    }
}

function Merge-Hashtables([System.Collections.Hashtable] $from, [System.Collections.Hashtable] $to) {

    $result = New-Object System.Collections.Hashtable

    if ($to) {
        $to.GetEnumerator() | ForEach-Object {
            $result."$($_.Name)" = $_.Value
        } | Out-Null
    }

    if ($from) {
        $from.GetEnumerator() | ForEach-Object {
            $result."$($_.Name)" = $_.Value
        } | Out-Null
    }

    return $result
}

function New-StringHashtableFromPropertyEnumerator($propertyEnumerator) {

    $hashtable = New-Object System.Collections.Hashtable

    $propertyEnumerator | ForEach-Object {
        $hashtable."$($_.Name)" = if ($null -ne $_.Value) {
            $_.Value.ToString()
        } else {
            [string]::Empty
        }
    }

    return $hashtable
}

function Remove-ConfigBuilders {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ $_ | Test-Path -PathType Leaf })]
        [string] $configFilePath
    )
    try {
        $doc = (Select-Xml -Path $configFilePath -XPath / ).Node

        Select-Xml -Xml $doc -XPath "/configuration/configSections/section[@name='configBuilders']" |
            Select-Object -ExpandProperty Node |
            ForEach-Object {
                $_.ParentNode.RemoveChild($_) | Out-Null
            }

        Select-Xml -Xml $doc -XPath "/configuration/configBuilders" |
            Select-Object -ExpandProperty Node |
            ForEach-Object {
                $_.ParentNode.RemoveChild($_) | Out-Null
            }

        Select-Xml -Xml $doc -XPath "/configuration/*/@configBuilders" |
            Select-Object -ExpandProperty Node |
            ForEach-Object {
                $_.OwnerElement.RemoveAttributeNode($_) | Out-Null
            }

        $doc.Save($configFilePath)
    }
    catch {
        Write-Host "Failed to remove configBuilders from file '$configFilePath'"
        DisplayException $_.Exception
    }
}

function Invoke-ExtensionsValidation {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateScript({ $_ | Test-Path -PathType Leaf })]
        [string] $configFilePath
    )

    Write-Host "Validating extensions"
    $validationProcess = Invoke-Executable -exeFile $cliToolPath `
                                           -args "extensions --configuration-path `"$configFilePath`""

    Write-Host "Process finished. Exit code: $($validationProcess.ExitCode)"
    Write-ProcessStd $validationProcess

    if($validationProcess.ExitCode -ne 0) {
        Write-Host "Some issues were detected while validating extensions." -ForegroundColor Red
        Exit 1
    }
}

function Invoke-DatabasePreValidations($databaseType, $connectionString, $configFilePath, [bool] $ignoreClassicFoldersError)
{
    Write-Host "Pre-validating database"
    $validationProcess = Invoke-Executable -exeFile $cliToolPath `
                                           -args "database pre-validate --database-type $databaseType --connection-string `"$connectionString`" --configuration-path `"$configFilePath`""

    Write-Host "Process finished. Exit code: $($validationProcess.ExitCode)"

    [string[]] $ignoredErrorCodes

    if ($ignoreClassicFoldersError) {
        $ignoredErrorCodes += "ClassicFoldersPresent"
    }

    $breakInstallation = 0

    if($validationProcess.ExitCode -ne 0) {
        Write-Host "Encountered the following errors:" -ForegroundColor Red

        $result = $validationProcess.StdErr | ConvertFrom-Json

        foreach($error in $result){
            Write-Host $error.ErrorMessage -ForegroundColor Red

            if(-not ($error.ErrorCode -in $ignoredErrorCodes))
            {
                $breakInstallation = 1;
            }
        }
    }

    if($breakInstallation -eq 1){
        Write-Host "Breaking the installation ..." -ForegroundColor Red
        Exit 1
    }
}

function Write-ProcessStd{
    param (
        [Parameter(Mandatory = $true)]
        [psobject] $process,
        [Parameter(Mandatory = $false)]
        [bool] $verboseMessage = $false        
    )

    if(-not [string]::IsNullOrWhiteSpace($process.StdOut)){
        if($verboseMessage){
            Write-Verbose "StdOut: $($process.StdOut)"
        }else{
            Write-Host "StdOut: $($process.StdOut)"
        }
    }
    
    if(-not [string]::IsNullOrWhiteSpace($process.StdErr)){
        Write-Host "StdErr: $($process.StdErr)" -ForegroundColor Red
    }    
}

function Get-WebAppUrl {

    param (
        [Parameter(Mandatory)]
        [string] $resourceGroupName,

        [Parameter(Mandatory)]
        [string] $webAppName
    )

    $webApp = Get-AzWebApp -ResourceGroupName $resourceGroupName -Name $webAppName
    $preferedHost = $webApp.HostNames | Select-Object -First 1

    return "https://$($preferedHost)"
}

# ============================================================================
# Checkpoint / resume helpers
# ============================================================================

# Ensures the Az PowerShell module is imported regardless of whether
# Set-ScriptConstants is being skipped on a resume run.
function Ensure-AzureModule {
    if (Get-Module -Name Az.Accounts) {
        Write-Verbose "Az module already loaded — skipping import."
        return
    }
    if (Test-Path $azModuleLocation) {
        Import-AzModuleFromLocalMachine
    } else {
        $azAccountsModule = Get-Module -Name Az.Accounts -ListAvailable -Verbose:$false |
                            Where-Object { $_.Version -ge $azAccountsModuleVersion }
        $azWebsitesModule = Get-Module -Name Az.Websites -ListAvailable -Verbose:$false |
                            Where-Object { $_.Version -ge $azWebsitesModuleVersion }
        if ($azAccountsModule -and $azWebsitesModule) {
            Import-Module Az -Version $azModuleVersion -Verbose:$false
        } else {
            Write-Host "Installing Az module $azModuleVersion ..." -ForegroundColor Yellow
            Install-Module Az -RequiredVersion $azModuleVersion -Force -AllowClobber -Verbose:$false
            Import-Module Az -Version $azModuleVersion -Verbose:$false
        }
    }
}

# Loads a prior checkpoint when -resume is given, restoring every script-scope
# variable that Set-ScriptConstants would normally compute.
function Initialize-Checkpoint {
    if ($resume -and (Test-Path $script:checkpointFile)) {
        Write-Host "`nLoading checkpoint: '$script:checkpointFile'" -ForegroundColor Cyan
        $saved = [System.IO.File]::ReadAllText($script:checkpointFile) | ConvertFrom-Json

        $script:completedSteps = if ($saved.CompletedSteps) { @($saved.CompletedSteps) } else { @() }

        # Restore every persisted variable into script scope.
        # Simple scalars, booleans, and arrays come back cleanly from JSON.
        # Nested objects (hashtables) come back as PSCustomObjects, which still
        # support dot-notation access — so no explicit conversion is needed.
        $s = $saved.State
        foreach ($prop in $s.PSObject.Properties) {
            Set-Variable -Name $prop.Name -Value $prop.Value -Scope Script
        }
        # Force arrays to stay arrays even when serialized as a single element
        $script:defaultFolderstoSkip = @($s.defaultFolderstoSkip)
        $script:defaultFilesToSkip   = @($s.defaultFilesToSkip)

        Write-Host "Restored state. Completed steps: [$($script:completedSteps -join ' > ')]`n" -ForegroundColor Cyan
    } else {
        $script:completedSteps = @()
        # Wipe any stale checkpoint left from a previous non-resume run
        if (-not $resume -and (Test-Path $script:checkpointFile)) {
            Remove-Item $script:checkpointFile -Force
        }
    }
}

# Persists script-scope state and the completed-steps list to the checkpoint file.
function Save-Checkpoint {
    $state = @{
        # --- paths ---
        tempDirectory            = $script:tempDirectory
        publishSettingsPath      = $script:publishSettingsPath
        webConfigPath            = $script:webConfigPath
        parametersXmlPath        = $script:parametersXmlPath
        newConfigPath            = $script:newConfigPath
        newConfigName            = $script:newConfigName
        webArchiveContentPath    = $script:webArchiveContentPath
        cliToolPath              = $script:cliToolPath
        productionWebConfigPath  = $script:productionWebConfigPath
        # --- config names ---
        aspNetConfigName         = $script:aspNetConfigName
        aspNetCoreConfigName     = $script:aspNetCoreConfigName
        dotNetCoreConfigName     = $script:dotNetCoreConfigName
        msDeployExe              = $script:msDeployExe
        # --- slot / swap ---
        hotswap                  = $script:hotswap
        deploymentSlotName       = $script:deploymentSlotName
        fullAppServiceName       = $script:fullAppServiceName
        updateProductionDatabase = $script:updateProductionDatabase
        # --- nuget / package migration ---
        packagesApiKey           = $script:packagesApiKey
        activitiesApiKey         = $script:activitiesApiKey
        storageType              = $script:storageType
        storageLocation          = $script:storageLocation
        runPackageMigrator       = $script:runPackageMigrator
        instanceKey              = $script:instanceKey
        nugetRepositoryType      = $script:nugetRepositoryType
        packagesUrl              = $script:packagesUrl
        activitiesUrl            = $script:activitiesUrl
        # --- crypto ---
        decryption               = $script:decryption
        decryptionKey            = $script:decryptionKey
        validation               = $script:validation
        validationKey            = $script:validationKey
        encryptionKey            = $script:encryptionKey
        # --- redis / elastic ---
        redisConnectionString              = $script:redisConnectionString
        loadBalancerUseRedis               = $script:loadBalancerUseRedis
        robotsElasticSearchUrl             = $script:robotsElasticSearchUrl
        robotsElasticSearchUsername        = $script:robotsElasticSearchUsername
        robotsElasticSearchPassword        = $script:robotsElasticSearchPassword
        robotsElasticSearchTargets         = $script:robotsElasticSearchTargets
        serverElasticSearchUrl             = $script:serverElasticSearchUrl
        serverElasticSearchDiagnosticsUsername = $script:serverElasticSearchDiagnosticsUsername
        serverElasticSearchDiagnosticsPassword = $script:serverElasticSearchDiagnosticsPassword
        serverElasticSearchIndex           = $script:serverElasticSearchIndex
        serverDefaultTargets               = $script:serverDefaultTargets
        # --- misc ---
        azureSignalRConnectionString = $script:azureSignalRConnectionString
        bucketsFileSystemAllowlist   = $script:bucketsFileSystemAllowlist
        bucketsAvailableProviders    = $script:bucketsAvailableProviders
        deployMethod                 = $script:deployMethod
        defaultFolderstoSkip         = $script:defaultFolderstoSkip
        defaultFilesToSkip           = $script:defaultFilesToSkip
        # --- objects (serialised as nested JSON) ---
        ftpPublishProfile            = $script:ftpPublishProfile
        defaultParameterXmlValues    = $script:defaultParameterXmlValues
        existingProdAppSettings      = $script:existingProdAppSettings
    }

    $json = @{
        Version        = "1.0"
        Timestamp      = (Get-Date -Format "o")
        CompletedSteps = @($script:completedSteps)
        State          = $state
    } | ConvertTo-Json -Depth 10

    [System.IO.File]::WriteAllText($script:checkpointFile, $json,
        [System.Text.UTF8Encoding]::new($false))
}

# Deletes the checkpoint file once the full deployment succeeds.
function Remove-Checkpoint {
    if (Test-Path $script:checkpointFile) {
        Remove-Item $script:checkpointFile -Force
        Write-Host "Deployment checkpoint cleared." -ForegroundColor Green
    }
}

# Call at the START of a named step.
# Returns $true  → step was already done; caller should skip it.
# Returns $false → step needs to run;   caller should execute then call End-Step.
function Start-Step([string] $stepName) {
    if ($script:completedSteps -contains $stepName) {
        Write-Host "[SKIP ] $stepName (already completed)" -ForegroundColor Cyan
        return $true
    }
    Write-Host "`n[STEP ] $stepName ..." -ForegroundColor Yellow
    return $false
}

# Call at the END of a named step after it completes successfully.
function End-Step([string] $stepName) {
    $script:completedSteps += $stepName
    Save-Checkpoint
    Write-Host "[DONE ] $stepName" -ForegroundColor Green
}

# ============================================================================

# Writes all three Orchestrator config-file variants into $tempDirectory using
# the baseline schema drawn from UiPath.Orchestrator.dll.config.
# All three share the same XML body — the file name alone tells the host which
# runtime flavour to expect (classic ASP.NET, ASP.NET Core, or .NET Core).
# Using a generated baseline means FTP/FTPS is never needed just to seed the
# temp folder for database migrations or parameter-reading.
function New-OrchestratorConfigFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string] $tempDirectory
    )

    Write-Host "Generating baseline Orchestrator config files in '$tempDirectory' ..." -ForegroundColor Yellow

    # --- embedded template (based on UiPath.Orchestrator.dll.config) ----------
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
  <!-- Logging configuration -->
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
    <!-- Do not use '_' in setting name. -->
    <!-- Advanced installation settings -->
    <add key="Features.CredentialStoreHost.Enabled" value="false"/>
    <add key="DeploymentUrl" value="" />
    <add key="MonitoringUrl" value="" />
    <add key="NotificationHubUrl" value="" />
    <add key="Logs.RobotLogs.ReadTarget" value="database" />
    <add key="LoggingUrl" value="" />
    <add key="LoggingIndex" value="logflow" />
    <add key="QueuesSvcUrl" value="" />
    <add key="TermsAndConditionsRegisterUrl" value="https://www.uipath.com/terms-of-use" />
    <!-- Queues -->
    <add key="inProgressMaxNumberOfMinutes" value="1440" />
    <add key="QueuesStatisticsScheduleCron" value="10 0/1 * 1/1 * ? *" />
    <add key="UpdateUncompletedItemsJobCron" value="0 0 0/1 1/1 * ? *" />
    <add key="Queue.ProcessActivationSchedule" value="0 0/30 * 1/1 * ? *" />
    <add key="Queue.MaxSlaInMinutes" value="129600" />
    <!-- Alerts -->
    <add key="DailyAlertMailJobCron" value="0 0 7 1/1 * ? *" />
    <add key="NotRespondingRobotsJobCron" value="0 0/1 * 1/1 * ? *" />
    <add key="Alerts.Email.Enabled" value="false" />
    <add key="NotificationDistributerJobCron" value="0/10 1/1 * 1/1 * ? *" />
    <add key="PeriodicErrorMailJobCron" value="0 0/10 * 1/1 * ? *" />
    <add key="AggregateLicenseUsageStatsJobCron" value="0 0 0/1 1/1 * ? *" />
    <add key="SystemJobs.LicenseExpirationAlert.Cron" value="0 0 7 1/1 * ? *" />
    <add key="SystemJobs.LicenseExpirationAlert.DaysBefore" value="180,90,30,14,7,1" />
    <add key="SystemJobs.PurgeOldErrorLogs.Cron" value="0 0 1 1/1 * ? *" />
    <add key="SystemJobs.JobTriggersFallback.Cron" value="0 0/10 * 1/1 * ? *" />
    <add key="SystemJobs.JobTriggersTimerCheck.Cron" value="0 0/1 * 1/1 * ? *" />
    <add key="SystemJobs.QueueSlaAlerting.Cron" value="0 7/30 * 1/1 * ? *" />
    <!-- Deployment -->
    <add key="NuGet.Packages.ApiKey" value="49B62823-8342-4ACA-A40B-D8741FB07178" />
    <add key="NuGet.Activities.ApiKey" value="49B62823-8342-4ACA-A40B-D8741FB07178" />
    <add key="Deployment.Libraries.AllowTenantPublish" value="true" />
    <!-- Authorization -->
    <add key="Auth.UserLockOut.IsEnabled" value="true" />
    <add key="Auth.UserLockOut.MaxFailedAccessAttemptsBeforeLockout" value="10" />
    <add key="Auth.UserLockOut.DefaultAccountLockoutSeconds" value="300" />
    <add key="Auth.Password.DefaultExpirationDays" value="0" />
    <!-- Load balancer -->
    <add key="LoadBalancer.UseRedis" value="false" />
    <add key="LoadBalancer.Enabled" value="false" />
    <add key="LoadBalancer.Redis.ConnectionString" value="localhost:6379" />
    <!-- Password vault -->
    <add key="Plugins.SecureStores" value=""/>
    <add key="CustomTitle" value="" />
    <add key="HelpUrl" value="https://docs.uipath.com/{HELP-LANGUAGE-PLACEHOLDER}/orchestrator/standalone/2024.10/user-guide/introduction" />
    <add key="Database.EnableAutomaticMigrations" value="false"/>
    <!-- Logs -->
    <add key="Logs.Elasticsearch.MaxResultWindow" value="10000" />
    <add key="SystemJobs.ElasticReloadToken.Cron" value="* 0/19 * ? * * *"/>
    <!-- Webhooks -->
    <add key="Webhooks.Enabled" value="true" />
    <!-- Scalability -->
    <add key="Scalability.Heartbeat.PeriodSeconds" value="30" />
    <add key="Scalability.Heartbeat.FailureThreshold" value="4" />
    <add key="Scalability.SignalR.Enabled" value="true" />
    <add key="Scalability.SignalR.Transport" value="7" />
    <add key="Scalability.SignalR.AuthenticationEnabled" value="false" />
    <!-- Feature flags -->
    <add key="Features.SmartCardAuthentication.Enabled" value="false" />
    <!-- Media Recording -->
    <add key="MediaRecording.Enabled" value="true" />
    <!-- Storage -->
    <add key="Storage.Type" value="FileSystem" />
    <add key="Storage.Location" value="RootPath=.\Storage" />
    <!-- Cloud RPA -->
    <add key="CloudRPA.Instance.Enabled" value="false" />
    <!-- Licensing -->
    <add key="License.ServiceURL" value="https://activate.uipath.com"/>
    <!-- Pagination -->
    <add key="Pagination.Limits.Enabled" value="true" />
    <!-- Triggers -->
    <add key="Triggers.DisableWhenFailedCount" value="10" />
    <add key="Triggers.DisableWhenFailingSinceDays" value="1" />
    <!-- Buckets -->
    <add key="Buckets.AvailableProviders" value="Orchestrator,Amazon,Azure,Minio,S3Compatible" />
    <add key="Buckets.FileSystem.Allowlist" value="" />
    <!-- Docs -->
    <add key="DocsReferenceUri" value="https://docs.uipath.com/orchestrator/reference" />
    <add key="Features.NotifiableUsersCache.Enabled" value="true" />
    <add key="Features.Queues.ValidateTransitionFromFinalToNew" value="true"/>
    <add key="Features.Queues.ValidateSuccessFailureTransition" value="true"/>
    <add key="VideoRecording.RetentionJobEnabled" value="false" />
    <add key="Telemetry.AppInsights.Key" value="4f1c407b-e9f8-48f5-999a-d7c8e0f4ee20"/>
  </appSettings>
  <secureAppSettings>
    <add key="EncryptionKey" value=""/>
  </secureAppSettings>
  <system.web>
    <!-- Not used for encryption; here to back up the machine key from ASP.NET in case of rollback. -->
    <machineKey decryption="Auto" decryptionKey="AutoGenerate,IsolateApps"
                validation="SHA1" validationKey="AutoGenerate,IsolateApps" />
  </system.web>
</configuration>
'@
    # --------------------------------------------------------------------------

    # All three host variants share the same XML body; only the file name differs.
    $fileNames = @(
        "UiPath.Orchestrator.dll.config",           # .NET Core host
        "UiPath.Orchestrator.WebCore.Host.exe.config", # ASP.NET Core host
        "Web.config"                                # Classic ASP.NET host
    )

    foreach ($fileName in $fileNames) {
        $destPath = Join-Path $tempDirectory $fileName
        # Write UTF-8 without BOM so the .NET XML parser is happy
        [System.IO.File]::WriteAllText($destPath, $templateXml, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  Generated: $destPath" -ForegroundColor Green
    }
}

# Applies Web Deploy parameter values directly to a deployed config file using
# the XPath mappings in parameters.xml.  Used by Invoke-KuduZipDeploy so that
# the same encryption keys / machine keys / storage settings that MsDeploy would
# inject are baked into the config before the zip is pushed via Kudu.
function Apply-WdParametersToConfig {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Hashtable] $parameters,

        [Parameter(Mandatory = $true)]
        [string] $configPath,

        [Parameter(Mandatory = $true)]
        [string] $parametersXmlPath
    )

    Write-Verbose "Applying WD parameters to config file $configPath"

    [xml] $configDoc = Get-Content $configPath
    $paramsXml = New-Object System.Xml.XmlDocument
    $paramsXml.Load($parametersXmlPath)

    $updated = $false
    foreach ($paramName in $parameters.Keys) {
        $paramNode = $paramsXml.SelectSingleNode("/parameters/parameter[@name='$paramName']")
        if ($paramNode) {
            $paramEntry = $paramNode.SelectSingleNode("parameterEntry[@kind='XmlFile']")
            if ($paramEntry) {
                $xpath = $paramEntry.match
                $attrNode = $configDoc.SelectSingleNode($xpath)
                if ($attrNode) {
                    $attrNode.Value = $parameters[$paramName]
                    $updated = $true
                    Write-Verbose "Set parameter '$paramName' in config"
                } else {
                    Write-Verbose "XPath '$xpath' for parameter '$paramName' did not match any node in config; skipping"
                }
            }
        } else {
            Write-Verbose "Parameter '$paramName' not found in parameters.xml; skipping"
        }
    }

    if ($updated) {
        $configDoc.Save($configPath)
    }
}

# Deploys the Web Deploy package via the Kudu REST ZIP deploy API
# (POST https://<scm-host>/api/zipdeploy).  No msdeploy.exe required;
# uses only an HTTPS request, making it suitable when FTP/FTPS ports are
# blocked or when Web Deploy is unavailable.
function Invoke-KuduZipDeploy {
    param(
        [Parameter(Mandatory = $true)]
        [string] $package,

        [Parameter(Mandatory = $true)]
        $publishSettings,

        [Parameter(Mandatory = $true)]
        [System.Collections.Hashtable] $wdParameters
    )

    # publishSettings.PublishUrl is the SCM host, e.g. <appname>.scm.azurewebsites.net
    $publishUrl = $publishSettings.PublishUrl
    $userName   = $publishSettings.UserName
    $password   = $publishSettings.Password

    Write-Host "`nDeploying package via Kudu ZIP deploy to https://$publishUrl" -ForegroundColor Yellow

    # Extract the web-app content from the Web Deploy package into a temp folder.
    # $script:webArchiveContentPath is set by Set-ScriptConstants based on whether
    # the package targets classic ASP.NET or .NET Core.
    $contentTempDir = Join-Path ([System.IO.Path]::GetTempPath()) "kudu-content-$(Get-Date -f 'yyyyMMddhhmmssfff')"
    New-Item -ItemType Directory -Path $contentTempDir | Out-Null

    Write-Host "Extracting web content from package (path pattern: $script:webArchiveContentPath)..."
    Extract-DirectoryFromZip -zip $package -directory $script:webArchiveContentPath -destination "$contentTempDir/"

    # Apply WD parameters (encryption key, machine keys, storage settings, etc.)
    # directly into the extracted config file so they are present when deployed.
    $deployConfigPath = Join-Path $contentTempDir $script:newConfigName
    if (Test-Path $deployConfigPath) {
        Write-Host "Applying deployment parameters to config file..."
        Apply-WdParametersToConfig -parameters $wdParameters -configPath $deployConfigPath -parametersXmlPath $script:parametersXmlPath
    } else {
        Write-Warning "Config file not found at '$deployConfigPath'; deployment parameters will not be applied to web.config."
    }

    # Re-pack the content into a plain zip (wwwroot layout) for Kudu.
    [Void][Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem')
    $kuduZipPath = Join-Path ([System.IO.Path]::GetTempPath()) "kudu-deploy-$(Get-Date -f 'yyyyMMddhhmmssfff').zip"
    Write-Host "Creating Kudu deployment zip from extracted content..."
    [System.IO.Compression.ZipFile]::CreateFromDirectory($contentTempDir, $kuduZipPath)

    $kuduUrl = "https://$publishUrl/api/zipdeploy"
    Write-Host "`nKudu endpoint: $kuduUrl" -ForegroundColor Yellow

    $shouldContinue = $unattended -or (Prompt-ForContinuation)
    if (!$shouldContinue) {
        Write-Host "`nExiting...`n" -ForegroundColor Yellow
        Remove-Item $contentTempDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $kuduZipPath    -Force          -ErrorAction SilentlyContinue
        Exit 0
    }

    $credentials = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${userName}:${password}"))
    $headers = @{
        Authorization  = "Basic $credentials"
        "Content-Type" = "application/zip"
    }

    try {
        $response = Invoke-WebRequest -Uri $kuduUrl -Method POST -InFile $kuduZipPath -Headers $headers -UseBasicParsing
        if ($response.StatusCode -in @(200, 202)) {
            Write-Host "`nKudu ZIP deploy succeeded. HTTP $($response.StatusCode)" -ForegroundColor Green
        } else {
            Write-Error "`nKudu ZIP deploy returned unexpected status: HTTP $($response.StatusCode)"
            Exit 1
        }
    } catch {
        Write-Error "`nKudu ZIP deploy failed: $($_.Exception.Message)"
        if ($_.Exception.Response) {
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                Write-Error "Server response: $($reader.ReadToEnd())"
            } catch {}
        }
        Exit 1
    } finally {
        Remove-Item $contentTempDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $kuduZipPath    -Force          -ErrorAction SilentlyContinue
    }
}

Main
