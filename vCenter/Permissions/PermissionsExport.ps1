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
function Export-PermissionsToCSV {
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
    $rows = foreach ($perm in (Get-VIPermission -Server $Server -ErrorAction Stop)) {
        $view = Get-View -Id $perm.EntityId -Server $Server -Property Name, Parent -ErrorAction Stop
        [pscustomobject]@{
            ServerInstanceUuid = $instance
            EntityId           = $perm.EntityId
            Name               = $view.Name
            Type               = $view.MoRef.Type
            EntityPath         = Get-EntityPath $view $Server
            Role               = [string]$perm.Role
            Principal          = $perm.Principal
            IsGroup            = $perm.IsGroup
            Propagate          = $perm.Propagate
        }
    }
    $rows | Export-Csv -LiteralPath $Filename
}
if ($MyInvocation.InvocationName -ne '.') { Export-PermissionsToCSV -Filename $Filename -Server $Server }
