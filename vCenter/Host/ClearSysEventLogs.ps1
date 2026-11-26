[CmdletBinding()]
param(
    $Server,
    [string]$Name
)

$ErrorActionPreference = 'Stop'

if (-not $Server) {
    $defaults = Get-Variable -Name DefaultVIServers -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if (!$defaults) { $defaults = Get-Variable -Name DefaultVIServer -Scope Global -ValueOnly -ErrorAction SilentlyContinue }
    $connections = @($defaults | Where-Object { $_ -and $_.IsConnected })
    if ($connections.Count -ne 1) { throw 'Specify -Server when there is not exactly one default vCenter connection.' }
    $Server = $connections[0]
}
if ([WildcardPattern]::ContainsWildcardCharacters([string]$Server)) { throw 'Specify one exact vCenter server.' }

function Get-SingleItem {
    param([object[]]$Items, [string]$Description)
    if ($Items.Count -ne 1 -or $null -eq $Items[0]) { throw "Expected one $Description. Found $($Items.Count)." }
    $Items[0]
}

if (!$Name) { throw 'Supply the exact host name using -Name.' }
$target = Get-SingleItem @(Get-VMHost -Server $Server | Where-Object Name -CEQ $Name) 'matching host'
$health = Get-View -Server $Server -Id $target.ExtensionData.ConfigManager.HealthStatusSystem
$health.ClearSystemEventLog()
