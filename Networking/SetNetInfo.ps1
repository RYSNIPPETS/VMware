[CmdletBinding()]
param(
    [string]$Server,
    [string]$VMName,
    [pscredential]$GuestCredential,
    [ipaddress]$OriginalIP,
    [ipaddress]$NewIP,
    [ipaddress]$SubnetMask,
    [ipaddress]$Gateway,
    [ipaddress]$DnsServer
)

$ErrorActionPreference = 'Stop'
if (!$VMName -or !$GuestCredential) { throw 'Supply -VMName and -GuestCredential.' }
foreach ($address in @($OriginalIP, $NewIP, $SubnetMask, $Gateway, $DnsServer)) {
    if ($address.AddressFamily -ne 'InterNetwork') { throw 'Supply an IPv4 address for each network setting.' }
}
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
function ConvertTo-GuestData {
    param($Value)
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Compress -Depth 5)))
}
$vm = Get-ExactVM $VMName
$data = ConvertTo-GuestData @{ Old = $OriginalIP.IPAddressToString; New = $NewIP.IPAddressToString; Mask = $SubnetMask.IPAddressToString; Gateway = $Gateway.IPAddressToString; Dns = $DnsServer.IPAddressToString }
$scriptText = @'
$ErrorActionPreference = 'Stop'
$config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('DATA')) | ConvertFrom-Json
$addresses = @(Get-NetIPAddress -AddressFamily IPv4)
$current = @($addresses | Where-Object IPAddress -eq $config.Old)
if ($current.Count -ne 1) { throw 'Expected exactly one interface with the original address.' }
if ($config.Old -ne $config.New -and $addresses.IPAddress -contains $config.New) { throw 'Replacement address is already present.' }
$index = $current[0].InterfaceIndex
netsh.exe interface ipv4 set address "name=$index" source=static "address=$($config.New)" "mask=$($config.Mask)" "gateway=$($config.Gateway)" store=persistent
if ($LASTEXITCODE -ne 0) { throw "Address change failed ($LASTEXITCODE)." }
if (!(Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 | Where-Object IPAddress -eq $config.New)) { throw 'New address was not applied.' }
Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $config.Dns
Register-DnsClient
'@
$result = Invoke-VMScript -VM $vm -GuestCredential $GuestCredential -ScriptType Powershell -ScriptText $scriptText.Replace('DATA', $data)
if ($result.ExitCode -ne 0) { throw "Network update failed on $VMName. $($result.ScriptOutput)" }
