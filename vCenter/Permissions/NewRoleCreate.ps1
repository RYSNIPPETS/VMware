[CmdletBinding()]
param(
    $Server,
    [string]$Role = 'New Custom Role',
    [string[]]$PrivilegeGroup = @('Interaction', 'Provisioning')
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

$privileges = @(Get-VIPrivilege -Server $Server -PrivilegeGroup -Name $PrivilegeGroup)
if (!$privileges) { throw 'No matching privileges were found.' }
New-VIRole -Name $Role -Server $Server -Privilege $privileges -Confirm:$false
