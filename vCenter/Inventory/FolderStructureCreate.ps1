[CmdletBinding()]
param(
    $Server,
    [string]$DC,
    [ValidateSet('Blue', 'Yellow')][string]$FolderType = 'Blue',
    [string]$Filename
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
function Resolve-FolderPath {
    param($Root, [string[]]$Parts, $Server, [switch]$Create)
    $parent = $Root
    foreach ($part in $Parts) {
        if ([string]::IsNullOrEmpty($part)) { throw 'Empty folder name in path.' }
        $found = @(Get-ChildFolder $parent $Server | Where-Object Name -CEQ $part)
        if (!$found -and $Create) { $parent = New-Folder -Location $parent -Name $part -Server $Server }
        else { $parent = Get-SingleItem $found "child folder '$part' under '$($parent.Name)'" }
    }
    $parent
}
function Get-RowPath {
    param($Row, $Root, [string]$DC, [switch]$VM)
    if ($Row.PathParts) {
        if ($Row.Root -cne $Root.Name -or $Row.Datacenter -cne $DC) { throw 'Folder root or datacenter differs from export.' }
        $parts = ConvertFrom-Json -InputObject $Row.PathParts -NoEnumerate
        if ($parts -isnot [array]) { throw 'Invalid folder path array.' }
        foreach ($part in $parts) {
            if ($part -isnot [string] -or !$part) { throw 'Invalid folder name.' }
            $part
        }
        return
    }
    $legacy = @($Row.Path -split '\\')
    if ($legacy[0] -ceq $DC) { $legacy = @($legacy | Select-Object -Skip 1) }
    elseif ($legacy[0] -cne $Root.Name) { throw 'Legacy path lacks a matching inventory root.' }
    if ($legacy[0] -ceq $Root.Name) { $legacy = @($legacy | Select-Object -Skip 1) }
    if (!$legacy -or $legacy[-1] -cne $Row.Name) { throw 'Legacy path and row name disagree.' }
    if ($VM) { $legacy | Select-Object -SkipLast 1 } else { $legacy }
}
function Import-Folder {
    param([ValidateSet('Blue', 'Yellow')][string]$FolderType, [string]$DC, [string]$Filename, $Server)
    if (!$Filename) { throw 'Supply -Filename.' }
    if (-not $Server) {
        $defaults = Get-Variable -Name DefaultVIServers -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if (!$defaults) { $defaults = Get-Variable -Name DefaultVIServer -Scope Global -ValueOnly -ErrorAction SilentlyContinue }
        $connections = @($defaults | Where-Object { $_ -and $_.IsConnected })
        if ($connections.Count -ne 1) { throw 'Specify -Server when there is not exactly one default vCenter connection.' }
        $Server = $connections[0]
    }
    if ([WildcardPattern]::ContainsWildcardCharacters([string]$Server)) { throw 'Specify one exact vCenter server.' }

    $root = Get-InventoryRoot -Server $Server -DC $DC -Kind $FolderType
    foreach ($row in (Import-Csv -LiteralPath $Filename)) {
        $parts = @(Get-RowPath -Row $row -Root $root -DC $DC)
        if (!$parts -or $parts[-1] -cne $row.Name) { throw 'Folder leaf and row name disagree.' }
        Resolve-FolderPath -Root $root -Parts $parts -Server $Server -Create
    }
}
if ($MyInvocation.InvocationName -ne '.') { Import-Folder -FolderType $FolderType -DC $DC -Filename $Filename -Server $Server }
