[CmdletBinding()]
param(
    $Server,
    [string[]]$VMName
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

$targets = if ($VMName) { foreach ($name in $VMName) { Get-ExactVM $name } } else { Get-VM -Server $Server }
# Some guest/Tools combinations can reboot even when -NoReboot is requested.
foreach ($vm in $targets) {
    $guest = $vm.ExtensionData.Guest
    if ($vm.PowerState -eq 'PoweredOn' -and $guest.ToolsRunningStatus -eq 'guestToolsRunning' -and
        $guest.ToolsVersionStatus2 -in 'guestToolsNeedUpgrade', 'guestToolsSupportedOld', 'guestToolsTooOld', 'guestToolsBlacklisted') {
        Update-Tools -VM $vm -NoReboot -ErrorAction Stop
    }
}
