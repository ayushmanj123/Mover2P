# Logging with secret redaction. Every message passes through Protect-MoverText
# before it reaches the console or the log file.

$script:MoverLogFile = $null
$script:MoverSecrets = New-Object 'System.Collections.Generic.List[string]'

function Register-MoverSecret {
    param([string]$Value)
    if ($Value -and -not $script:MoverSecrets.Contains($Value)) {
        $script:MoverSecrets.Add($Value)
    }
}

function Protect-MoverText {
    param([string]$Text)
    if (-not $Text) { return $Text }
    foreach ($secret in $script:MoverSecrets) {
        $Text = $Text.Replace($secret, '***')
    }
    return $Text
}

function Set-MoverLogFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $script:MoverLogFile = $Path
}

function Write-MoverLog {
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $safe = Protect-MoverText $Message
    $color = switch ($Level) {
        'OK' { 'Green' }
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }
    Write-Host ('[{0}] {1}' -f $Level.PadRight(5), $safe) -ForegroundColor $color
    if ($script:MoverLogFile) {
        $line = '{0} [{1}] {2}' -f (Get-Date).ToString('s'), $Level, $safe
        Add-Content -LiteralPath $script:MoverLogFile -Value $line -Encoding UTF8
    }
}
