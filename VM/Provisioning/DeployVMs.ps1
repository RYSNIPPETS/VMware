[CmdletBinding()]
param(
    [string]$Server,
    [string]$Path = './NewVMs.csv'
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
function Get-SingleItem {
    param([object[]]$Items, [string]$Description)
    if ($Items.Count -ne 1 -or $null -eq $Items[0]) { throw "Expected one $Description. Found $($Items.Count)." }
    $Items[0]
}
function Assert-VMNameAvailable([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'A VM name is required.' }
    $filter = @{ Name = '(?i)^' + [regex]::Escape($Name) + '$' }
    if (Get-View -Server $Server -ViewType VirtualMachine -Property Name -Filter $filter) { throw "A VM named '$Name' already exists on $Server." }
}
foreach ($row in (Import-Csv -LiteralPath $Path)) {
    foreach ($column in 'Name', 'Cluster', 'Template', 'Datastore', 'Customization', 'Location', 'Network', 'vCPU', 'Memory') {
        if ([string]::IsNullOrWhiteSpace($row.$column)) { throw "Missing CSV value for $column." }
    }
    if ([int]$row.vCPU -lt 1 -or [decimal]$row.Memory -le 0) { throw 'CPU and memory must be positive.' }
    Assert-VMNameAvailable $row.Name
    $cluster = Get-SingleItem @(Get-Cluster -Server $Server -Name ([WildcardPattern]::Escape($row.Cluster)) | Where-Object Name -EQ $row.Cluster) 'cluster'
    $template = Get-SingleItem @(Get-Template -Server $Server -Name ([WildcardPattern]::Escape($row.Template)) | Where-Object Name -EQ $row.Template) 'template'
    $store = Get-SingleItem @(Get-Datastore -Server $Server -Name ([WildcardPattern]::Escape($row.Datastore)) | Where-Object Name -EQ $row.Datastore) 'datastore'
    $folder = Get-SingleItem @(Get-Folder -Server $Server -Type VM -Name ([WildcardPattern]::Escape($row.Location)) | Where-Object Name -EQ $row.Location) 'VM folder'
    $spec = Get-SingleItem @(Get-OSCustomizationSpec -Server $Server -Name ([WildcardPattern]::Escape($row.Customization)) | Where-Object Name -EQ $row.Customization) 'customization specification'
    $clone = New-VM -Server $Server -Name $row.Name -Template $template -ResourcePool $cluster -Location $folder -DiskStorageFormat Thin -Datastore $store -OSCustomizationSpec $spec -ErrorAction Stop
    $vm = Get-SingleItem @($clone) 'newly cloned VM'
    Set-VM -VM $vm -MemoryGB $row.Memory -NumCpu $row.vCPU -Confirm:$false | Out-Null
    Get-NetworkAdapter -VM $vm | Set-NetworkAdapter -NetworkName $row.Network -Confirm:$false | Out-Null
    $vm
}
