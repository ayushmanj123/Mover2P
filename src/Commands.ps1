# The four commands. Each returns an exit code: 0 for success, 1 when a check
# or validation fails. Unexpected problems throw.

function Get-MoverPackagePaths {
    param([Parameter(Mandatory = $true)]$Config)
    $root = $Config.PackageDir
    return [pscustomobject]@{
        Root      = $root
        Manifest  = Join-Path $root 'manifest.json'
        Solutions = Join-Path $root 'solutions'
        Site      = Join-Path $root 'site'
        Data      = Join-Path $root 'data'
        DataFile  = Join-Path (Join-Path $root 'data') 'data.zip'
        Logs      = Join-Path $root 'logs'
        Report    = Join-Path $root 'validation-report.json'
    }
}

function Start-MoverRun {
    param($Paths, [string]$Command)
    $logFile = Join-Path $Paths.Logs ('{0}-{1}.log' -f $Command, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Set-MoverLogFile -Path $logFile
    Write-MoverLog "Mover2P $Command. Log: $logFile"
}

function Write-MoverJsonFile {
    param([string]$Path, $Object)
    $json = $Object | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-MoverManifest {
    param([Parameter(Mandatory = $true)]$Config)
    $paths = Get-MoverPackagePaths $Config
    if (-not (Test-Path -LiteralPath $paths.Manifest -PathType Leaf)) {
        throw "No package found at $($paths.Root). Run 'export' first, or copy the exported package folder there."
    }
    $manifest = Get-Content -LiteralPath $paths.Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.tool -ne 'Mover2P') {
        throw "$($paths.Manifest) is not a Mover2P manifest."
    }
    if ("$($manifest.websiteId)" -ine $Config.WebsiteId) {
        throw "The package is for website $($manifest.websiteId), but the config names $($Config.WebsiteId)."
    }
    return $manifest
}

function Find-MoverSiteFolder {
    # pac downloads into a child folder named after the site; the folder that
    # holds website.yml is the one 'pac pages upload' needs.
    param([Parameter(Mandatory = $true)][string]$Root)
    $found = @()
    if (Test-Path -LiteralPath $Root -PathType Container) {
        $found = @(Get-ChildItem -LiteralPath $Root -Filter 'website.yml' -File -Recurse -Depth 2)
    }
    if ($found.Count -eq 0) {
        throw "No website.yml found under $Root. The site download did not produce a site folder."
    }
    if ($found.Count -gt 1) {
        throw "More than one site folder found under ${Root}: $(($found | ForEach-Object { $_.DirectoryName }) -join ', ')."
    }
    return $found[0].DirectoryName
}

function Reset-MoverDirectory {
    # Empties a folder that belongs to the package. Refuses anything outside it.
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$PackageRoot)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($PackageRoot).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clear $fullPath because it is outside the package folder $fullRoot."
    }
    if (Test-Path -LiteralPath $fullPath) {
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
}

function Get-MoverRelativePath {
    param([string]$Root, [string]$Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($fullRoot.Length)
    }
    return $fullPath
}

function Write-MoverFindings {
    param($Findings)
    foreach ($finding in @($Findings)) {
        if ($finding) { Write-MoverLog "$($finding.Check): $($finding.Message)" -Level $finding.Level }
    }
}

function Invoke-MoverExport {
    param([Parameter(Mandatory = $true)]$Config, [switch]$DryRun)
    $paths = Get-MoverPackagePaths $Config
    Start-MoverRun -Paths $paths -Command 'export'
    $source = $Config.Source

    if ($Config.DataSchemaFile -and -not (Test-Path -LiteralPath $Config.DataSchemaFile -PathType Leaf)) {
        throw "Schema file not found: $($Config.DataSchemaFile)"
    }
    Test-MoverPacAvailable

    Write-MoverLog "Reading source environment $($source.Url)"
    $facts = Get-MoverEnvironmentFacts -Environment $source -WebsiteId $Config.WebsiteId -CountTables $Config.CountTables -IncludeCounts
    if (-not $facts.portalTablesInstalled) {
        throw "The source has no standard data model tables (adx_website). This tool only moves standard data model sites."
    }
    $site = @($facts.websites) | Where-Object { $_.id -ieq $Config.WebsiteId } | Select-Object -First 1
    if (-not $site) {
        $known = (@($facts.websites) | ForEach-Object { "'$($_.name)' ($($_.id))" }) -join ', '
        if (-not $known) { $known = 'none' }
        throw "Website $($Config.WebsiteId) is not a standard data model site in the source. Sites found: $known."
    }
    Write-MoverLog "Found standard data model site '$($site.name)'." -Level OK

    if ($DryRun) {
        Write-MoverLog '[dry-run] Skipping pac sign-in; the commands below are not run.'
    }
    else {
        Connect-MoverPac -Environment $source -Side source
        New-Item -ItemType Directory -Path $paths.Solutions -Force | Out-Null
    }

    $solutionArtifacts = @(
        foreach ($solution in @($Config.Solutions)) {
            if (-not $solution) { continue }
            $suffix = if ($solution.Managed) { '_managed' } else { '' }
            $zip = Join-Path $paths.Solutions "$($solution.Name)$suffix.zip"
            Invoke-MoverPac (Get-MoverSolutionExportArguments -Solution $solution -ZipPath $zip -Url $source.Url) -DryRun:$DryRun | Out-Null
            if (-not $DryRun -and -not (Test-Path -LiteralPath $zip -PathType Leaf)) {
                throw "pac reported success but $zip was not created."
            }
            [pscustomobject]@{ name = $solution.Name; managed = [bool]$solution.Managed; file = (Get-MoverRelativePath -Root $paths.Root -Path $zip) }
        }
    )

    if (-not $DryRun) { Reset-MoverDirectory -Path $paths.Site -PackageRoot $paths.Root }
    Invoke-MoverPac (Get-MoverSiteDownloadArguments -Path $paths.Site -WebsiteId $Config.WebsiteId -Url $source.Url) -DryRun:$DryRun | Out-Null

    $dataFile = $null
    if ($Config.DataSchemaFile) {
        if (-not $DryRun) { New-Item -ItemType Directory -Path $paths.Data -Force | Out-Null }
        Invoke-MoverPac (Get-MoverDataExportArguments -SchemaFile $Config.DataSchemaFile -DataFile $paths.DataFile -Url $source.Url) -DryRun:$DryRun | Out-Null
        $dataFile = Get-MoverRelativePath -Root $paths.Root -Path $paths.DataFile
    }

    if ($DryRun) {
        Write-MoverLog '[dry-run] No package was written.'
        return 0
    }

    $siteFolder = Find-MoverSiteFolder -Root $paths.Site
    $manifest = [ordered]@{
        tool            = 'Mover2P'
        manifestVersion = 1
        name            = $Config.Name
        createdAt       = (Get-Date).ToUniversalTime().ToString('o')
        websiteId       = $Config.WebsiteId
        websiteName     = $site.name
        source          = $facts
        artifacts       = [ordered]@{
            solutions  = $solutionArtifacts
            siteFolder = (Get-MoverRelativePath -Root $paths.Root -Path $siteFolder)
            dataFile   = $dataFile
        }
    }
    Write-MoverJsonFile -Path $paths.Manifest -Object $manifest

    foreach ($note in (ConvertTo-MoverMap $facts.countNotes).GetEnumerator()) {
        Write-MoverLog "Not counted in source: $($note.Key) ($($note.Value))" -Level WARN
    }
    Write-MoverLog "Package written to $($paths.Root)" -Level OK
    Write-MoverLog "Next: copy the package folder to where Tenant B is reachable, then run 'check' and 'import'."
    return 0
}

function Invoke-MoverCheck {
    param([Parameter(Mandatory = $true)]$Config, [switch]$Nested)
    $paths = Get-MoverPackagePaths $Config
    if (-not $Nested) { Start-MoverRun -Paths $paths -Command 'check' }
    $manifest = Read-MoverManifest -Config $Config

    Write-MoverLog "Checking target environment $($Config.Target.Url) against the package"
    $targetFacts = Get-MoverEnvironmentFacts -Environment $Config.Target -WebsiteId $manifest.websiteId
    $findings = @(Compare-MoverEnvironment -Source $manifest.source -Target $targetFacts -WebsiteId $manifest.websiteId -PortalSolutionPattern $Config.PortalSolutionPattern)
    Write-MoverFindings $findings

    Write-MoverLog "Not checked by this tool: confirm 'Switch to enhanced data model' is off for the target environment, and that its site was provisioned from the same template as the source." -Level WARN

    $errors = @($findings | Where-Object { $_.Level -eq 'ERROR' })
    if ($errors.Count -gt 0) {
        Write-MoverLog "Check failed with $($errors.Count) blocking problem(s)." -Level ERROR
        return 1
    }
    Write-MoverLog 'Check passed.' -Level OK
    return 0
}

function Invoke-MoverImport {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [switch]$DryRun,
        [switch]$Yes,
        [string[]]$Steps = @('solutions', 'site', 'data')
    )
    $paths = Get-MoverPackagePaths $Config
    Start-MoverRun -Paths $paths -Command 'import'
    $target = $Config.Target
    $manifest = Read-MoverManifest -Config $Config
    Test-MoverPacAvailable

    # Resolve every artifact before touching the target.
    $solutionFiles = @(
        foreach ($artifact in @($manifest.artifacts.solutions)) {
            if (-not $artifact) { continue }
            $zip = Join-Path $paths.Root $artifact.file
            if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw "Solution file missing from the package: $zip" }
            [pscustomobject]@{ Name = $artifact.name; Managed = [bool]$artifact.managed; Path = $zip }
        }
    )
    $siteFolder = Join-Path $paths.Root $manifest.artifacts.siteFolder
    if (-not (Test-Path -LiteralPath (Join-Path $siteFolder 'website.yml') -PathType Leaf)) {
        throw "Site folder missing from the package: $siteFolder"
    }
    $dataFile = $null
    if ($manifest.artifacts.dataFile) {
        $dataFile = Join-Path $paths.Root $manifest.artifacts.dataFile
        if (-not (Test-Path -LiteralPath $dataFile -PathType Leaf)) { throw "Data file missing from the package: $dataFile" }
    }
    $profileName = $null
    if ($Config.DeploymentProfileFile) {
        if (-not (Test-Path -LiteralPath $Config.DeploymentProfileFile -PathType Leaf)) {
            throw "Deployment profile not found: $($Config.DeploymentProfileFile)"
        }
        $profileName = (Split-Path -Leaf $Config.DeploymentProfileFile) -replace '\.deployment\.yml$', ''
    }

    if ((Invoke-MoverCheck -Config $Config -Nested) -ne 0) {
        throw 'Import stopped because the pre-flight check failed.'
    }

    if ($DryRun) {
        Write-MoverLog '[dry-run] Skipping pac sign-in; the commands below are not run.'
    }
    else {
        if (-not $Yes) {
            Write-Host ''
            Write-Host "About to import '$($manifest.websiteName)' into $($target.Url) (steps: $($Steps -join ', '))." -ForegroundColor Yellow
            $answer = Read-Host "Type the target host name ($($target.Host)) to continue"
            if ($answer -ne $target.Host) { throw 'Import cancelled: the confirmation did not match.' }
        }
        Connect-MoverPac -Environment $target -Side target
    }

    if ($Steps -contains 'solutions') {
        foreach ($solution in $solutionFiles) {
            Write-MoverLog "Importing solution $($solution.Name)"
            Invoke-MoverPac (Get-MoverSolutionImportArguments -ZipPath $solution.Path -Managed $solution.Managed -Url $target.Url) -DryRun:$DryRun | Out-Null
        }
    }

    if ($Steps -contains 'site') {
        if ($profileName -and -not $DryRun) {
            $profileFolder = Join-Path $siteFolder 'deployment-profiles'
            New-Item -ItemType Directory -Path $profileFolder -Force | Out-Null
            Copy-Item -LiteralPath $Config.DeploymentProfileFile -Destination $profileFolder -Force
        }
        Write-MoverLog 'Uploading site configuration'
        Invoke-MoverPac (Get-MoverSiteUploadArguments -Path $siteFolder -DeploymentProfile $profileName -Url $target.Url) -DryRun:$DryRun | Out-Null
    }

    if ($Steps -contains 'data' -and $dataFile) {
        Write-MoverLog 'Importing gap-table data'
        Invoke-MoverPac (Get-MoverDataImportArguments -DataFile $dataFile -Url $target.Url) -DryRun:$DryRun | Out-Null
    }

    if ($DryRun) {
        Write-MoverLog '[dry-run] Nothing was changed in the target.'
        return 0
    }
    Write-MoverLog 'Import finished.' -Level OK
    Write-MoverLog 'Next steps, done by hand:'
    Write-MoverLog '  1. Power Pages home > Inactive sites > Reactivate the site.'
    Write-MoverLog '  2. Convert the site to production and set up the custom domain and certificate.'
    Write-MoverLog '  3. Review site settings for values that still point at the source environment.'
    Write-MoverLog "  4. Run 'validate' to compare record counts with the source."
    return 0
}

function Invoke-MoverValidate {
    param([Parameter(Mandatory = $true)]$Config)
    $paths = Get-MoverPackagePaths $Config
    Start-MoverRun -Paths $paths -Command 'validate'
    $manifest = Read-MoverManifest -Config $Config

    Write-MoverLog "Counting site records in $($Config.Target.Url)"
    $targetFacts = Get-MoverEnvironmentFacts -Environment $Config.Target -WebsiteId $manifest.websiteId -CountTables $Config.CountTables -IncludeCounts
    if (-not $targetFacts.portalTablesInstalled) {
        throw 'The target has no standard data model tables, so there is nothing to validate.'
    }

    $rows = @(Compare-MoverCounts -SourceCounts $manifest.source.counts -TargetCounts $targetFacts.counts `
            -SourceNotes $manifest.source.countNotes -TargetNotes $targetFacts.countNotes)

    foreach ($row in $rows) {
        $line = '{0,-34} source {1,6}  target {2,6}  {3}' -f $row.Table, "$($row.Source)", "$($row.Target)", $row.Status
        if ($row.Note) { $line += " ($($row.Note))" }
        $level = switch ($row.Status) { 'Match' { 'OK' } 'Mismatch' { 'ERROR' } default { 'WARN' } }
        Write-MoverLog $line -Level $level
    }

    $mismatches = @($rows | Where-Object { $_.Status -eq 'Mismatch' })
    $notCounted = @($rows | Where-Object { $_.Status -eq 'NotCounted' })
    Write-MoverJsonFile -Path $paths.Report -Object ([ordered]@{
            name             = $Config.Name
            websiteId        = $manifest.websiteId
            sourceCapturedAt = $manifest.source.capturedAt
            targetCapturedAt = $targetFacts.capturedAt
            passed           = ($mismatches.Count -eq 0)
            rows             = $rows
        })
    Write-MoverLog "Report written to $($paths.Report)"

    if ($notCounted.Count -gt 0) {
        Write-MoverLog "$($notCounted.Count) table(s) could not be compared; check them by hand." -Level WARN
    }
    if ($mismatches.Count -gt 0) {
        Write-MoverLog "$($mismatches.Count) table(s) have different record counts." -Level ERROR
        return 1
    }
    Write-MoverLog 'Record counts match for every table that could be compared.' -Level OK
    return 0
}
