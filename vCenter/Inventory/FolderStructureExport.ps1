[CmdletBinding()]
param(
    $Server,
    [string]$DC,
    [ValidateSet('Blue', 'Yellow')][string]$FolderType = 'Blue',
    [string]$Filename = './BlueFolders.csv',
    [string]$VMLocationPath
)

$ErrorActionPreference = 'Stop'

function Get-SingleItem {
    param([object[]]$Items, [string]$Description)
    if ($Items.Count -ne 1 -or $null -eq $Items[0]) { throw "Expected one $Description. Found $($Items.Count)." }
    $Items[0]
}

function Get-InventoryRoot {
    param($Server, [string]$DC, [string]$Kind)
    if (!$DC) { throw 'Supply an exact datacenter name.' }
    $location = Get-SingleItem @(Get-Datacenter -Server $Server | Where-Object Name -CEQ $DC) 'matching datacenter'
    $ref = if ($Kind -eq 'Yellow') { $location.ExtensionData.HostFolder } else { $location.ExtensionData.VmFolder }
    Get-SingleItem @(Get-Folder -Id "Folder-$($ref.Value)" -Server $Server) 'inventory root folder'
}
function Get-ChildFolder {
    param($Parent, $Server)
    Get-Folder -Location $Parent -NoRecursion -Server $Server | Where-Object { $_.ExtensionData.Parent.Value -eq $Parent.ExtensionData.MoRef.Value }
}
function Write-FolderRow {
    param($Folder, $Root, $Server, $DC, [string[]]$Parts, [switch]$VMs)
    if ($VMs) {
        $instance = $Root.ExtensionData.Client.ServiceContent.About.InstanceUuid
        foreach ($ref in $Folder.ExtensionData.ChildEntity | Where-Object Type -EQ 'VirtualMachine') {
            $view = Get-View -Id $ref -Server $Server -Property Name, Config.Template
            if ($view.Config.Template) { continue }
            [pscustomobject]@{ Datacenter = $DC; Root = $Root.Name; Name = $view.Name; PathParts = (ConvertTo-Json -InputObject @($Parts | Where-Object { $_ }) -Compress); VMId = "VirtualMachine-$($ref.Value)"; ServerInstanceUuid = $instance }
        }
    }
    foreach ($child in (Get-ChildFolder $Folder $Server)) {
        $childParts = @($Parts | Where-Object { $_ }) + $child.Name
        if (!$VMs) {
            [pscustomobject]@{ Datacenter = $DC; Root = $Root.Name; Name = $child.Name; PathParts = (ConvertTo-Json -InputObject $childParts -Compress); Path = (@($Root.Name) + $childParts -join '\') }
        }
        Write-FolderRow -Folder $child -Root $Root -Server $Server -DC $DC -Parts $childParts -VMs:$VMs
    }
}
function Export-Folder {
    param([ValidateSet('Blue', 'Yellow')][string]$FolderType, [string]$DC, [string]$Filename, $Server)
    if (-not $Server) {
        $defaults = Get-Variable -Name DefaultVIServers -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if (!$defaults) { $defaults = Get-Variable -Name DefaultVIServer -Scope Global -ValueOnly -ErrorAction SilentlyContinue }
        $connections = @($defaults | Where-Object { $_ -and $_.IsConnected })
        if ($connections.Count -ne 1) { throw 'Specify -Server when there is not exactly one default vCenter connection.' }
        $Server = $connections[0]
    }
    if ([WildcardPattern]::ContainsWildcardCharacters([string]$Server)) { throw 'Specify one exact vCenter server.' }

    $root = Get-InventoryRoot -Server $Server -DC $DC -Kind $FolderType
    Write-FolderRow -Folder $root -Root $root -Server $Server -DC $DC -Parts @() | Export-Csv -LiteralPath $Filename
}
function Export-VMLocation {
    param([string]$DC, [string]$Filename, $Server)
    if (-not $Server) {
        $defaults = Get-Variable -Name DefaultVIServers -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if (!$defaults) { $defaults = Get-Variable -Name DefaultVIServer -Scope Global -ValueOnly -ErrorAction SilentlyContinue }
        $connections = @($defaults | Where-Object { $_ -and $_.IsConnected })
        if ($connections.Count -ne 1) { throw 'Specify -Server when there is not exactly one default vCenter connection.' }
        $Server = $connections[0]
    }
    if ([WildcardPattern]::ContainsWildcardCharacters([string]$Server)) { throw 'Specify one exact vCenter server.' }

    $root = Get-InventoryRoot -Server $Server -DC $DC -Kind Blue
    Write-FolderRow -Folder $root -Root $root -Server $Server -DC $DC -Parts @() -VMs | Export-Csv -LiteralPath $Filename
}
if ($MyInvocation.InvocationName -ne '.') {
    if (!$PSBoundParameters.ContainsKey('Filename') -and $FolderType -eq 'Yellow') { $Filename = './YellowFolders.csv' }
    Export-Folder -FolderType $FolderType -DC $DC -Filename $Filename -Server $Server
    if ($VMLocationPath) { Export-VMLocation -DC $DC -Filename $VMLocationPath -Server $Server }
}
