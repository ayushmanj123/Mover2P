<#
.SYNOPSIS
Moves a standard data model Power Pages site from one tenant to another.

.DESCRIPTION
  export    Reads the source environment and writes a portable package.
  check     Compares the target environment with the package. Changes nothing.
  import    Runs check, then imports solutions, site and gap-table data.
  validate  Compares record counts in the target with the source.

.EXAMPLE
.\Mover2P.ps1 export -Config .\config\contoso.json

.EXAMPLE
.\Mover2P.ps1 import -Config .\config\contoso.json -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('export', 'check', 'import', 'validate')]
    [string]$Command,

    [Parameter(Mandatory = $true)]
    [string]$Config,

    # Show the pac commands without running them. Read-only checks still run.
    [switch]$DryRun,

    # Skip the confirmation prompt before importing.
    [switch]$Yes,

    # Limit import to some steps, for example to resume after a failure.
    [ValidateSet('solutions', 'site', 'data')]
    [string[]]$Steps = @('solutions', 'site', 'data')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\Mover2P.psm1') -Force

try {
    $sides = if ($Command -eq 'export') { @('source') } else { @('target') }
    $settings = Read-MoverConfig -Path $Config -Sides $sides

    $exitCode = switch ($Command) {
        'export' { Invoke-MoverExport -Config $settings -DryRun:$DryRun }
        'check' { Invoke-MoverCheck -Config $settings }
        'import' { Invoke-MoverImport -Config $settings -DryRun:$DryRun -Yes:$Yes -Steps $Steps }
        'validate' { Invoke-MoverValidate -Config $settings }
    }
    exit ([int]$exitCode)
}
catch {
    Write-MoverLog "$($_.Exception.Message)" -Level ERROR
    exit 1
}
