[CmdletBinding()]
param(
    [string]$Filename,
    $Server
)

$ErrorActionPreference = 'Stop'

function Get-EntityPath {
    param($View, $Server)
    $parts = [System.Collections.Generic.List[object]]::new()
    while ($View) {
        $parts.Insert(0, [ordered]@{ Type = $View.MoRef.Type; Name = $View.Name })
        if (!$View.Parent) { break }
        $View = Get-View -Id $View.Parent -Server $Server -Property Name, Parent -ErrorAction Stop
    }
    ConvertTo-Json -InputObject $parts.ToArray() -Compress
}
function Get-SingleItem {
    param([object[]]$Items, [string]$Description)
    if ($Items.Count -ne 1 -or $null -eq $Items[0]) { throw "Expected one $Description. Found $($Items.Count)." }
    $Items[0]
}
function Get-PermissionAccount {
    param([string]$Principal, [bool]$IsGroup, $Server)
    $id = $Principal
    $domain = $null
    if ($Principal -match '^([^\\]+)\\(.+)$') { $domain = $Matches[1]; $id = $Matches[2] }
    elseif ($Principal -match '^([^@]+)@([^@]+)$') { $id = $Matches[1]; $domain = $Matches[2] }
    $lookup = @{ Id = $id; Server = $Server; Group = $IsGroup; User = !$IsGroup }
    if ($domain) { $lookup.Domain = $domain }
    $accounts = @(Get-VIAccount @lookup | Where-Object {
            $_.Id -eq $Principal -or ($_.Id -eq $id -and $_.Domain -eq $domain)
        })
    Get-SingleItem $accounts "account '$Principal'"
}

function Import-Permission {
    param([string]$Filename, $Server)
    if (!$Filename) { throw 'Supply a permissions CSV path using -Filename.' }
    if (-not $Server) {
        $defaults = Get-Variable -Name DefaultVIServers -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if (!$defaults) { $defaults = Get-Variable -Name DefaultVIServer -Scope Global -ValueOnly -ErrorAction SilentlyContinue }
        $connections = @($defaults | Where-Object { $_ -and $_.IsConnected })
        if ($connections.Count -ne 1) { throw 'Specify -Server when there is not exactly one default vCenter connection.' }
        $Server = $connections[0]
    }
    if ([WildcardPattern]::ContainsWildcardCharacters([string]$Server)) { throw 'Specify one exact vCenter server.' }

    $instance = (Get-View -Id ServiceInstance -Server $Server).Content.About.InstanceUuid
    if (!$instance) { throw 'Unable to identify vCenter instance.' }
    # Resolve every row before granting the first permission. Legacy exports lack object identity.
    $changes = foreach ($row in (Import-Csv -LiteralPath $Filename)) {
        if (!$row.EntityId -or !$row.EntityPath -or $instance -ne $row.ServerInstanceUuid) {
            throw 'This export lacks matching vCenter identity or inventory metadata. Generate a fresh export from this vCenter.'
        }
        $view = Get-View -Id $row.EntityId -Server $Server -Property Name, Parent -ErrorAction Stop
        if ($view.Name -cne $row.Name -or $view.MoRef.Type -cne $row.Type -or (Get-EntityPath $view $Server) -cne $row.EntityPath) {
            throw "Inventory identity changed for $($row.EntityId). Review and re-export permissions."
        }
        $entity = $view | Get-VIObjectByVIView
        $role = Get-SingleItem @(Get-VIRole -Server $Server | Where-Object Name -CEQ $row.Role) 'matching role'
        $group = [bool]::Parse($row.IsGroup)
        $propagate = [bool]::Parse($row.Propagate)
        if (!$row.Principal) { throw 'Missing principal.' }
        $account = Get-PermissionAccount -Principal $row.Principal -IsGroup $group -Server $Server
        [pscustomobject]@{Entity = $entity; EntityId = $row.EntityId; Role = $role; Account = $account; Principal = $row.Principal; Group = $group; Propagate = $propagate }
    }
    foreach ($change in $changes) {
        $existing = @(Get-VIPermission -Entity $change.Entity -Server $Server | Where-Object {
                $_.EntityId -eq $change.EntityId -and $_.Principal -eq $change.Principal -and $_.IsGroup -eq $change.Group
            })
        if ($existing.Count -gt 1) { throw "Duplicate assignment for $($change.Account.Id)." }
        if (!$existing) {
            New-VIPermission -Entity $change.Entity -Role $change.Role -Principal $change.Account -Propagate:$change.Propagate -Server $Server -Confirm:$false
        }
        elseif ($existing[0].Role -cne $change.Role.Name -or $existing[0].Propagate -ne $change.Propagate) {
            Set-VIPermission -Permission $existing[0] -Role $change.Role -Propagate:$change.Propagate -Confirm:$false
        }
    }
}
if ($MyInvocation.InvocationName -ne '.') { Import-Permission -Filename $Filename -Server $Server }
