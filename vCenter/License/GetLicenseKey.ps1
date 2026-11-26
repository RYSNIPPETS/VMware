[CmdletBinding()]
param(
    [string]$EntityName,
    [switch]$Effective,
    $Server
)

$ErrorActionPreference = 'Stop'

function Get-LicenseKey {
    param([string]$EntityName, [switch]$Effective, $Server)
    if (-not $Server) {
        $defaults = Get-Variable -Name DefaultVIServers -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if (!$defaults) { $defaults = Get-Variable -Name DefaultVIServer -Scope Global -ValueOnly -ErrorAction SilentlyContinue }
        $connections = @($defaults | Where-Object { $_ -and $_.IsConnected })
        if ($connections.Count -ne 1) { throw 'Specify -Server when there is not exactly one default vCenter connection.' }
        $Server = $connections[0]
    }
    if ([WildcardPattern]::ContainsWildcardCharacters([string]$Server)) { throw 'Specify one exact vCenter server.' }

    $about = (Get-View ServiceInstance -Server $Server -ErrorAction Stop).Content.About
    if (!$about.Version) { throw 'Unable to identify vCenter version.' }
    if ([version]$about.Version -ge [version]'9.0') { throw 'Use VCF Operations subscription licensing for vSphere 9 or later (Broadcom KB 428638).' }
    $manager = Get-LicenseDataManager -Server $Server
    if (!$EntityName) { $manager.QueryEntityLicenseData(); return }
    $entities = @(Get-Inventory -Name ([WildcardPattern]::Escape($EntityName)) -Server $Server | Where-Object Name -CEQ $EntityName)
    if ($entities.Count -ne 1) { throw "Expected one inventory object named '$EntityName'." }
    if ($Effective) { $manager.QueryEffectiveLicenseData($entities[0].Uid) }
    else { $manager.QueryAssociatedLicenseData($entities[0].Uid) }
}
if ($MyInvocation.InvocationName -ne '.') { Get-LicenseKey @PSBoundParameters }
