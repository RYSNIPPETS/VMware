[CmdletBinding()]
param(
    [string]$Server,
    [string]$VMName,
    [string]$TemplateName,
    [string]$DatastoreCluster,
    [string]$FolderId
)

$ErrorActionPreference = 'Stop'
if (!$VMName -or !$TemplateName -or !$DatastoreCluster -or !$FolderId) { throw 'Supply -VMName, -TemplateName, -DatastoreCluster and -FolderId.' }
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
function Get-SingleItem {
    param([object[]]$Items, [string]$Description)
    if ($Items.Count -ne 1 -or $null -eq $Items[0]) { throw "Expected one $Description. Found $($Items.Count)." }
    $Items[0]
}
$vm = Get-ExactVM $VMName
$store = Get-SingleItem @(Get-DatastoreCluster -Server $Server -Name ([WildcardPattern]::Escape($DatastoreCluster)) | Where-Object Name -EQ $DatastoreCluster) 'datastore cluster'
$folder = Get-SingleItem @(Get-Folder -Server $Server -Id $FolderId | Where-Object Id -EQ $FolderId) 'folder'
New-Template -Server $Server -VM $vm -Name $TemplateName -Datastore $store -Location $folder -Confirm:$false
