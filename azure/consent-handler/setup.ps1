$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Domain Scanner - Azure Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# --- Prompt for inputs ---
$customerSlug = Read-Host "Enter customer slug (e.g. contoso)"
$appName = Read-Host "Enter App Registration name (press Enter to use 'domain-scanner-$customerSlug')"
if ([string]::IsNullOrWhiteSpace($appName)) {
    $appName = "domain-scanner-$customerSlug"
}
$externalApiUrl = Read-Host "Enter external API URL to receive credentials (press Enter to skip)"

Write-Host ""
Write-Host "Setting up for customer: $customerSlug" -ForegroundColor Yellow
Write-Host "App Registration name:   $appName" -ForegroundColor Yellow
if ($externalApiUrl) {
    Write-Host "Credentials will POST to: $externalApiUrl" -ForegroundColor Yellow
}
Write-Host ""

# --- Get tenant info ---
$context = Get-AzContext
$tenantId = $context.Tenant.Id
Write-Host "Tenant ID: $tenantId" -ForegroundColor Green

# --- Install and connect to Microsoft Graph ---
Write-Host "Installing Microsoft.Graph.Applications module..." -ForegroundColor Gray
Install-Module -Name Microsoft.Graph.Applications -Force -Scope CurrentUser -AllowClobber | Out-Null
Import-Module Microsoft.Graph.Applications

Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Gray
$token = (Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com' -AsSecureString).Token
Connect-MgGraph -AccessToken $token | Out-Null
Write-Host "Connected to Microsoft Graph" -ForegroundColor Green

# --- Create App Registration ---
Write-Host "Creating App Registration '$appName'..." -ForegroundColor Gray

$graphAppId     = '00000003-0000-0000-c000-000000000000'
$domainsReadAllId = '0b5d694c-a244-4bde-86e6-eb5cd07730fe'
$redirectUri    = 'https://portal.azure.com'

$app = New-MgApplication `
    -DisplayName $appName `
    -SignInAudience 'AzureADMyOrg' `
    -Web @{ RedirectUris = @($redirectUri) } `
    -RequiredResourceAccess @(@{
        ResourceAppId  = $graphAppId
        ResourceAccess = @(@{
            Id   = $domainsReadAllId
            Type = 'Role'
        })
    })

$clientId = $app.AppId
$objectId = $app.Id
Write-Host "App Registration created (clientId: $clientId)" -ForegroundColor Green

# --- Create client secret ---
Write-Host "Creating client secret..." -ForegroundColor Gray
$secret = Add-MgApplicationPassword -ApplicationId $objectId -PasswordCredential @{
    DisplayName = 'setup-script-secret'
    EndDateTime = (Get-Date).AddYears(1)
}
$clientSecret = $secret.SecretText
Write-Host "Client secret created" -ForegroundColor Green

# --- Build consent URL ---
$consentUrl = 'https://login.microsoftonline.com/' + $tenantId + '/adminconsent?client_id=' + $clientId + '&redirect_uri=' + [System.Uri]::EscapeDataString($redirectUri) + '&state=consent'

# --- POST to external API if configured ---
if (-not [string]::IsNullOrWhiteSpace($externalApiUrl)) {
    Write-Host "Posting credentials to external API..." -ForegroundColor Gray
    $body = @{
        tenantId     = $tenantId
        clientId     = $clientId
        clientSecret = $clientSecret
        customerSlug = $customerSlug
    } | ConvertTo-Json

    try {
        Invoke-RestMethod -Uri $externalApiUrl -Method Post -Body $body -ContentType 'application/json' | Out-Null
        Write-Host "Credentials posted successfully" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to POST to external API: $($_.Exception.Message)"
        Write-Host "Credentials are still available below." -ForegroundColor Yellow
    }
}

# --- Output results ---
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Setup Complete!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Tenant ID:     $tenantId"
Write-Host "Client ID:     $clientId"
Write-Host "Client Secret: $clientSecret"
Write-Host ""
Write-Host "NEXT STEP — Share this URL with a Global Administrator" -ForegroundColor Yellow
Write-Host "to grant the Domains.Read.All permission:" -ForegroundColor Yellow
Write-Host ""
Write-Host $consentUrl -ForegroundColor Cyan
Write-Host ""
