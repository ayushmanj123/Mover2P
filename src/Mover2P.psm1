# Mover2P: moves a standard data model Power Pages site between tenants by
# orchestrating the Power Platform CLI. Written for Windows PowerShell 5.1.

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Log.ps1')
. (Join-Path $PSScriptRoot 'Config.ps1')
. (Join-Path $PSScriptRoot 'Pac.ps1')
. (Join-Path $PSScriptRoot 'Dataverse.ps1')
. (Join-Path $PSScriptRoot 'Facts.ps1')
. (Join-Path $PSScriptRoot 'Compare.ps1')
. (Join-Path $PSScriptRoot 'Commands.ps1')

Export-ModuleMember -Function *-Mover*
