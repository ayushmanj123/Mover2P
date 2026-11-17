# Pure comparison logic: no network, no file access. Inputs may be freshly
# collected facts or facts read back from manifest.json.

function New-MoverFinding {
    param([string]$Level, [string]$Check, [string]$Message)
    return [pscustomobject]@{ Level = $Level; Check = $Check; Message = $Message }
}

function ConvertTo-MoverMap {
    # Normalises a dictionary or a JSON object into a hashtable.
    param($Object)
    $map = @{}
    if ($null -eq $Object) { return $map }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { $map["$key"] = $Object[$key] }
    }
    else {
        foreach ($property in $Object.PSObject.Properties) { $map[$property.Name] = $property.Value }
    }
    return $map
}

function ConvertTo-MoverVersion {
    param([string]$Text)
    try { return [version]$Text } catch { return $null }
}

function Compare-MoverEnvironment {
    # Returns findings with Level ERROR (blocks import), WARN, or OK.
    param(
        [Parameter(Mandatory = $true)]$Source,
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string]$WebsiteId,
        [string]$PortalSolutionPattern = $script:MoverDefaultPortalSolutionPattern
    )
    $findings = New-Object System.Collections.ArrayList

    if ("$($Source.url)".TrimEnd('/') -ieq "$($Target.url)".TrimEnd('/')) {
        [void]$findings.Add((New-MoverFinding 'ERROR' 'environments' 'Source and target are the same environment.'))
    }

    if ($Target.portalTablesInstalled) {
        [void]$findings.Add((New-MoverFinding 'OK' 'data-model' 'Standard data model tables are installed in the target.'))
    }
    else {
        [void]$findings.Add((New-MoverFinding 'ERROR' 'data-model' "Standard data model tables (adx_website) are missing in the target. Turn off 'Switch to enhanced data model' for the environment, then provision a site from the same template as the source."))
    }

    if ([int]$Source.baseLanguage -eq [int]$Target.baseLanguage) {
        [void]$findings.Add((New-MoverFinding 'OK' 'base-language' "Base language matches ($($Target.baseLanguage))."))
    }
    else {
        [void]$findings.Add((New-MoverFinding 'ERROR' 'base-language' "Base language differs: source $($Source.baseLanguage), target $($Target.baseLanguage). It cannot be changed after an environment is created."))
    }

    if ($null -eq $Source.provisionedLanguages -or $null -eq $Target.provisionedLanguages) {
        [void]$findings.Add((New-MoverFinding 'WARN' 'languages' 'Enabled languages could not be read on one side; compare them manually.'))
    }
    else {
        $targetLanguages = @($Target.provisionedLanguages)
        $missing = @(@($Source.provisionedLanguages) | Where-Object { $targetLanguages -notcontains $_ })
        if ($missing.Count -gt 0) {
            [void]$findings.Add((New-MoverFinding 'WARN' 'languages' "Languages enabled in the source but not the target: $($missing -join ', '). Enable them first if the site uses them."))
        }
        else {
            [void]$findings.Add((New-MoverFinding 'OK' 'languages' 'All source languages are enabled in the target.'))
        }
    }

    if ([int]$Target.maxUploadFileSize -ge [int]$Source.maxUploadFileSize) {
        [void]$findings.Add((New-MoverFinding 'OK' 'attachment-size' "Maximum attachment size is sufficient ($($Target.maxUploadFileSize) bytes)."))
    }
    else {
        [void]$findings.Add((New-MoverFinding 'ERROR' 'attachment-size' "Maximum attachment size is smaller in the target ($($Target.maxUploadFileSize) bytes) than the source ($($Source.maxUploadFileSize) bytes). Larger web files would lose their content."))
    }

    $targetSolutions = @{}
    foreach ($solution in @($Target.solutions)) {
        if ($solution) { $targetSolutions["$($solution.uniqueName)".ToLowerInvariant()] = $solution }
    }
    $missingSolutions = @()
    $olderSolutions = @()
    foreach ($solution in @($Source.solutions)) {
        if (-not $solution -or "$($solution.uniqueName)" -notmatch $PortalSolutionPattern) { continue }
        $match = $targetSolutions["$($solution.uniqueName)".ToLowerInvariant()]
        if (-not $match) {
            $missingSolutions += $solution.uniqueName
            continue
        }
        $sourceVersion = ConvertTo-MoverVersion $solution.version
        $targetVersion = ConvertTo-MoverVersion $match.version
        if ($sourceVersion -and $targetVersion -and $targetVersion -lt $sourceVersion) {
            $olderSolutions += "$($solution.uniqueName) (source $($solution.version), target $($match.version))"
        }
    }
    if ($missingSolutions.Count -gt 0) {
        [void]$findings.Add((New-MoverFinding 'WARN' 'portal-solutions' "Portal solutions in the source that the target does not have: $($missingSolutions -join ', ')."))
    }
    if ($olderSolutions.Count -gt 0) {
        [void]$findings.Add((New-MoverFinding 'WARN' 'portal-solutions' "Portal solutions that are older in the target: $($olderSolutions -join '; '). Update them before importing."))
    }
    if ($missingSolutions.Count -eq 0 -and $olderSolutions.Count -eq 0) {
        [void]$findings.Add((New-MoverFinding 'OK' 'portal-solutions' 'Portal solutions in the target are present and not older than the source.'))
    }

    foreach ($website in @($Target.websites)) {
        if (-not $website) { continue }
        if ("$($website.id)" -ieq $WebsiteId) {
            [void]$findings.Add((New-MoverFinding 'WARN' 'websites' "The target already has this website record ('$($website.name)'). Importing will update it in place."))
        }
        else {
            [void]$findings.Add((New-MoverFinding 'WARN' 'websites' "The target has another website record: '$($website.name)' ($($website.id)). If it is the default record created by provisioning, delete it in Portal Management before importing."))
        }
    }

    return $findings.ToArray()
}

function Compare-MoverCounts {
    # One row per table: Match, Mismatch, or NotCounted (with the reason).
    param($SourceCounts, $TargetCounts, $SourceNotes, $TargetNotes)
    $source = ConvertTo-MoverMap $SourceCounts
    $target = ConvertTo-MoverMap $TargetCounts
    $sourceNotes = ConvertTo-MoverMap $SourceNotes
    $targetNotes = ConvertTo-MoverMap $TargetNotes

    $tables = @(@($source.Keys) + @($target.Keys) + @($sourceNotes.Keys) + @($targetNotes.Keys) | Sort-Object -Unique)
    $rows = @(
        foreach ($table in $tables) {
            $hasSource = $source.ContainsKey($table)
            $hasTarget = $target.ContainsKey($table)
            $note = $null
            if ($hasSource -and $hasTarget) {
                $status = if ([int]$source[$table] -eq [int]$target[$table]) { 'Match' } else { 'Mismatch' }
            }
            else {
                $status = 'NotCounted'
                $reasons = @()
                if (-not $hasSource) {
                    $reason = $sourceNotes[$table]
                    if (-not $reason) { $reason = 'not counted' }
                    $reasons += "source: $reason"
                }
                if (-not $hasTarget) {
                    $reason = $targetNotes[$table]
                    if (-not $reason) { $reason = 'not counted' }
                    $reasons += "target: $reason"
                }
                $note = $reasons -join '; '
            }
            $sourceValue = $null
            $targetValue = $null
            if ($hasSource) { $sourceValue = [int]$source[$table] }
            if ($hasTarget) { $targetValue = [int]$target[$table] }
            [pscustomobject]@{
                Table  = $table
                Source = $sourceValue
                Target = $targetValue
                Status = $status
                Note   = $note
            }
        }
    )
    return $rows
}
