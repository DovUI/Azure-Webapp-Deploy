function Ensure-Azure {

    $azModuleVersion = "6.0.0";
    $azAccountsModuleVersion = "2.3.0";
    $azWebsitesModuleVersion = "2.6.0";

    Write-Output "`nLoading Az module ... "

    if (Test-Path "C:\Modules\az_$azModuleVersion\az\$azModuleVersion\az.psd1") {
        Import-AzModuleFromLocalMachine
    } else {
            # we can't check for Az module in Powershell 5.1 because of https://github.com/PowerShell/PowerShell/pull/8777
            # we will check for Az.Accounts and Az.Websites versions instead which come bundled with the desired Az module version
            $azAccountsModule = (Get-Module -Name Az.Accounts -ListAvailable -Verbose:$false | Where-Object {($_.Version -ge $azAccountsModuleVersion)})
            $azWebsitesModule = (Get-Module -Name Az.Websites -ListAvailable -Verbose:$false | Where-Object {($_.Version -ge $azWebsitesModuleVersion)})
            if ($azAccountsModule -and $azWebsitesModule) {
                Import-Module Az -Version $azModuleVersion -Verbose:$false
            } else {
                Write-Warning "Az module is not installed. If you reached this error, the prerequisites were not met please follow https://docs.uipath.com/installation-and-upgrade/docs/the-azure-app-service-installation-script#general-steps"
                Exit 1 
            }
    }

    Write-Output "`nDone loading Az module"
}

function Import-AzModuleFromLocalMachine {

    $azModuleLocationBaseDir = 'C:\Modules\az_$azModuleVersion'
    $azModuleLocation = "$azModuleLocationBaseDir\az\$azModuleVersion\az.psd1"

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

function AuthenticateToAzure(
    [switch] $azureUSGovernmentLogin
) {
    Write-Output "Connecting to Azure — a browser or device-code prompt will appear for sign-in ..."

    if ($azureUSGovernmentLogin) {
        $loginResult = Connect-AzAccount -Environment AzureUSGovernment
    } else {
        $loginResult = Connect-AzAccount
    }

    if ($loginResult) {
        Write-Output "Logged in to Azure as $($loginResult.Context.Account.Id)"
    } else {
        Write-Error "Failed to log in to Azure"
        Exit 1
    }
}

function Stop-WebApplication (
    [string] $targetSlot,
    [string] $resourceGroupName,
    [string] $appServiceName
) {
    Write-Verbose "Stopping Web Application $appServiceName"

    $stopped = Stop-AzWebAppSlot -ResourceGroupName $resourceGroupName -Name $appServiceName -Slot $targetSlot

    if ($stopped) {
        Write-Output "Stopped the application $appServiceName-$targetSlot"
    } else {
        Write-Error "Could not stop the application $appServiceName-$targetSlot, aborting."
        Exit 1
    }

    $waitTime = 30
    Write-Output "Waiting $waitTime seconds for $appServiceName-$targetSlot to shut down completely."
    Start-Sleep -Seconds $waitTime
}

function Start-WebApplication(
    [string] $targetSlot,
    [string] $resourceGroupName,
    [string] $appServiceName
) {
    Write-Verbose "Starting Web Application $appServiceName"

    $started = Start-AzWebAppSlot -ResourceGroupName $resourceGroupName -Name $appServiceName -Slot $targetSlot

    if ($started){
        Write-Output "Started the application $appServiceName-$targetSlot"
    } else {
        Write-Error "Could not start the application $appServiceName-$targetSlot, try to start it manually."
    }
}

function Set-VirtualPath(
    [string] $resourceGroupName,
    [string] $appServiceName,
    [string] $virtualPath,
    [string] $rootFolder
) {
    $props = @{
        "virtualApplications" = @(
            @{
                "virtualPath"  = "/";
                "physicalPath" = "site\wwwroot";
            },
            @{
                "virtualPath"  = $virtualPath;
                "physicalPath" = "site\wwwroot\$rootFolder";
            }
        )
    }
    Write-Verbose "Adding following virtual paths to $appServiceName`n$($props| ConvertTo-Json)"
    Write-Output "Setting web app virtual path"
    try
    {
        Set-AzResource `
            -ResourceGroupName $resourceGroupName `
            -ResourceType "Microsoft.Web/sites/config" `
            -ResourceName "$appServiceName/web" `
            -Properties $props `
            -ApiVersion "2015-08-01" `
            -Force
    }
    catch
    {
        Write-Error "Failed to Set Virtual Paths for Identity Server Web App Service!`n`nPlease make sure the virtual paths have been set by either doing it manually or by re-running the script before using identity server."
    }
}


function Download-PublishProfile(
    [string] $resourceGroupName,
    [string] $appServiceName,
    [string] $outputPath
) {
    Write-Verbose "Downloading Publish Profile for $appServiceName"
    Get-AzWebAppPublishingProfile -OutputFile $outputPath -ResourceGroupName $resourceGroupName -Name $appServiceName  | Out-Null
}

function Download-WebsiteFile([string] $websiteFilePath, [string] $outputPath, $publishProfile) {
    $fileUrl = if ($websiteFilePath.StartsWith("/")) {
        $publishProfile.FtpPublishUrl + $websiteFilePath
    } else {
        $publishProfile.FtpPublishUrl + "/" + $websiteFilePath
    }
    Download-File -url $fileUrl -userName $publishProfile.FtpUsername -password $publishProfile.FtpPassword -outputPath $outputPath
}

function Upload-WebsiteFile([string] $websiteFilePath, [string] $localFilePath, $publishProfile) {

    $fileUrl = if ($websiteFilePath.StartsWith("/")) {
        $publishProfile.FtpPublishUrl + $websiteFilePath
    } else {
        $publishProfile.FtpPublishUrl + "/" + $websiteFilePath
    }
        
    Upload-File -url $fileUrl -file $localFilePath -userName $publishProfile.FtpUsername -password $publishProfile.FtpPassword 
}

function Download-File([string] $url, [string] $userName, [string] $password, [string] $outputPath) {
    Write-Verbose "`nDownloading file from URL $url to $outputPath"

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
        $fileUri = New-Object System.Uri($url)
        $webClient = New-Object System.Net.WebClient
        $webClient.Credentials = New-Object System.Net.NetworkCredential($userName.Normalize(), $password.Normalize())
        $webClient.DownloadFile($fileUri, $outputPath)
    }
}

function Upload-File([string] $url, [string] $file, [string] $userName, [string] $password) {
    Write-Verbose "`nUploading file from $file to $url"

    $isFtps = $url -match '^ftps://'
    if ($isFtps -or $url -match '^ftp://') {
        # FtpWebRequest does not natively accept the ftps:// scheme;
        # substitute ftp:// and enable SSL for FTPS connections.
        $normalizedUrl = if ($isFtps) { $url -replace '^ftps://', 'ftp://' } else { $url }
        $uri = New-Object System.Uri($normalizedUrl)
        $ftpRequest = [System.Net.FtpWebRequest][System.Net.WebRequest]::Create($uri)
        $ftpRequest.Method = [System.Net.WebRequestMethods+Ftp]::UploadFile
        $ftpRequest.Credentials = New-Object System.Net.NetworkCredential($userName.Normalize(), $password.Normalize())
        $ftpRequest.EnableSsl = $isFtps
        $fileBytes = [System.IO.File]::ReadAllBytes($file)
        $ftpRequest.ContentLength = $fileBytes.Length
        $requestStream = $ftpRequest.GetRequestStream()
        $requestStream.Write($fileBytes, 0, $fileBytes.Length)
        $requestStream.Close()
        $response = $ftpRequest.GetResponse()
        $response.Close()
    } else {
        $fileUri = New-Object System.Uri($url)
        $webClient = New-Object System.Net.WebClient
        $webClient.Credentials = New-Object System.Net.NetworkCredential($userName.Normalize(), $password.Normalize())
        $webClient.UploadFile($fileUri, $file)
    }
}

function Update-WebSiteSettings(
    $siteDetails, # @{ appServiceName, resourceGroupName }
    $newSettings
) {
    $appService = Get-AzWebApp -Name $siteDetails.appServiceName -ResourceGroupName $siteDetails.resourceGroupName

    $appSettings = $appService.SiteConfig.AppSettings

    # setup the current app settings
    $settings = @{}
    ForEach ($setting in $appSettings) {
        $settings[$setting.Name] = $setting.Value
    }

    # adding new settings to the app settings
    ForEach ($it in $newSettings.Keys) {
        $value = $newSettings[$it]
        $settings[$it] = $value
        Write-Verbose "Updating $it to $value";
    }

    Write-Output "Updating azure website with new settings";

    # update will just replace all settings (does NOT do Upsert)
    $app = Set-AzWebApp -AppSettings $settings -Name $siteDetails.appServiceName -ResourceGroupName $siteDetails.resourceGroupName

    Write-Output "Successfully updated azure website";
}

function Copy-NewWebSiteSettings
(
    $sourceSiteDetails, # @{ appServiceName, resourceGroupName }
    $targetSiteDetails, # @{ appServiceName, resourceGroupName }
    $settingsMap # @{source_name, target_name}
) {
    $sourceAppService = Get-AzWebApp -Name $sourceSiteDetails.appServiceName -ResourceGroupName $sourceSiteDetails.resourceGroupName
    $sourceSettings = $sourceAppService.SiteConfig.AppSettings

    $destinationSettings = @{}
    ForEach ($source in $sourceSettings)
    {
        $sourceKey = $source.Name
        $destinationKey =  $settingsMap.$sourceKey
        if ($null -ne $destinationKey)
        {
            $destinationSettings.$destinationKey = $source.Value
            Write-Output "Copied $sourceKey value to $destinationKey value"
        }
    }

    Update-WebSiteSettings -siteDetails $targetSiteDetails -newSettings $destinationSettings
}

function Copy-NewWebSiteSettingsFromXmlFile
(
    $sourceXmlFilePath,
    $targetSiteDetails, # @{ appServiceName, resourceGroupName }
    $sourceSettingName,
    $targetSettingName
) {
    $sourceSettingValue = Get-WebConfigSettingValue $sourceSettingName $sourceXmlFilePath
    if ($null -eq $sourceSettingValue)
    {
        Write-Output "Cannot find value for setting $sourceSettingName in file $sourceXmlFilePath"
    }
    else
    {
        $destinationSettings = @{}
        $destinationSettings.$targetSettingName = $sourceSettingValue
        Write-Output "Copied $sourceSettingName value to $targetSettingName value"
        Update-WebSiteSettings -siteDetails $targetSiteDetails -newSettings $destinationSettings
    }
}

function Get-WebConfigSettingValue(
    $settingName, 
    $xmlConfigPath
) {
    $settingValue = $null
    $webConfigXml = New-Object System.Xml.XmlDocument

    $webConfigXml.Load($xmlConfigPath)
    $settingNode = Select-Xml -Path $xmlConfigPath -XPath "//configuration/secureAppSettings/add[@key='$settingName']" | Select-Object -ExpandProperty Node -First 1

    if($settingNode) {
        $settingValue = $settingNode.value
    }

    return $settingValue
}

function Set-CORS-Policy(
    $siteDetails, # @{ appServiceName, resourceGroupName }
    [string[]] $allowedCors
) {
    $props = @{
        "cors" = @{
            allowedOrigins = $allowedCors
        }
    }

    Write-Verbose "Adding following CORS to $($siteDetails.appServiceName)`n$($allowedCors| ConvertTo-Json)"
    Write-Output "Setting web app allowed CORS"
    try
    {
        Set-AzResource `
            -ResourceGroupName $siteDetails.resourceGroupName `
            -ResourceType "Microsoft.Web/sites/config" `
            -ResourceName "$($siteDetails.appServiceName)/web" `
            -Properties $props `
            -ApiVersion "2015-08-01" `
            -Force
    }
    catch
    {
        Write-Error "Failed to set the allowed CORS"
    }
}
