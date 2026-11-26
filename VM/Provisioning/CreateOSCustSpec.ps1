[CmdletBinding()]
param(
    [string]$Server,
    [string]$Name = 'Win2022Spec',
    [string]$Domain,
    [pscredential]$DomainCredential,
    [securestring]$AdminPassword,
    [string]$Organization = 'Organization Name',
    [string]$ProductKey
)

$ErrorActionPreference = 'Stop'
if (!$Domain -or !$DomainCredential -or !$AdminPassword) { throw 'Supply -Domain, -DomainCredential and -AdminPassword.' }
if (-not $Server) {
    $defaults = Get-Variable -Name DefaultVIServers -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if (!$defaults) { $defaults = Get-Variable -Name DefaultVIServer -Scope Global -ValueOnly -ErrorAction SilentlyContinue }
    $connections = @($defaults | Where-Object { $_ -and $_.IsConnected })
    if ($connections.Count -ne 1) { throw 'Specify -Server when there is not exactly one default vCenter connection.' }
    $Server = $connections[0]
}
if ([WildcardPattern]::ContainsWildcardCharacters([string]$Server)) { throw 'Specify one exact vCenter server.' }
$options = @{ Server = $Server; Name = $Name; FullName = 'Administrator'; OrgName = $Organization; Domain = $Domain; DomainCredentials = $DomainCredential; OSType = 'Windows'; TimeZone = '004'; Type = 'Persistent'; NamingScheme = 'Vm'; AdminPassword = ([pscredential]::new('Administrator', $AdminPassword).GetNetworkCredential().Password) }
if ($ProductKey) { $options.ProductKey = $ProductKey }
# New-OSCustomizationSpec creates its first NIC mapping with DHCP.
New-OSCustomizationSpec @options -Confirm:$false
