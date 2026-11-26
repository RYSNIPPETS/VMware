[CmdletBinding()]
param(
    [string]$Server,
    [string]$Path = './MountedISOs.csv'
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
$instance = (Get-View -Id ServiceInstance -Server $Server -Property Content.About).Content.About.InstanceUuid
foreach ($row in (Import-Csv -LiteralPath $Path)) {
    if (!$row.InstanceUuid -or $row.InstanceUuid -ne $instance) { throw 'Report belongs to a different or unidentified vCenter.' }
    $vm = Get-VM -Server $Server -Id $row.VMId
    $drives = @($vm | Get-CDDrive | Where-Object Id -EQ $row.DriveId)
    if ($drives.Count -ne 1 -or !$row.ISOPath) { throw "Invalid drive record for $($row.VMName)." }
    if (!$drives[0].IsoPath) { continue }
    if ($drives[0].IsoPath -cne $row.ISOPath) { throw "Mounted ISO changed on $($vm.Name)." }
    Set-CDDrive -CD $drives[0] -NoMedia -Confirm:$false
}
