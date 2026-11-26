[CmdletBinding()]
param(
    [string]$Server,
    [pscredential]$GuestCredential
)

$ErrorActionPreference = 'Stop'
if (!$GuestCredential) { throw 'Supply -GuestCredential.' }
if (-not $Server) {
    $defaults = Get-Variable -Name DefaultVIServers -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if (!$defaults) { $defaults = Get-Variable -Name DefaultVIServer -Scope Global -ValueOnly -ErrorAction SilentlyContinue }
    $connections = @($defaults | Where-Object { $_ -and $_.IsConnected })
    if ($connections.Count -ne 1) { throw 'Specify -Server when there is not exactly one default vCenter connection.' }
    $Server = $connections[0]
}
if ([WildcardPattern]::ContainsWildcardCharacters([string]$Server)) { throw 'Specify one exact vCenter server.' }
$guestQuery = 'Get-NetAdapter -IncludeHidden -ErrorAction Stop | Select-Object Name, MacAddress, ifIndex | ConvertTo-Json -Compress'
Get-VM -Server $Server | Where-Object { $_.PowerState -eq 'PoweredOn' -and $_.ExtensionData.Config.GuestFullName -match 'Windows' } | ForEach-Object {
    $vm = $_
    $result = Invoke-VMScript -VM $vm -GuestCredential $GuestCredential -ScriptType Powershell -ScriptText $guestQuery
    if ($result.ExitCode -ne 0) { throw "Adapter query failed on $($vm.Name)." }
    $adapters = $result.ScriptOutput | ConvertFrom-Json
    foreach ($nic in ($vm | Get-NetworkAdapter)) {
        $mac = $nic.MacAddress -replace '[:-]'
        $guest = @($adapters | Where-Object { $_.MacAddress -and ($_.MacAddress -replace '[:-]') -eq $mac })
        if ($guest.Count -gt 1) { throw "Ambiguous guest MAC $mac on $($vm.Name)." }
        [pscustomobject]@{ VM = $vm.Name; Portgroup = $nic.NetworkName; vMAC = $nic.MacAddress; osMAC = $guest.MacAddress -join ''; vNIC = $nic.Name; osNIC = $guest.Name -join ''; vSlot = $nic.ExtensionData.SlotInfo.PciSlotNumber; InterfaceIndex = $guest.ifIndex -join '' }
    }
}
