[CmdletBinding()]
param(
    $Server,
    [string]$Datacenter,
    [string]$Cluster = 'Production'
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

$centers = @(Get-Datacenter -Server $Server | Where-Object { !$Datacenter -or $_.Name -ceq $Datacenter })
$location = Get-SingleItem $centers 'matching datacenter'
$matchesInDC = @(Get-Cluster -Location $location -Server $Server | Where-Object Name -CEQ $Cluster)
$configuration = @{ HAEnabled = $true; HAAdmissionControlEnabled = $true; HAFailoverLevel = 1; HARestartPriority = "Medium" }
if (!$matchesInDC) {
    New-Cluster -Location $location -Name $Cluster -Server $Server @configuration -Confirm:$false
    return
}
$target = Get-SingleItem $matchesInDC 'matching cluster'
Set-Cluster -Cluster $target @configuration -Confirm:$false
