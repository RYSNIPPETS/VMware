[CmdletBinding()]
param(
    $Server,
    [string]$Name = 'Boston'
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

$root = (Get-View -Id ServiceInstance -Server $Server).Content.RootFolder
$folder = Get-Folder -Id "Folder-$($root.Value)" -Server $Server
New-Datacenter -Name $Name -Location $folder -Server $Server -Confirm:$false
