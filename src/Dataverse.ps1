# Read-only Dataverse Web API client. This file only ever issues GET requests;
# anything that changes an environment goes through pac instead.

$script:MoverTokens = @{}
$script:MoverApiVersion = 'v9.2'

function Get-MoverHttpErrorBody {
    param($ErrorRecord)
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        return $ErrorRecord.ErrorDetails.Message
    }
    try {
        $response = $ErrorRecord.Exception.Response
        if ($response) {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
            return $reader.ReadToEnd()
        }
    }
    catch { }
    return $ErrorRecord.Exception.Message
}

function Get-MoverHttpStatus {
    param($ErrorRecord)
    try { return [int]$ErrorRecord.Exception.Response.StatusCode } catch { return 0 }
}

function Get-MoverDeviceCodeToken {
    param($Environment, [string]$Authority)
    $scope = "$($Environment.Url)/user_impersonation"
    try {
        $device = Invoke-RestMethod -Method Post -Uri "$Authority/devicecode" -Body @{
            client_id = $Environment.ClientId
            scope     = $scope
        }
    }
    catch {
        throw "Could not start sign-in for $($Environment.Url): $(Get-MoverHttpErrorBody $_)"
    }

    Write-Host ''
    Write-Host "Sign in for $($Environment.Url)" -ForegroundColor Cyan
    Write-Host $device.message -ForegroundColor Cyan
    Write-Host ''

    $interval = [int]$device.interval
    if ($interval -lt 1) { $interval = 5 }
    $deadline = (Get-Date).AddSeconds([int]$device.expires_in)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            return Invoke-RestMethod -Method Post -Uri "$Authority/token" -Body @{
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                client_id   = $Environment.ClientId
                device_code = $device.device_code
            }
        }
        catch {
            $body = Get-MoverHttpErrorBody $_
            $code = $null
            try { $code = ($body | ConvertFrom-Json).error } catch { }
            if ($code -eq 'authorization_pending') { continue }
            if ($code -eq 'slow_down') { $interval += 5; continue }
            throw "Sign-in failed for $($Environment.Url): $body"
        }
    }
    throw "Sign-in for $($Environment.Url) timed out."
}

function Get-MoverToken {
    param([Parameter(Mandatory = $true)]$Environment)
    $cached = $script:MoverTokens[$Environment.Url]
    if ($cached -and $cached.ExpiresOn -gt (Get-Date).AddMinutes(5)) {
        return $cached.AccessToken
    }

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    $authority = "https://login.microsoftonline.com/$($Environment.TenantId)/oauth2/v2.0"

    if ($Environment.AuthMode -eq 'servicePrincipal') {
        try {
            $response = Invoke-RestMethod -Method Post -Uri "$authority/token" -Body @{
                grant_type    = 'client_credentials'
                client_id     = $Environment.ClientId
                client_secret = (Get-MoverClientSecret $Environment)
                scope         = "$($Environment.Url)/.default"
            }
        }
        catch {
            throw "Sign-in failed for $($Environment.Url): $(Get-MoverHttpErrorBody $_)"
        }
    }
    else {
        $response = Get-MoverDeviceCodeToken -Environment $Environment -Authority $authority
    }

    Register-MoverSecret $response.access_token
    $script:MoverTokens[$Environment.Url] = @{
        AccessToken = $response.access_token
        ExpiresOn   = (Get-Date).AddSeconds([int]$response.expires_in)
    }
    return $response.access_token
}

function Invoke-MoverDataverse {
    # GET only. -Path is relative to /api/data/<version>/, or an absolute
    # @odata.nextLink that must stay on the same environment.
    param(
        [Parameter(Mandatory = $true)]$Environment,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowNotFound
    )
    if ($Path -match '^https?://') {
        if (-not $Path.StartsWith("$($Environment.Url)/", [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to send the access token to a different host: $Path"
        }
        $uri = $Path
    }
    else {
        $uri = "$($Environment.Url)/api/data/$script:MoverApiVersion/$Path"
    }

    $headers = @{
        Authorization      = "Bearer $(Get-MoverToken $Environment)"
        Accept             = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version'    = '4.0'
    }
    try {
        return Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
    }
    catch {
        $status = Get-MoverHttpStatus $_
        if ($AllowNotFound -and $status -eq 404) { return $null }
        throw "Dataverse request failed (HTTP $status): GET $uri`n$(Get-MoverHttpErrorBody $_)"
    }
}

function Get-MoverDataverseAll {
    # Follows @odata.nextLink and returns every row.
    param(
        [Parameter(Mandatory = $true)]$Environment,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $rows = New-Object System.Collections.ArrayList
    $next = $Path
    while ($next) {
        $page = Invoke-MoverDataverse -Environment $Environment -Path $next
        if ($page.value) {
            foreach ($row in $page.value) { [void]$rows.Add($row) }
        }
        $next = $page.'@odata.nextLink'
    }
    return $rows.ToArray()
}
