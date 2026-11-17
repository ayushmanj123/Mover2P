# Written for Pester 3.4, which ships with Windows PowerShell 5.1.
# Run with: Invoke-Pester .\tests

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
Import-Module (Join-Path $repoRoot 'src\Mover2P.psm1') -Force

$websiteId = '33333333-3333-3333-3333-333333333333'

function New-RawConfig {
    return @"
{
  "name": "contoso-portal",
  "workDir": "./work",
  "source": {
    "url": "https://src.crm.dynamics.com",
    "tenantId": "00000000-0000-0000-0000-000000000001"
  },
  "target": {
    "url": "https://tgt.crm.dynamics.com/",
    "tenantId": "00000000-0000-0000-0000-000000000002",
    "auth": {
      "mode": "servicePrincipal",
      "clientId": "00000000-0000-0000-0000-000000000003",
      "clientSecretEnvVar": "M2P_TEST_SECRET"
    }
  },
  "site": { "websiteId": "$websiteId" },
  "solutions": [ { "name": "PortalSchema" } ]
}
"@ | ConvertFrom-Json
}

function New-Facts {
    param([string]$Url = 'https://src.crm.dynamics.com')
    return [pscustomobject]@{
        url                   = $Url
        capturedAt            = '2026-01-01T00:00:00Z'
        organizationId        = 'org'
        baseLanguage          = 1033
        provisionedLanguages  = @(1033)
        maxUploadFileSize     = 5242880
        portalTablesInstalled = $true
        websites              = @()
        solutions             = @(
            [pscustomobject]@{ uniqueName = 'MicrosoftPortalBase'; version = '9.3.2.1'; isManaged = $true },
            [pscustomobject]@{ uniqueName = 'Unrelated'; version = '5.0.0.0'; isManaged = $true }
        )
        counts                = $null
        countNotes            = $null
    }
}

function Get-Levels {
    param($Findings, [string]$Check)
    return @($Findings | Where-Object { $_.Check -eq $Check } | ForEach-Object { $_.Level })
}

Describe 'Test-MoverConfig' {
    It 'accepts a valid config' {
        @(Test-MoverConfig -Raw (New-RawConfig)).Count | Should Be 0
    }

    It 'rejects a tenant id that is not a GUID' {
        $raw = New-RawConfig
        $raw.source.tenantId = 'contoso.onmicrosoft.com'
        (@(Test-MoverConfig -Raw $raw) -join '|') | Should Match 'source\.tenantId'
    }

    It 'rejects the same environment as source and target' {
        $raw = New-RawConfig
        $raw.target.url = 'https://SRC.crm.dynamics.com/'
        (@(Test-MoverConfig -Raw $raw) -join '|') | Should Match 'same environment'
    }

    It 'requires a secret variable for a service principal' {
        $raw = New-RawConfig
        $raw.target.auth.clientSecretEnvVar = ''
        (@(Test-MoverConfig -Raw $raw) -join '|') | Should Match 'clientSecretEnvVar'
    }

    It 'rejects a website id that is not a GUID' {
        $raw = New-RawConfig
        $raw.site.websiteId = 'my-site'
        (@(Test-MoverConfig -Raw $raw) -join '|') | Should Match 'site\.websiteId'
    }

    It 'rejects a solution listed twice' {
        $raw = New-RawConfig
        $raw.solutions = @($raw.solutions[0], [pscustomobject]@{ name = 'portalschema' })
        (@(Test-MoverConfig -Raw $raw) -join '|') | Should Match 'more than once'
    }

    It 'only validates the side a command needs' {
        $raw = New-RawConfig
        $raw.PSObject.Properties.Remove('target')
        @(Test-MoverConfig -Raw $raw -Sides @('source')).Count | Should Be 0
        (@(Test-MoverConfig -Raw $raw -Sides @('target')) -join '|') | Should Match "'target' section is missing"
    }
}

Describe 'Read-MoverConfig' {
    $configDir = Join-Path $TestDrive 'cfg'
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    $configPath = Join-Path $configDir 'site.json'
    New-RawConfig | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8

    It 'applies defaults and resolves paths against the config file' {
        $config = Read-MoverConfig -Path $configPath
        $config.WorkDir | Should Be (Join-Path $configDir 'work')
        $config.PackageDir | Should Be (Join-Path (Join-Path $configDir 'work') 'contoso-portal')
        $config.Source.AuthMode | Should Be 'interactive'
        $config.Source.ClientId | Should Be '51f81489-12ee-4a9e-aaae-a2591f45987d'
        $config.Target.Url | Should Be 'https://tgt.crm.dynamics.com'
        $config.Target.Host | Should Be 'tgt.crm.dynamics.com'
        $config.Solutions[0].Managed | Should Be $true
        ($config.CountTables -contains 'adx_webpage') | Should Be $true
    }

    It 'loads only the requested side' {
        $config = Read-MoverConfig -Path $configPath -Sides @('source')
        $config.Target | Should BeNullOrEmpty
    }

    It 'lists every problem in one error' {
        $badPath = Join-Path $configDir 'bad.json'
        '{ "name": "has spaces", "site": {} }' | Set-Content -LiteralPath $badPath -Encoding UTF8
        $message = ''
        try { Read-MoverConfig -Path $badPath | Out-Null } catch { $message = $_.Exception.Message }
        $message | Should Match "'name' is required"
        $message | Should Match "'source' section is missing"
        $message | Should Match 'site\.websiteId'
    }

    It 'reports a missing file' {
        { Read-MoverConfig -Path (Join-Path $configDir 'nope.json') } | Should Throw 'Config file not found'
    }
}

Describe 'Get-MoverPacProfileName' {
    It 'fits the 30 character limit of pac' {
        $name = Get-MoverPacProfileName -Side target -Url 'https://a-very-long-organisation-name-for-testing.crm.dynamics.com'
        ($name.Length -le 30) | Should Be $true
    }

    It 'is stable across case and trailing slash, and differs by side' {
        $a = Get-MoverPacProfileName -Side source -Url 'https://Org.crm.dynamics.com/'
        $b = Get-MoverPacProfileName -Side source -Url 'https://org.crm.dynamics.com'
        $c = Get-MoverPacProfileName -Side target -Url 'https://org.crm.dynamics.com'
        $a | Should Be $b
        $a | Should Not Be $c
    }
}

Describe 'Invoke-MoverPac' {
    $fake = Join-Path $TestDrive 'fakepac.cmd'
    @(
        '@echo off',
        'echo ARGS: %*',
        'if "%1"=="fail" exit /b 3',
        'if "%1"=="soft" echo Error: something broke',
        'if "%1"=="stderr" echo warning text 1>&2',
        'exit /b 0'
    ) | Set-Content -LiteralPath $fake -Encoding ASCII
    Set-MoverPacCommand $fake

    It 'returns the output and keeps arguments with spaces together' {
        $output = (Invoke-MoverPac @('hello', 'two words') -Quiet) -join "`n"
        $output | Should Match 'ARGS: hello "two words"'
    }

    It 'throws on a non-zero exit code' {
        { Invoke-MoverPac @('fail') -Quiet } | Should Throw 'exit code 3'
    }

    It 'throws when pac prints an Error line but exits with 0' {
        { Invoke-MoverPac @('soft') -Quiet } | Should Throw 'something broke'
    }

    It 'does not treat stderr output as a failure' {
        $output = (Invoke-MoverPac @('stderr') -Quiet) -join "`n"
        $output | Should Match 'warning text'
    }

    It 'redacts registered secrets in errors' {
        Register-MoverSecret 'S3cr3tValue-123'
        $message = ''
        try { Invoke-MoverPac @('fail', '--clientSecret', 'S3cr3tValue-123') -Quiet | Out-Null } catch { $message = $_.Exception.Message }
        $message | Should Match '\*\*\*'
        $message | Should Not Match 'S3cr3tValue'
    }

    It 'skips changing commands in a dry run but still runs read-only ones' {
        Set-MoverPacCommand (Join-Path $TestDrive 'does-not-exist.cmd')
        Invoke-MoverPac @('solution', 'import') -DryRun | Should BeNullOrEmpty
        Set-MoverPacCommand $fake
        ((Invoke-MoverPac @('auth', 'list') -DryRun -ReadOnly -Quiet) -join "`n") | Should Match 'ARGS: auth list'
    }
}

Describe 'pac argument builders' {
    $url = 'https://tgt.crm.dynamics.com'

    It 'exports managed only when asked' {
        $managed = Get-MoverSolutionExportArguments -Solution ([pscustomobject]@{ Name = 'A'; Managed = $true }) -ZipPath 'a.zip' -Url $url
        $unmanaged = Get-MoverSolutionExportArguments -Solution ([pscustomobject]@{ Name = 'A'; Managed = $false }) -ZipPath 'a.zip' -Url $url
        ($managed -contains '--managed') | Should Be $true
        ($unmanaged -contains '--managed') | Should Be $false
        ($managed -join ' ') | Should Match '--environment https://tgt\.crm\.dynamics\.com'
    }

    It 'publishes changes only for unmanaged imports' {
        ((Get-MoverSolutionImportArguments -ZipPath 'a.zip' -Managed $true -Url $url) -contains '--publish-changes') | Should Be $false
        ((Get-MoverSolutionImportArguments -ZipPath 'a.zip' -Managed $false -Url $url) -contains '--publish-changes') | Should Be $true
    }

    It 'always uses the standard data model for the site' {
        ((Get-MoverSiteDownloadArguments -Path 'p' -WebsiteId $websiteId -Url $url) -join ' ') | Should Match "--webSiteId $websiteId --modelVersion 1"
        ((Get-MoverSiteUploadArguments -Path 'p' -DeploymentProfile '' -Url $url) -join ' ') | Should Match '--modelVersion 1'
    }

    It 'passes a deployment profile only when one is configured' {
        ((Get-MoverSiteUploadArguments -Path 'p' -DeploymentProfile '' -Url $url) -contains '--deploymentProfile') | Should Be $false
        ((Get-MoverSiteUploadArguments -Path 'p' -DeploymentProfile 'prod' -Url $url) -join ' ') | Should Match '--deploymentProfile prod'
    }

    It 'builds sign-in arguments for each auth mode' {
        $interactive = [pscustomobject]@{ Url = $url; AuthMode = 'interactive'; ClientId = 'x'; TenantId = 't'; ClientSecretEnvVar = '' }
        ((Get-MoverPacAuthArguments -Environment $interactive -ProfileName 'P') -contains '--clientSecret') | Should Be $false

        $env:M2P_TEST_SECRET = 'from-env-var'
        $principal = [pscustomobject]@{ Url = $url; AuthMode = 'servicePrincipal'; ClientId = 'app'; TenantId = 'tenant'; ClientSecretEnvVar = 'M2P_TEST_SECRET' }
        ((Get-MoverPacAuthArguments -Environment $principal -ProfileName 'P') -join ' ') | Should Match '--applicationId app --clientSecret from-env-var --tenant tenant'

        $env:M2P_TEST_SECRET = ''
        { Get-MoverPacAuthArguments -Environment $principal -ProfileName 'P' } | Should Throw 'M2P_TEST_SECRET'
    }
}

Describe 'Compare-MoverEnvironment' {
    It 'reports no errors for compatible environments' {
        $findings = @(Compare-MoverEnvironment -Source (New-Facts) -Target (New-Facts 'https://tgt.crm.dynamics.com') -WebsiteId $websiteId)
        @($findings | Where-Object { $_.Level -eq 'ERROR' }).Count | Should Be 0
        @($findings | Where-Object { $_.Level -eq 'WARN' }).Count | Should Be 0
    }

    It 'blocks on a different base language' {
        $target = New-Facts 'https://tgt.crm.dynamics.com'
        $target.baseLanguage = 1036
        Get-Levels (Compare-MoverEnvironment -Source (New-Facts) -Target $target -WebsiteId $websiteId) 'base-language' | Should Be 'ERROR'
    }

    It 'blocks on a smaller attachment size' {
        $target = New-Facts 'https://tgt.crm.dynamics.com'
        $target.maxUploadFileSize = 1048576
        Get-Levels (Compare-MoverEnvironment -Source (New-Facts) -Target $target -WebsiteId $websiteId) 'attachment-size' | Should Be 'ERROR'
    }

    It 'blocks when the standard data model tables are missing' {
        $target = New-Facts 'https://tgt.crm.dynamics.com'
        $target.portalTablesInstalled = $false
        Get-Levels (Compare-MoverEnvironment -Source (New-Facts) -Target $target -WebsiteId $websiteId) 'data-model' | Should Be 'ERROR'
    }

    It 'blocks when source and target are the same environment' {
        Get-Levels (Compare-MoverEnvironment -Source (New-Facts) -Target (New-Facts) -WebsiteId $websiteId) 'environments' | Should Be 'ERROR'
    }

    It 'warns about other website records in the target' {
        $target = New-Facts 'https://tgt.crm.dynamics.com'
        $target.websites = @([pscustomobject]@{ id = '99999999-9999-9999-9999-999999999999'; name = 'Default' })
        $findings = @(Compare-MoverEnvironment -Source (New-Facts) -Target $target -WebsiteId $websiteId)
        Get-Levels $findings 'websites' | Should Be 'WARN'
        ($findings | Where-Object { $_.Check -eq 'websites' }).Message | Should Match 'Default'
    }

    It 'warns about older portal solutions and ignores unrelated ones' {
        $target = New-Facts 'https://tgt.crm.dynamics.com'
        $target.solutions = @([pscustomobject]@{ uniqueName = 'microsoftportalbase'; version = '9.3.1.9'; isManaged = $true })
        $findings = @(Compare-MoverEnvironment -Source (New-Facts) -Target $target -WebsiteId $websiteId)
        $messages = ($findings | Where-Object { $_.Check -eq 'portal-solutions' } | ForEach-Object { $_.Message }) -join '|'
        $messages | Should Match 'older in the target: MicrosoftPortalBase'
        $messages | Should Not Match 'Unrelated'
    }

    It 'warns about languages missing in the target' {
        $source = New-Facts
        $source.provisionedLanguages = @(1033, 1036)
        $findings = @(Compare-MoverEnvironment -Source $source -Target (New-Facts 'https://tgt.crm.dynamics.com') -WebsiteId $websiteId)
        ($findings | Where-Object { $_.Check -eq 'languages' }).Message | Should Match '1036'
    }

    It 'warns when languages could not be read' {
        $target = New-Facts 'https://tgt.crm.dynamics.com'
        $target.provisionedLanguages = $null
        Get-Levels (Compare-MoverEnvironment -Source (New-Facts) -Target $target -WebsiteId $websiteId) 'languages' | Should Be 'WARN'
    }

    It 'gives the same result for facts read back from JSON' {
        $source = New-Facts | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $findings = @(Compare-MoverEnvironment -Source $source -Target (New-Facts 'https://tgt.crm.dynamics.com') -WebsiteId $websiteId)
        @($findings | Where-Object { $_.Level -ne 'OK' }).Count | Should Be 0
    }
}

Describe 'Compare-MoverCounts' {
    $source = [ordered]@{ adx_webpage = 10; adx_webfile = 4; adx_webrole = 3 }
    $target = [ordered]@{ adx_webpage = 10; adx_webfile = 2 }
    $targetNotes = [ordered]@{ adx_webrole = 'table not installed' }

    It 'classifies each table' {
        $rows = @(Compare-MoverCounts -SourceCounts $source -TargetCounts $target -TargetNotes $targetNotes)
        ($rows | Where-Object { $_.Table -eq 'adx_webpage' }).Status | Should Be 'Match'
        ($rows | Where-Object { $_.Table -eq 'adx_webfile' }).Status | Should Be 'Mismatch'
        $role = $rows | Where-Object { $_.Table -eq 'adx_webrole' }
        $role.Status | Should Be 'NotCounted'
        $role.Note | Should Match 'target: table not installed'
    }

    It 'accepts counts read back from JSON' {
        $fromJson = $source | ConvertTo-Json | ConvertFrom-Json
        $rows = @(Compare-MoverCounts -SourceCounts $fromJson -TargetCounts $source)
        @($rows | Where-Object { $_.Status -ne 'Match' }).Count | Should Be 0
        $rows.Count | Should Be 3
    }
}

Describe 'package helpers' {
    It 'finds the folder that holds website.yml' {
        $root = Join-Path $TestDrive 'find-one'
        $siteDir = Join-Path $root 'my-site'
        New-Item -ItemType Directory -Path $siteDir -Force | Out-Null
        'x' | Set-Content -LiteralPath (Join-Path $siteDir 'website.yml')
        Find-MoverSiteFolder -Root $root | Should Be $siteDir
    }

    It 'fails when there is no site folder or more than one' {
        $empty = Join-Path $TestDrive 'find-none'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        { Find-MoverSiteFolder -Root $empty } | Should Throw 'No website.yml'

        $two = Join-Path $TestDrive 'find-two'
        foreach ($name in 'a', 'b') {
            New-Item -ItemType Directory -Path (Join-Path $two $name) -Force | Out-Null
            'x' | Set-Content -LiteralPath (Join-Path (Join-Path $two $name) 'website.yml')
        }
        { Find-MoverSiteFolder -Root $two } | Should Throw 'More than one'
    }

    It 'only clears folders inside the package' {
        $package = Join-Path $TestDrive 'pkg'
        $inside = Join-Path $package 'site'
        $outside = Join-Path $TestDrive 'elsewhere'
        New-Item -ItemType Directory -Path $inside, $outside -Force | Out-Null
        'keep' | Set-Content -LiteralPath (Join-Path $outside 'file.txt')
        'old' | Set-Content -LiteralPath (Join-Path $inside 'old.txt')

        { Reset-MoverDirectory -Path $outside -PackageRoot $package } | Should Throw 'outside the package'
        Test-Path -LiteralPath (Join-Path $outside 'file.txt') | Should Be $true

        Reset-MoverDirectory -Path $inside -PackageRoot $package
        Test-Path -LiteralPath $inside | Should Be $true
        Test-Path -LiteralPath (Join-Path $inside 'old.txt') | Should Be $false
    }

    It 'redacts secrets in log text' {
        Register-MoverSecret 'hunter2-token'
        Protect-MoverText 'Bearer hunter2-token end' | Should Be 'Bearer *** end'
    }
}

Describe 'end-to-end flow with a fake pac' {
    $flowDir = Join-Path $TestDrive 'flow'
    New-Item -ItemType Directory -Path $flowDir -Force | Out-Null
    $configPath = Join-Path $flowDir 'site.json'
    New-RawConfig | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8

    $profilePath = Join-Path $flowDir 'prod.deployment.yml'
    'adx_sitesetting: []' | Set-Content -LiteralPath $profilePath -Encoding ASCII

    # A stand-in for pac that records every call and produces the files the
    # real CLI would.
    $fakeLog = Join-Path $flowDir 'pac-calls.log'
    $env:M2P_FAKE_LOG = $fakeLog
    $env:M2P_TEST_SECRET = 'flow-secret'
    $fake = Join-Path $flowDir 'fakepac.ps1'
    @'
$all = @($args)
Add-Content -LiteralPath $env:M2P_FAKE_LOG -Value ($all -join ' ')
$value = @{}
for ($i = 0; $i -lt $all.Count - 1; $i++) {
    if ("$($all[$i])".StartsWith('--')) { $value["$($all[$i])"] = $all[$i + 1] }
}
switch ("$($all[0]) $($all[1])") {
    'auth list' { 'No profiles were found on this computer.' }
    'env who' { "Org URL: $env:M2P_FAKE_URL/" }
    'solution export' { Set-Content -LiteralPath $value['--path'] -Value 'zip' }
    'pages download' {
        $dir = Join-Path $value['--path'] 'my-site'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'website.yml') -Value 'adx_name: My Site'
    }
    default { 'done' }
}
exit 0
'@ | Set-Content -LiteralPath $fake -Encoding ASCII
    Set-MoverPacCommand $fake

    Mock Get-MoverEnvironmentFacts -ModuleName Mover2P {
        $isSource = $Environment.Url -match 'src'
        $websites = @()
        if ($isSource) { $websites = @([pscustomobject]@{ id = '33333333-3333-3333-3333-333333333333'; name = 'My Site' }) }
        $counts = $null
        $notes = $null
        if ($IncludeCounts) {
            $counts = [ordered]@{ adx_webpage = 10; adx_webfile = 4 }
            $notes = [ordered]@{ adx_weblink = 'no adx_websiteid column' }
            if ($env:M2P_FAKE_DRIFT -and -not $isSource) { $counts['adx_webfile'] = 3 }
        }
        return [pscustomobject]@{
            url                   = $Environment.Url
            capturedAt            = '2026-01-01T00:00:00Z'
            organizationId        = 'org'
            baseLanguage          = 1033
            provisionedLanguages  = @(1033)
            maxUploadFileSize     = 5242880
            portalTablesInstalled = $true
            websites              = $websites
            solutions             = @([pscustomobject]@{ uniqueName = 'MicrosoftPortalBase'; version = '9.3.2.1'; isManaged = $true })
            counts                = $counts
            countNotes            = $notes
        }
    }

    $packageDir = Join-Path (Join-Path $flowDir 'work') 'contoso-portal'

    It 'exports a package with a manifest' {
        $env:M2P_FAKE_URL = 'https://src.crm.dynamics.com'
        $config = Read-MoverConfig -Path $configPath -Sides @('source')
        Invoke-MoverExport -Config $config | Should Be 0

        Test-Path -LiteralPath (Join-Path $packageDir 'solutions\PortalSchema_managed.zip') | Should Be $true
        $manifestText = Get-Content -LiteralPath (Join-Path $packageDir 'manifest.json') -Raw
        $manifest = $manifestText | ConvertFrom-Json
        $manifest.artifacts.siteFolder | Should Be 'site\my-site'
        $manifest.websiteName | Should Be 'My Site'
        @($manifest.source.websites).Count | Should Be 1
        $manifest.source.websites[0].id | Should Be $websiteId
        $manifest.source.counts.adx_webpage | Should Be 10
        # Windows PowerShell can serialise arrays as {"value":[],"Count":n}.
        $manifestText | Should Not Match '"Count"'
    }

    It 'passes the pre-flight check against a compatible target' {
        $config = Read-MoverConfig -Path $configPath -Sides @('target')
        Invoke-MoverCheck -Config $config | Should Be 0
    }

    It 'shows the import commands in a dry run without running them' {
        Clear-Content -LiteralPath $fakeLog
        $config = Read-MoverConfig -Path $configPath -Sides @('target')
        Invoke-MoverImport -Config $config -DryRun | Should Be 0
        (Get-Content -LiteralPath $fakeLog -Raw) | Should BeNullOrEmpty
    }

    It 'refuses to import when pac is connected to another environment' {
        $env:M2P_FAKE_URL = 'https://someone-else.crm.dynamics.com'
        Clear-Content -LiteralPath $fakeLog
        $config = Read-MoverConfig -Path $configPath -Sides @('target')
        { Invoke-MoverImport -Config $config -Yes } | Should Throw 'is not connected to tgt.crm.dynamics.com'
        (Get-Content -LiteralPath $fakeLog -Raw) | Should Not Match 'solution import|pages upload'
    }

    It 'imports solutions and the site, with the deployment profile' {
        $env:M2P_FAKE_URL = 'https://tgt.crm.dynamics.com'
        Clear-Content -LiteralPath $fakeLog
        $raw = New-RawConfig
        $raw.site | Add-Member -NotePropertyName deploymentProfileFile -NotePropertyValue './prod.deployment.yml'
        $raw | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8
        $config = Read-MoverConfig -Path $configPath -Sides @('target')

        Invoke-MoverImport -Config $config -Yes | Should Be 0

        $calls = Get-Content -LiteralPath $fakeLog -Raw
        $calls | Should Match 'auth create --name M2P-tgt-\w+ --environment https://tgt\.crm\.dynamics\.com --applicationId'
        $calls | Should Match 'solution import --path .*PortalSchema_managed\.zip --async --activate-plugins --environment https://tgt\.crm\.dynamics\.com'
        $calls | Should Match 'pages upload --path .*my-site --modelVersion 1 --environment https://tgt\.crm\.dynamics\.com --deploymentProfile prod'
        $calls | Should Not Match 'data import'
        Test-Path -LiteralPath (Join-Path $packageDir 'site\my-site\deployment-profiles\prod.deployment.yml') | Should Be $true
    }

    It 'can resume with a single step' {
        Clear-Content -LiteralPath $fakeLog
        $config = Read-MoverConfig -Path $configPath -Sides @('target')
        Invoke-MoverImport -Config $config -Yes -Steps @('site') | Should Be 0
        $calls = Get-Content -LiteralPath $fakeLog -Raw
        $calls | Should Match 'pages upload'
        $calls | Should Not Match 'solution import'
    }

    It 'validates matching counts and writes a report' {
        $env:M2P_FAKE_DRIFT = ''
        $config = Read-MoverConfig -Path $configPath -Sides @('target')
        Invoke-MoverValidate -Config $config | Should Be 0
        $report = Get-Content -LiteralPath (Join-Path $packageDir 'validation-report.json') -Raw | ConvertFrom-Json
        $report.passed | Should Be $true
        (@($report.rows) | Where-Object { $_.Table -eq 'adx_weblink' }).Status | Should Be 'NotCounted'
    }

    It 'fails validation when a count differs' {
        $env:M2P_FAKE_DRIFT = '1'
        $config = Read-MoverConfig -Path $configPath -Sides @('target')
        Invoke-MoverValidate -Config $config | Should Be 1
        $env:M2P_FAKE_DRIFT = ''
    }

    It 'rejects a package made for a different website' {
        $raw = New-RawConfig
        $raw.site.websiteId = '44444444-4444-4444-4444-444444444444'
        $otherPath = Join-Path $flowDir 'other.json'
        $raw | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $otherPath -Encoding UTF8
        $config = Read-MoverConfig -Path $otherPath -Sides @('target')
        { Invoke-MoverCheck -Config $config } | Should Throw 'The package is for website'
    }

    Set-MoverPacCommand 'pac'
}

Describe 'Mover2P.ps1' {
    It 'exits with 1 and a clear message when the config is missing' {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'Mover2P.ps1') check -Config (Join-Path $TestDrive 'missing.json') 2>&1 | Out-String
        $LASTEXITCODE | Should Be 1
        $output | Should Match 'Config file not found'
    }
}
