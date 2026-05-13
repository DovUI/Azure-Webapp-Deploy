function Remove-NullValues($hashset) {
    # clone keys before enumeration
    $allKeys = $hashset.Keys.Clone()

    foreach ($h in $allKeys) {
        if ($null -eq $hashset.Item($h)) {
            $hashset.Remove($h)
        }
    }

    return $hashset
}

function Update-WebSiteSettings(
    $siteDetails, # @{ appServiceName, resourceGroupName }
    $newSettings
) {
    Write-Verbose "Getting Azure Web Application $($siteDetails.appServiceName) in $($siteDetails.resourceGroupName)"
    $appService = Get-AzWebApp -Name $siteDetails.appServiceName -ResourceGroupName $siteDetails.resourceGroupName

    Write-Verbose "Getting current App settings"
    $appSettings = $appService.SiteConfig.AppSettings

    # setup the current app settings
    $settings = @{}
    ForEach ($setting in $appSettings) {
        $settings[$setting.Name] = $setting.Value
    }

    # adding new settings to the app settigns
    Write-Verbose "Adding new app Settings"
    ForEach ($it in $newSettings.Keys) {
        $value = $newSettings[$it]
        $settings[$it] = $value
    }

    Write-Output "Updating azure website with new settings";

    # update will just replace all settings (does NOT do Upsert)
    $app = Set-AzWebApp -AppSettings $settings -Name $siteDetails.appServiceName -ResourceGroupName $siteDetails.resourceGroupName

    Write-Output "Successfully updated azure website";
}

function Read-OrchestratorSettings(
    $configJsonFilePath,
    $identityServerUrl
) {
    Write-Verbose "Reading Orchestrator Settings"
    $json = Get-Content -Raw -Path $configJsonFilePath | ConvertFrom-Json;

    $newSettings = @{
        "IdentityServer.Integration.Enabled"                         = "true";
        "IdentityServer.Integration.Authority"                       = $identityServerUrl;
        "IdentityServer.Integration.ClientId"                        = $json.OrchestratorClientsConfig.OrchestratorS2SClient.ClientId;
        "IdentityServer.Integration.ClientSecret"                    = $json.OrchestratorClientsConfig.OrchestratorS2SClient.ClientSecret;
        "IdentityServer.Integration.AccessTokenCacheBufferInSeconds" = "50";
        "IdentityServer.Integration.UserOrchestratorApiAudience"     = "OrchestratorApiUserAccess";
        "IdentityServer.Integration.S2SOrchestratorApiAudience"      = "OrchestratorApiS2sAccess";

        "ExternalAuth.System.OpenIdConnect.Enabled"                  = "true";
        "ExternalAuth.System.OpenIdConnect.Authority"                = $identityServerUrl;
        "ExternalAuth.System.OpenIdConnect.ClientId"                 = $json.OrchestratorClientsConfig.OrchestratorOpenIdClient.ClientId;
        "ExternalAuth.System.OpenIdConnect.ClientSecret"             = $json.OrchestratorClientsConfig.OrchestratorOpenIdClient.ClientSecret;
        "ExternalAuth.System.OpenIdConnect.RedirectUri"              = $json.OrchestratorClientsConfig.OrchestratorOpenIdClient.RedirectUri;
        "ExternalAuth.System.OpenIdConnect.PostLogoutRedirectUri"    = $json.OrchestratorClientsConfig.OrchestratorOpenIdClient.PostLogoutUri;

        "MultiTenancy.AllowHostToAccessTenantApi"                     = "true";
        "MultiTenancy.TenantResolvers.HttpGlobalIdHeaderEnabled"      = "true";
        "Auth.Ropc.ClientSecret"                                      = $json.OrchestratorClientsConfig.OrchestratorRopcClient.ClientSecret;
		
        "IdentityServer.S2SIntegration.Enabled"                       = "true";
        "IdentityServer.OAuth.Enabled"                                = "true";
    }

    # Idempotency
    # cli may output json with null values (if they were already inserted and secret is not available)
    $newSettings = Remove-NullValues $newSettings

    return $newSettings;
}
