[CmdletBinding()]
param(
    $Server
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

foreach ($vm in (Get-VM -Server $Server)) {
    $view = $vm.ExtensionData
    $entry = Get-VIEvent -Server $Server -Entity $vm -MaxSamples ([int]::MaxValue) | Where-Object {
        $_.Vm.Vm.Value -eq $view.MoRef.Value -and $_.GetType().Name -in 'VmCreatedEvent', 'VmClonedEvent', 'VmDeployedEvent'
    } | Sort-Object CreatedTime | Select-Object -First 1
    [pscustomobject]@{
        VMName      = $vm.Name
        VMId        = $vm.Id
        Hostname    = $view.Guest.HostName
        OS          = $view.Config.GuestFullName
        IPAddress   = $view.Guest.IpAddress
        CreatedDate = $view.Config.CreateDate
        Creator     = $entry.UserName
        Notes       = $view.Config.Annotation -replace '[\r\n]', ''
    }
}
