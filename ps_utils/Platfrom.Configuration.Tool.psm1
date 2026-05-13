$script:signinsystemopenidconnect = $null

function Update-UiPathUrl {
	Param(
		[Parameter(Mandatory = $true)] [string] $siteName,
		[Parameter(Mandatory = $true)] [string] $orchestratorUri,
		[Parameter(Mandatory = $false)] [string] $identityServerUrl,
		[Parameter(Mandatory = $false)] [string] $sqlConnectionString
	)

	if (-not $identityServerUrl) {
		$identityServerUrl = -join ($orchestratorUri, "/identity")
		$identitySite = Get-Item IIS:\Sites\$siteName\Identity
		$identityPath = $identitySite.PhysicalPath
	} else {
		$identity = $identityServerUrl -split $orchestratorUri | Select-Object -last 1
		$identitySite = Get-Item IIS:\Sites\$identity
		$identityPath = $identitySite.PhysicalPath		
	}
	
	$orchestratorSite = Get-Item IIS:\Sites\$siteName
	$orchestratorPath = $orchestratorSite.PhysicalPath
	$orchestratorconfigFilePath = Join-Path $orchestratorPath "UiPath.Orchestrator.dll.config"

	Write-Host "`nUpdating Orchestrator Settings" -ForegroundColor Yellow
	
	$orchestratorWebConfig = [xml](Get-Content $orchestratorconfigFilePath)	
	ForEach ($add in $orchestratorWebConfig.configuration.appSettings.add) {		
		Switch ($add.key) {
		 "IdentityServer.Integration.Authority" { $add.value = $identityServerUrl }
		 "ExternalAuth.System.OpenIdConnect.Authority" { $add.value = $identityServerUrl }
		 "ExternalAuth.System.OpenIdConnect.PostLogoutRedirectUri" { $add.value = $orchestratorUri }
		 "ExternalAuth.System.OpenIdConnect.RedirectUri" { 
			 $script:signinsystemopenidconnect = $add.value 
			 $add.value = -join ($orchestratorUri, "/signinsystemopenidconnect")
		 }
		}
	}	
	$orchestratorWebConfig.Save($orchestratorconfigFilePath)
	
	Write-Host "`nOrchestrator setting got updated" -ForegroundColor Green
	
	Write-Host "`nUpdating IdentityServer AppSettings" -ForegroundColor Yellow

	$identityProductionConfigPath = -join ($identityPath, "\appsettings.Production.json")
	$identityProductionJson = Get-Content $identityProductionConfigPath	| ConvertFrom-Json
	$identityProductionJson.AppSettings.IdentityServerAddress = $identityServerUrl
	$identityProductionJson.AppSettings.OrchestratorUrl = $orchestratorUri
	$identityProductionJson | ConvertTo-Json -Depth 5 | set-content $identityProductionConfigPath
	
	Write-Host "`nIdentityServer setting got updated" -ForegroundColor Green
	
	Write-Host "`nUpdating ClientRedirectUris in the SqlDB" -ForegroundColor Yellow	
	
	if (-not $sqlConnectionString) {
		$sqlConnectionString = $orchestratorWebConfig.configuration.connectionStrings.add | Where-Object { $_.name -eq 'Default' } | Select-Object -ExpandProperty 'connectionString'
	}	
	$clientRedirectUri = -join ($orchestratorUri, "/signinsystemopenidconnect")
	
	$identityDataBaseSql = "
	UPDATE [identity].[ClientRedirectUris] SET [RedirectUri] = '$clientRedirectUri' WHERE [RedirectUri] = '$script:signinsystemopenidconnect'
	"

	Invoke-Sqlcmd -ConnectionString $sqlConnectionString -Query $identityDataBaseSql
	
	Write-Host "`nClientRedirectUris got updated" -ForegroundColor Green
	
	Write-Host "`nRestart the Orchestrator Services by iisreset" -ForegroundColor Yellow
	
	invoke-command -scriptblock { iisreset }
}

function Update-UiPathCertificate {
	Param(
		[Parameter(Mandatory = $true)] [string] $siteName,
		[Parameter(Mandatory = $false)] [string] $newTokenSigningThumbprint,
		[Parameter(Mandatory = $false)] [string] $newSSLThumbprint,
		[Parameter(Mandatory = $false)] [string] $orchestratorUri
	)
	
	$identitySite = Get-Item IIS:\Sites\$siteName\Identity
	$identityPath = $identitySite.PhysicalPath
	$identityProductionConfigPath = -join ($identityPath, "\appsettings.Production.json")
	$identityProductionJson = Get-Content $identityProductionConfigPath	| ConvertFrom-Json
	
	if(-not $orchestratorUri){
		[URI]$orchestratorUri = $identityProductionJson.AppSettings.OrchestratorUrl
	}	
	
	if ($newTokenSigningThumbprint) {
		Write-Host "`nUpdating Certificate Details in IdentityServer App Settings" -ForegroundColor Yellow

		$identityProductionJson.AppSettings.SigningCredentialSettings.StoreLocation.Name = $newTokenSigningThumbprint
		$identityProductionJson | ConvertTo-Json -Depth 5 | set-content $identityProductionConfigPath

		Restart-WebAppPool $identitySite.applicationPool

		Write-Host "`nIdentityServer App Setting got updated" -ForegroundColor Green
	}
		
	if($newSSLThumbprint){
		Write-Host "`nUpdating IIS binding with new SSL Certificate" -ForegroundColor Yellow

		$binding = (Get-ChildItem -Path IIS:\SSLBindings | Where-Object Sites -eq $siteName)[0]
		$newSSLThumbprintPath = "cert:\LocalMachine\$($binding.Store)\$($newSSLThumbprint)"		
		Remove-Item -path IIS:\SslBindings\$($binding.IPAddress.IPAddressToString)!$($binding.Port)
		Get-Item -Path $newSSLThumbprintPath | new-item -path IIS:\SslBindings\$($binding.IPAddress.IPAddressToString)!$($binding.Port)

		Restart-WebAppPool $siteName 

		Write-Host "`nNew SSL Certificate got updated" -ForegroundColor Green
	}
	
	Write-Host "`nRestart the Orchestrator Services by iisreset" -ForegroundColor Yellow
	
	invoke-command -scriptblock { iisreset }
}

Export-ModuleMember -Function Update-UiPathUrl
Export-ModuleMember -Function Update-UiPathCertificate