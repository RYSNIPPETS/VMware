[CmdletBinding()]
param(
    $Server,
    [string]$Datacenter,
    [string]$Role,
    [string]$Principal,
    [switch]$Group
)

$ErrorActionPreference = 'Stop'

if (!$Datacenter -or !$Role -or !$Principal) { throw 'Supply -Datacenter, -Role and -Principal.' }
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
function Get-PermissionAccount {
    param([string]$Principal, [bool]$IsGroup, $Server)
    $id = $Principal
    $domain = $null
    if ($Principal -match '^([^\\]+)\\(.+)$') { $domain = $Matches[1]; $id = $Matches[2] }
    elseif ($Principal -match '^([^@]+)@([^@]+)$') { $id = $Matches[1]; $domain = $Matches[2] }
    $lookup = @{ Id = $id; Server = $Server; Group = $IsGroup; User = !$IsGroup }
    if ($domain) { $lookup.Domain = $domain }
    $accounts = @(Get-VIAccount @lookup | Where-Object {
            $_.Id -eq $Principal -or ($_.Id -eq $id -and $_.Domain -eq $domain)
        })
    Get-SingleItem $accounts "account '$Principal'"
}

$centers = @(Get-Datacenter -Server $Server | Where-Object { !$Datacenter -or $_.Name -ceq $Datacenter })
$location = Get-SingleItem $centers 'matching datacenter'
$targetRole = Get-SingleItem @(Get-VIRole -Server $Server | Where-Object Name -CEQ $Role) 'matching role'
$account = Get-PermissionAccount -Principal $Principal -IsGroup $Group -Server $Server
New-VIPermission -Role $targetRole -Principal $account -Entity $location -Server $Server -Confirm:$false
