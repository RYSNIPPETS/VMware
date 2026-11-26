[CmdletBinding()]
param(
    $Server,
    [string]$Path = './ToolsStatus.csv'
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

Get-VM -Server $Server | ForEach-Object {
    $vm = $_
    [pscustomobject]@{
        Name                   = $vm.Name
        Server                 = [string]$Server
        VMId                   = $vm.Id
        'VMware Tools Version' = $vm.ExtensionData.Config.Tools.ToolsVersion
        'VMware Tools Status'  = $vm.ExtensionData.Guest.ToolsVersionStatus2
    }
} | Export-Csv -LiteralPath $Path
