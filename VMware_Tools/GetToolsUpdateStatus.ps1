[CmdletBinding()]
param(
    $Server,
    [string]$ListPath = './ServerList.txt',
    [string]$Path = './VMToolsUpdate.csv'
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

function Get-ExactVM {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'A VM name is required.' }
    $matchesFound = @(Get-VM -Server $Server -Name ([WildcardPattern]::Escape($Name)) | Where-Object Name -EQ $Name)
    if ($matchesFound.Count -ne 1) { throw "Expected one VM named '$Name' on '$Server'. Found $($matchesFound.Count)." }
    $matchesFound[0]
}

$rows = foreach ($name in (Get-Content -LiteralPath $ListPath | Where-Object { $_.Trim() } | Sort-Object -Unique)) {
    $vm = Get-ExactVM $name.Trim()
    $status = $vm.ExtensionData.Guest.ToolsVersionStatus2
    $action = switch ($status) {
        guestToolsCurrent { 'Current' }
        guestToolsUnmanaged { 'Guest managed' }
        guestToolsNotInstalled { 'Install Tools' }
        guestToolsSupportedNew { 'Newer supported version' }
        guestToolsTooNew { 'Check host compatibility' }
        guestToolsBlacklisted { 'Upgrade required' }
        guestToolsTooOld { 'Upgrade required' }
        guestToolsNeedUpgrade { 'Upgrade available' }
        guestToolsSupportedOld { 'Upgrade available' }
        default { 'Unknown' }
    }
    [pscustomobject]@{
        Name                   = $vm.Name
        Server                 = [string]$Server
        Assessment             = $action
        VMId                   = $vm.Id
        'VMware Tools Version' = $vm.ExtensionData.Config.Tools.ToolsVersion
        'VMware Tools Status'  = $vm.ExtensionData.Guest.ToolsVersionStatus2
    }
}
$rows | Export-Csv -LiteralPath $Path
