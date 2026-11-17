# Collects the facts about an environment that the pre-flight check and the
# validation report compare. Everything here is read-only.

function Get-MoverCountQuery {
    # Active records of one table that belong to the website.
    param([string]$Table, [string]$PrimaryId, [string]$WebsiteId)
    return "<fetch aggregate='true'><entity name='$Table'>" +
    "<attribute name='$PrimaryId' alias='cnt' aggregate='count'/>" +
    "<filter><condition attribute='adx_websiteid' operator='eq' value='$WebsiteId'/>" +
    "<condition attribute='statecode' operator='eq' value='0'/></filter>" +
    "</entity></fetch>"
}

function Get-MoverFileContentQuery {
    # Web files of the website that have a note with a file attached. This is
    # the number that drops when the target's attachment size limit is too low.
    param([string]$WebsiteId)
    return "<fetch aggregate='true'><entity name='annotation'>" +
    "<attribute name='objectid' alias='cnt' aggregate='countcolumn' distinct='true'/>" +
    "<filter><condition attribute='isdocument' operator='eq' value='1'/></filter>" +
    "<link-entity name='adx_webfile' from='adx_webfileid' to='objectid' link-type='inner'>" +
    "<filter><condition attribute='adx_websiteid' operator='eq' value='$WebsiteId'/>" +
    "<condition attribute='statecode' operator='eq' value='0'/></filter>" +
    "</link-entity></entity></fetch>"
}

function Get-MoverShortError {
    param($ErrorRecord)
    $text = ("$($ErrorRecord.Exception.Message)" -split "`n")[0].Trim()
    if ($text.Length -gt 200) { $text = $text.Substring(0, 200) + '...' }
    return $text
}

function Get-MoverSiteCounts {
    # Returns counts per table plus a note for every table that could not be
    # counted. A table that fails never stops the others.
    param(
        [Parameter(Mandatory = $true)]$Environment,
        [Parameter(Mandatory = $true)][string]$WebsiteId,
        [Parameter(Mandatory = $true)][string[]]$Tables
    )
    $counts = [ordered]@{}
    $notes = [ordered]@{}

    foreach ($table in $Tables) {
        try {
            $meta = Invoke-MoverDataverse -Environment $Environment -AllowNotFound `
                -Path "EntityDefinitions(LogicalName='$table')?`$select=EntitySetName,PrimaryIdAttribute"
            if (-not $meta) {
                $notes[$table] = 'table not installed'
                continue
            }
            $lookup = Invoke-MoverDataverse -Environment $Environment -AllowNotFound `
                -Path "EntityDefinitions(LogicalName='$table')/Attributes(LogicalName='adx_websiteid')?`$select=LogicalName"
            if (-not $lookup) {
                $notes[$table] = 'no adx_websiteid column'
                continue
            }
            $fetch = Get-MoverCountQuery -Table $table -PrimaryId $meta.PrimaryIdAttribute -WebsiteId $WebsiteId
            $result = Invoke-MoverDataverse -Environment $Environment `
                -Path "$($meta.EntitySetName)?fetchXml=$([uri]::EscapeDataString($fetch))"
            $counts[$table] = [int](@($result.value)[0].cnt)
        }
        catch {
            $notes[$table] = "could not count: $(Get-MoverShortError $_)"
        }
    }

    $contentKey = 'adx_webfile (with file content)'
    try {
        $fetch = Get-MoverFileContentQuery -WebsiteId $WebsiteId
        $result = Invoke-MoverDataverse -Environment $Environment `
            -Path "annotations?fetchXml=$([uri]::EscapeDataString($fetch))"
        $counts[$contentKey] = [int](@($result.value)[0].cnt)
    }
    catch {
        $notes[$contentKey] = "could not count: $(Get-MoverShortError $_)"
    }

    return [pscustomobject]@{ Counts = $counts; Notes = $notes }
}

function Get-MoverEnvironmentFacts {
    param(
        [Parameter(Mandatory = $true)]$Environment,
        [Parameter(Mandatory = $true)][string]$WebsiteId,
        [string[]]$CountTables,
        [switch]$IncludeCounts
    )
    $organization = @((Invoke-MoverDataverse -Environment $Environment `
                -Path 'organizations?$select=organizationid,languagecode,maxuploadfilesize').value)[0]

    # null means "could not be determined", which the check reports as a warning.
    $languages = $null
    try {
        $response = Invoke-MoverDataverse -Environment $Environment -Path 'RetrieveProvisionedLanguages'
        # Piping $null would yield a single bogus 0, so only convert a real list.
        if ($null -ne $response.RetrieveProvisionedLanguages) {
            $languages = @(foreach ($lcid in $response.RetrieveProvisionedLanguages) { [int]$lcid })
        }
        else {
            Write-MoverLog 'Enabled languages were not returned by the environment.' -Level WARN
        }
    }
    catch {
        Write-MoverLog "Could not read enabled languages: $(Get-MoverShortError $_)" -Level WARN
    }

    $tableMeta = Invoke-MoverDataverse -Environment $Environment -AllowNotFound `
        -Path "EntityDefinitions(LogicalName='adx_website')?`$select=EntitySetName"
    $portalTablesInstalled = [bool]$tableMeta

    $websites = @()
    if ($portalTablesInstalled) {
        $websites = @(
            foreach ($row in @(Get-MoverDataverseAll -Environment $Environment -Path 'adx_websites?$select=adx_websiteid,adx_name')) {
                if ($row) { [pscustomobject]@{ id = "$($row.adx_websiteid)".ToLowerInvariant(); name = "$($row.adx_name)" } }
            }
        )
    }

    $solutions = @(
        foreach ($row in @(Get-MoverDataverseAll -Environment $Environment -Path 'solutions?$select=uniquename,version,ismanaged')) {
            if ($row) { [pscustomobject]@{ uniqueName = "$($row.uniquename)"; version = "$($row.version)"; isManaged = [bool]$row.ismanaged } }
        }
    )

    $counts = $null
    $countNotes = $null
    if ($IncludeCounts -and $portalTablesInstalled) {
        $siteCounts = Get-MoverSiteCounts -Environment $Environment -WebsiteId $WebsiteId -Tables $CountTables
        $counts = $siteCounts.Counts
        $countNotes = $siteCounts.Notes
    }

    return [pscustomobject]@{
        url                   = $Environment.Url
        capturedAt            = (Get-Date).ToUniversalTime().ToString('o')
        organizationId        = "$($organization.organizationid)"
        baseLanguage          = [int]$organization.languagecode
        provisionedLanguages  = $languages
        maxUploadFileSize     = [int]$organization.maxuploadfilesize
        portalTablesInstalled = $portalTablesInstalled
        websites              = $websites
        solutions             = $solutions
        counts                = $counts
        countNotes            = $countNotes
    }
}
