[CmdletBinding()]
param(
    [string]$Server,
    [string]$Path = './VMList.csv'
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
foreach ($row in (Import-Csv -LiteralPath $Path)) {
    $vm = Get-ExactVM $row.Name
    $snapshotName = "$($vm.Name).SNAPSHOT"
    if (!(Get-Snapshot -VM $vm | Where-Object Name -EQ $snapshotName)) {
        New-Snapshot -VM $vm -Name $snapshotName -Description 'Snapshot' -Quiesce -Memory:$false -Confirm:$false
    }
}
