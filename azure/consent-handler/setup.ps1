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
$domainsReadAllId = 'dbb9058a-0e50-45d7-ae91-66909b5d4664'

$app = New-MgApplication `
    -DisplayName $appName `
    -SignInAudience 'AzureADMyOrg' `
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

# --- Create Service Principal (required for admin consent to work) ---
Write-Host "Creating Service Principal..." -ForegroundColor Gray
$sp = New-MgServicePrincipal -AppId $clientId
Write-Host "Service Principal created (objectId: $($sp.Id))" -ForegroundColor Green

# --- Create client secret ---
Write-Host "Creating client secret..." -ForegroundColor Gray
$secret = Add-MgApplicationPassword -ApplicationId $objectId -PasswordCredential @{
    DisplayName = 'setup-script-secret'
    EndDateTime = (Get-Date).AddYears(1)
}
$clientSecret = $secret.SecretText
Write-Host "Client secret created" -ForegroundColor Green

# --- Grant admin consent directly (script runs as Global Admin already) ---
Write-Host "Granting admin consent for Domains.Read.All..." -ForegroundColor Gray
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
New-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $sp.Id `
    -PrincipalId $sp.Id `
    -ResourceId $graphSp.Id `
    -AppRoleId $domainsReadAllId | Out-Null
Write-Host "Admin consent granted for Domains.Read.All" -ForegroundColor Green

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
Write-Host "Domains.Read.All permission has been granted." -ForegroundColor Green
Write-Host "No further admin consent steps required." -ForegroundColor Green
Write-Host ""
