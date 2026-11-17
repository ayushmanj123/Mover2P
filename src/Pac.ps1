# Wrapper around the Power Platform CLI. All changes to either environment go
# through Invoke-MoverPac, so -DryRun can show exactly what would run.

$script:MoverPacCommand = 'pac'

function Set-MoverPacCommand {
    # Points the tool at a specific pac executable. The tests use this to
    # substitute a fake.
    param([Parameter(Mandatory = $true)][string]$Path)
    $script:MoverPacCommand = $Path
}

function Test-MoverPacAvailable {
    if (-not (Get-Command $script:MoverPacCommand -ErrorAction SilentlyContinue)) {
        throw "Power Platform CLI ('pac') was not found on PATH. Install it from https://aka.ms/PowerPlatformCLI."
    }
}

function Invoke-MoverPac {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string[]]$Arguments,
        [switch]$DryRun,
        # Read-only calls run even in a dry run.
        [switch]$ReadOnly,
        [switch]$Quiet
    )
    $display = 'pac ' + (($Arguments | ForEach-Object {
                if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
            }) -join ' ')
    $display = Protect-MoverText $display

    if ($DryRun -and -not $ReadOnly) {
        Write-MoverLog "[dry-run] $display"
        return
    }
    if (-not $Quiet) { Write-MoverLog "> $display" }

    # Windows PowerShell turns native stderr lines into terminating errors when
    # the preference is 'Stop', so relax it for the duration of the call.
    $ErrorActionPreference = 'Continue'
    $output = @(& $script:MoverPacCommand @Arguments 2>&1 | ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE

    if (-not $Quiet) {
        foreach ($line in $output) {
            if ($line.Trim()) { Write-MoverLog "  $line" }
        }
    }

    # pac reports some failures as an 'Error:' line with exit code 0.
    $errorLine = $output | Where-Object { $_ -match '^\s*Error:' } | Select-Object -First 1
    if ($exitCode -ne 0 -or $errorLine) {
        $detail = $errorLine
        if (-not $detail) { $detail = ($output | Where-Object { $_.Trim() } | Select-Object -Last 1) }
        throw (Protect-MoverText "pac failed (exit code $exitCode): $display`n$detail")
    }
    return $output
}

function Get-MoverPacProfileName {
    # pac limits profile names to 30 characters; a short hash of the URL keeps
    # one profile per environment without collisions between migrations.
    param(
        [Parameter(Mandatory = $true)][ValidateSet('source', 'target')][string]$Side,
        [Parameter(Mandatory = $true)][string]$Url
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Url.TrimEnd('/').ToLowerInvariant()))
    }
    finally {
        $sha.Dispose()
    }
    $hash = -join ($bytes[0..3] | ForEach-Object { $_.ToString('x2') })
    $prefix = if ($Side -eq 'source') { 'src' } else { 'tgt' }
    return "M2P-$prefix-$hash"
}

function Get-MoverClientSecret {
    param([Parameter(Mandatory = $true)]$Environment)
    $secret = [System.Environment]::GetEnvironmentVariable($Environment.ClientSecretEnvVar)
    if (-not $secret) {
        throw "Environment variable '$($Environment.ClientSecretEnvVar)' is empty. Set it to the client secret for $($Environment.Url)."
    }
    Register-MoverSecret $secret
    return $secret
}

function Get-MoverPacAuthArguments {
    param(
        [Parameter(Mandatory = $true)]$Environment,
        [Parameter(Mandatory = $true)][string]$ProfileName
    )
    $arguments = @('auth', 'create', '--name', $ProfileName, '--environment', $Environment.Url)
    if ($Environment.AuthMode -eq 'servicePrincipal') {
        $arguments += @(
            '--applicationId', $Environment.ClientId,
            '--clientSecret', (Get-MoverClientSecret $Environment),
            '--tenant', $Environment.TenantId
        )
    }
    return $arguments
}

function Connect-MoverPac {
    # Selects (or creates) the pac profile for this environment, then confirms
    # pac is really connected to it before anything else runs.
    param(
        [Parameter(Mandatory = $true)]$Environment,
        [Parameter(Mandatory = $true)][ValidateSet('source', 'target')][string]$Side
    )
    Test-MoverPacAvailable
    $profileName = Get-MoverPacProfileName -Side $Side -Url $Environment.Url
    $authList = (Invoke-MoverPac @('auth', 'list') -ReadOnly -Quiet) -join "`n"

    if ($authList -match [regex]::Escape($profileName)) {
        Invoke-MoverPac @('auth', 'select', '--name', $profileName) -ReadOnly -Quiet | Out-Null
    }
    else {
        Write-MoverLog "Creating pac profile '$profileName' for $($Environment.Url)"
        $authArguments = Get-MoverPacAuthArguments -Environment $Environment -ProfileName $profileName
        Invoke-MoverPac $authArguments -ReadOnly | Out-Null
    }

    $who = (Invoke-MoverPac @('env', 'who') -ReadOnly -Quiet) -join "`n"
    if ($who -notmatch [regex]::Escape($Environment.Host)) {
        throw "pac profile '$profileName' is not connected to $($Environment.Host). Remove it with 'pac auth delete --name $profileName' and run again."
    }
    Write-MoverLog "pac is connected to $($Environment.Host) (profile $profileName)." -Level OK
}

function Get-MoverSolutionExportArguments {
    param($Solution, [string]$ZipPath, [string]$Url)
    $arguments = @('solution', 'export', '--name', $Solution.Name, '--path', $ZipPath, '--overwrite', '--async', '--environment', $Url)
    if ($Solution.Managed) { $arguments += '--managed' }
    return $arguments
}

function Get-MoverSolutionImportArguments {
    param([string]$ZipPath, [bool]$Managed, [string]$Url)
    $arguments = @('solution', 'import', '--path', $ZipPath, '--async', '--activate-plugins', '--environment', $Url)
    if (-not $Managed) { $arguments += '--publish-changes' }
    return $arguments
}

function Get-MoverSiteDownloadArguments {
    param([string]$Path, [string]$WebsiteId, [string]$Url)
    return @('pages', 'download', '--path', $Path, '--webSiteId', $WebsiteId, '--modelVersion', '1', '--overwrite', '--environment', $Url)
}

function Get-MoverSiteUploadArguments {
    param([string]$Path, [string]$DeploymentProfile, [string]$Url)
    $arguments = @('pages', 'upload', '--path', $Path, '--modelVersion', '1', '--environment', $Url)
    if ($DeploymentProfile) { $arguments += @('--deploymentProfile', $DeploymentProfile) }
    return $arguments
}

function Get-MoverDataExportArguments {
    param([string]$SchemaFile, [string]$DataFile, [string]$Url)
    return @('data', 'export', '--schemaFile', $SchemaFile, '--dataFile', $DataFile, '--overwrite', '--environment', $Url)
}

function Get-MoverDataImportArguments {
    param([string]$DataFile, [string]$Url)
    return @('data', 'import', '--data', $DataFile, '--environment', $Url)
}
