[CmdletBinding()]
param(
    [string]$Server,
    [string]$Path = './VMs.csv',
    [string]$DestinationFolderId
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
if (!$DestinationFolderId) { throw 'Specify the exact -DestinationFolderId.' }
$folder = @(Get-Folder -Server $Server -Id $DestinationFolderId | Where-Object { $_.Id -eq $DestinationFolderId -and $_.Type -eq 'VM' })
if ($folder.Count -ne 1) { throw 'Expected one VM destination folder.' }
foreach ($row in (Import-Csv -LiteralPath $Path)) {
    $vm = Get-ExactVM $row.Name
    if ($vm.FolderId -ne $folder[0].Id) { Move-VM -VM $vm -InventoryLocation $folder[0] -Confirm:$false }
}
