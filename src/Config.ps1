# Config loading and validation. Test-MoverConfig is pure so it can be unit tested;
# Read-MoverConfig adds file access, defaults and path resolution.

$script:MoverGuidPattern = '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'

# Microsoft's shared app registration for Dataverse samples. Used only for
# interactive sign-in to read environment facts; override with auth.clientId.
$script:MoverSampleClientId = '51f81489-12ee-4a9e-aaae-a2591f45987d'

$script:MoverDefaultPortalSolutionPattern = '(?i)portal|powerpages'

# Site component tables that carry an adx_websiteid lookup. Tables that turn out
# not to have the column in a given environment are reported, not failed.
$script:MoverDefaultCountTables = @(
    'adx_webpage', 'adx_webfile', 'adx_webtemplate', 'adx_pagetemplate',
    'adx_contentsnippet', 'adx_sitesetting', 'adx_sitemarker', 'adx_weblinkset',
    'adx_entityform', 'adx_entitylist', 'adx_webform', 'adx_entitypermission',
    'adx_webrole', 'adx_webpageaccesscontrolrule', 'adx_websiteaccess',
    'adx_redirect', 'adx_shortcut', 'adx_publishingstate', 'adx_websitelanguage',
    'adx_columnpermissionprofile'
)

function Get-MoverProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Test-MoverEnvironmentConfig {
    param($Section, [string]$Side)
    $errors = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Section) {
        $errors.Add("'$Side' section is missing.")
        return $errors.ToArray()
    }

    $url = Get-MoverProp $Section 'url'
    if ("$url" -notmatch '^https://[A-Za-z0-9.-]+/?$') {
        $errors.Add("'$Side.url' must look like https://yourorg.crm.dynamics.com.")
    }
    $tenantId = Get-MoverProp $Section 'tenantId'
    if ("$tenantId" -notmatch $script:MoverGuidPattern) {
        $errors.Add("'$Side.tenantId' must be the tenant GUID.")
    }

    $auth = Get-MoverProp $Section 'auth'
    $mode = Get-MoverProp $auth 'mode'
    if (-not $mode) { $mode = 'interactive' }
    $clientId = Get-MoverProp $auth 'clientId'

    if ($mode -eq 'servicePrincipal') {
        if ("$clientId" -notmatch $script:MoverGuidPattern) {
            $errors.Add("'$Side.auth.clientId' must be the application (client) GUID.")
        }
        if (-not (Get-MoverProp $auth 'clientSecretEnvVar')) {
            $errors.Add("'$Side.auth.clientSecretEnvVar' must name the environment variable that holds the client secret.")
        }
    }
    elseif ($mode -eq 'interactive') {
        if ($clientId -and "$clientId" -notmatch $script:MoverGuidPattern) {
            $errors.Add("'$Side.auth.clientId' must be a GUID when provided.")
        }
    }
    else {
        $errors.Add("'$Side.auth.mode' must be 'interactive' or 'servicePrincipal'.")
    }
    return $errors.ToArray()
}

function Test-MoverConfig {
    param(
        [Parameter(Mandatory = $true)]$Raw,
        [string[]]$Sides = @('source', 'target')
    )
    $errors = New-Object 'System.Collections.Generic.List[string]'

    $name = Get-MoverProp $Raw 'name'
    if (-not $name -or "$name" -notmatch '^[A-Za-z0-9_-]+$') {
        $errors.Add("'name' is required and may contain only letters, digits, '-' and '_'.")
    }

    foreach ($side in $Sides) {
        foreach ($problem in @(Test-MoverEnvironmentConfig -Section (Get-MoverProp $Raw $side) -Side $side)) {
            $errors.Add($problem)
        }
    }

    $source = Get-MoverProp $Raw 'source'
    $target = Get-MoverProp $Raw 'target'
    if ($source -and $target) {
        $sourceUrl = "$(Get-MoverProp $source 'url')".TrimEnd('/')
        $targetUrl = "$(Get-MoverProp $target 'url')".TrimEnd('/')
        if ($sourceUrl -and $sourceUrl -ieq $targetUrl) {
            $errors.Add("'source.url' and 'target.url' point at the same environment.")
        }
    }

    $site = Get-MoverProp $Raw 'site'
    if ("$(Get-MoverProp $site 'websiteId')" -notmatch $script:MoverGuidPattern) {
        $errors.Add("'site.websiteId' must be the GUID of the website record (see 'pac pages list').")
    }
    $profileFile = Get-MoverProp $site 'deploymentProfileFile'
    if ($profileFile -and "$profileFile" -notmatch '\.deployment\.yml$') {
        $errors.Add("'site.deploymentProfileFile' must be named <profile>.deployment.yml.")
    }

    $seen = @{}
    foreach ($solution in @(Get-MoverProp $Raw 'solutions')) {
        if ($null -eq $solution) { continue }
        $solutionName = Get-MoverProp $solution 'name'
        if (-not $solutionName) {
            $errors.Add("Every entry in 'solutions' needs a 'name' (the solution's unique name).")
            continue
        }
        $key = "$solutionName".ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            $errors.Add("Solution '$solutionName' is listed more than once.")
        }
        $seen[$key] = $true
        $managed = Get-MoverProp $solution 'managed'
        if ($null -ne $managed -and $managed -isnot [bool]) {
            $errors.Add("'managed' for solution '$solutionName' must be true or false.")
        }
    }

    foreach ($table in @(Get-MoverProp (Get-MoverProp $Raw 'validation') 'tables')) {
        if ($null -eq $table) { continue }
        if ("$table" -notmatch '^[a-z0-9_]+$') {
            $errors.Add("'validation.tables' entry '$table' is not a table logical name.")
        }
    }
    return $errors.ToArray()
}

function Resolve-MoverPath {
    param([string]$BaseDirectory, [string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
}

function ConvertTo-MoverEnvironment {
    param($Section)
    if ($null -eq $Section) { return $null }
    $auth = Get-MoverProp $Section 'auth'
    $mode = Get-MoverProp $auth 'mode'
    if (-not $mode) { $mode = 'interactive' }
    $clientId = Get-MoverProp $auth 'clientId'
    if (-not $clientId -and $mode -eq 'interactive') { $clientId = $script:MoverSampleClientId }
    $url = "$($Section.url)".TrimEnd('/')
    return [pscustomobject]@{
        Url                = $url
        Host               = ([uri]$url).Host
        TenantId           = "$($Section.tenantId)"
        AuthMode           = "$mode"
        ClientId           = "$clientId"
        ClientSecretEnvVar = "$(Get-MoverProp $auth 'clientSecretEnvVar')"
    }
}

function Read-MoverConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Sides = @('source', 'target')
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config file not found: $Path"
    }
    $fullPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    try {
        $raw = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Config file is not valid JSON: $fullPath. $($_.Exception.Message)"
    }

    $errors = @(Test-MoverConfig -Raw $raw -Sides $Sides)
    if ($errors.Count -gt 0) {
        throw ("Config is invalid:`n - " + ($errors -join "`n - "))
    }

    $baseDirectory = Split-Path -Parent $fullPath
    $workDir = Get-MoverProp $raw 'workDir'
    if (-not $workDir) { $workDir = './work' }
    $workDir = Resolve-MoverPath -BaseDirectory $baseDirectory -Path $workDir

    $site = Get-MoverProp $raw 'site'
    $profileFile = Get-MoverProp $site 'deploymentProfileFile'
    if ($profileFile) { $profileFile = Resolve-MoverPath -BaseDirectory $baseDirectory -Path $profileFile }

    $schemaFile = Get-MoverProp (Get-MoverProp $raw 'data') 'schemaFile'
    if ($schemaFile) { $schemaFile = Resolve-MoverPath -BaseDirectory $baseDirectory -Path $schemaFile }

    $solutions = @(
        foreach ($solution in @(Get-MoverProp $raw 'solutions')) {
            if ($null -eq $solution) { continue }
            $managed = Get-MoverProp $solution 'managed'
            if ($null -eq $managed) { $managed = $true }
            [pscustomobject]@{ Name = "$($solution.name)"; Managed = [bool]$managed }
        }
    )

    $tables = @(Get-MoverProp (Get-MoverProp $raw 'validation') 'tables' | Where-Object { $_ })
    if ($tables.Count -eq 0) { $tables = $script:MoverDefaultCountTables }

    $pattern = Get-MoverProp (Get-MoverProp $raw 'check') 'portalSolutionPattern'
    if (-not $pattern) { $pattern = $script:MoverDefaultPortalSolutionPattern }

    $sourceSection = $null
    $targetSection = $null
    if ($Sides -contains 'source') { $sourceSection = Get-MoverProp $raw 'source' }
    if ($Sides -contains 'target') { $targetSection = Get-MoverProp $raw 'target' }

    return [pscustomobject]@{
        Name                  = "$($raw.name)"
        ConfigPath            = $fullPath
        WorkDir               = $workDir
        PackageDir            = Join-Path $workDir "$($raw.name)"
        Source                = ConvertTo-MoverEnvironment $sourceSection
        Target                = ConvertTo-MoverEnvironment $targetSection
        WebsiteId             = "$($site.websiteId)".ToLowerInvariant()
        DeploymentProfileFile = $profileFile
        Solutions             = $solutions
        DataSchemaFile        = $schemaFile
        CountTables           = [string[]]$tables
        PortalSolutionPattern = "$pattern"
    }
}
