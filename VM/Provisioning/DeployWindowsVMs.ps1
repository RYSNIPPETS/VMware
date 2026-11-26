<#
.SYNOPSIS
Clones a Windows VM and applies a per-VM customization specification.
.DESCRIPTION
Uses an existing vCenter connection or the supplied vCenter credential. Static IPv4 and domain membership are applied by guest customization. Optional firewall changes require the guest credential.
#>
[CmdletBinding()]
param(
    [Alias('vCenterInstance')][string]$Server,
    [pscredential]$vCenterCredential,
    [ValidatePattern('^(?!-)[A-Za-z0-9-]{1,15}(?<!-)$')][string]$Hostname,
    [string]$Cluster,
    [string]$VMTemplate,
    [string]$CustomSpec,
    [string]$Location,
    [string]$Datastore,
    [ValidateSet('Thin', 'Thick', 'EagerZeroedThick')][string]$DiskStorageFormat = 'Thin',
    [string]$NetworkName,
    [int]$CPU,
    [decimal]$Memory,
    [decimal]$DiskCapacity,
    [int]$NicPosition = 1,
    [ipaddress]$IP,
    [ValidateRange(1, 32)][int]$SubnetLength = 24,
    [ipaddress]$GW,
    [ipaddress[]]$IP_DNS,
    [string]$Domain,
    [pscredential]$DomainCredential,
    [pscredential]$VMLocalCredential,
    [switch]$EnableRemoteDesktop,
    [switch]$EnableFileSharing,
    [ValidateRange(1, 86400)][int]$TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
if (!$Hostname -or !$Cluster -or !$VMTemplate -or !$CustomSpec -or !$Location -or !$Datastore -or !$NetworkName -or $CPU -lt 1 -or $Memory -le 0 -or $DiskCapacity -le 0 -or $NicPosition -lt 1) {
    throw 'Supply the VM name, template, customization spec, cluster, folder, datastore, network, CPU, memory and disk capacity.'
}
if ([bool]$Domain -ne [bool]$DomainCredential) { throw 'Supply -Domain and -DomainCredential together.' }
if (($EnableRemoteDesktop -or $EnableFileSharing) -and !$VMLocalCredential) { throw 'Supply -VMLocalCredential for requested guest firewall changes.' }
if ($IP -and (!$GW -or !$IP_DNS -or (@($IP, $GW) + $IP_DNS | Where-Object AddressFamily -NE InterNetwork))) { throw 'Static IPv4 requires an IPv4 address, gateway and DNS server addresses.' }
if (!$IP -and ($GW -or $IP_DNS)) { throw 'Supply -IP for a static configuration.' }
if ($vCenterCredential) {
    if (!$Server -or [WildcardPattern]::ContainsWildcardCharacters($Server)) { throw 'Specify an exact -Server with -vCenterCredential.' }
    $connection = Connect-VIServer -Server $Server -Credential $vCenterCredential -NotDefault -Force
    $Server = $connection.Name
}
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
Assert-VMNameAvailable $Hostname
$clusterObject = Get-SingleItem @(Get-Cluster -Server $Server -Name ([WildcardPattern]::Escape($Cluster)) | Where-Object Name -EQ $Cluster) 'cluster'
$template = Get-SingleItem @(Get-Template -Server $Server -Name ([WildcardPattern]::Escape($VMTemplate)) | Where-Object Name -EQ $VMTemplate) 'template'
$store = Get-SingleItem @(Get-Datastore -Server $Server -Name ([WildcardPattern]::Escape($Datastore)) | Where-Object Name -EQ $Datastore) 'datastore'
$folder = Get-SingleItem @(Get-Folder -Server $Server -Type VM -Name ([WildcardPattern]::Escape($Location)) | Where-Object Name -EQ $Location) 'VM folder'
$sourceSpec = Get-SingleItem @(Get-OSCustomizationSpec -Server $Server -Name ([WildcardPattern]::Escape($CustomSpec)) | Where-Object Name -EQ $CustomSpec) 'customization specification'
$spec = New-OSCustomizationSpec -Server $Server -OSCustomizationSpec $sourceSpec -Type NonPersistent
$identity = @{ NamingScheme = 'Fixed'; NamingPrefix = $Hostname }
if ($Domain) { $identity.Domain = $Domain; $identity.DomainCredentials = $DomainCredential }
else { $identity.Workgroup = 'WORKGROUP' }
$spec = Set-OSCustomizationSpec -OSCustomizationSpec $spec @identity -Confirm:$false
$mapping = Get-SingleItem @($spec | Get-OSCustomizationNicMapping | Where-Object Position -EQ $NicPosition) 'customization NIC mapping'
$nicSettings = @{ IpMode = 'UseDhcp' }
if ($IP) {
    $mask = [uint32]::MaxValue -shl (32 - $SubnetLength)
    $maskBytes = [BitConverter]::GetBytes([uint32]$mask)
    if ([BitConverter]::IsLittleEndian) { [array]::Reverse($maskBytes) }
    $nicSettings = @{ IpMode = 'UseStaticIP'; IpAddress = $IP.IPAddressToString; SubnetMask = ([ipaddress]::new($maskBytes)).IPAddressToString; DefaultGateway = $GW.IPAddressToString; Dns = $IP_DNS.IPAddressToString }
}
$mapping | Set-OSCustomizationNicMapping @nicSettings -Confirm:$false | Out-Null
$vm = New-VM -Server $Server -Name $Hostname -Template $template -ResourcePool $clusterObject -Location $folder -Datastore $store -DiskStorageFormat $DiskStorageFormat -OSCustomizationSpec $spec -ErrorAction Stop
if (!$vm.Id) { throw 'Clone did not return a VM identity.' }
$nics = @(Get-NetworkAdapter -VM $vm | Sort-Object { $_.ExtensionData.Key })
if ($nics.Count -lt $NicPosition) { throw "The clone has no NIC at position $NicPosition." }
Set-NetworkAdapter -NetworkAdapter $nics[$NicPosition - 1] -NetworkName $NetworkName -Confirm:$false | Out-Null
Set-VM -VM $vm -NumCpu $CPU -MemoryGB $Memory -Confirm:$false | Out-Null
$disk = Get-SingleItem @(Get-HardDisk -VM $vm | Where-Object Name -EQ 'Hard disk 1') 'system VMDK'
if ($disk.CapacityGB -gt $DiskCapacity) { throw 'Requested system disk size would shrink the cloned disk.' }
if ($disk.CapacityGB -lt $DiskCapacity) { Set-HardDisk -HardDisk $disk -CapacityGB $DiskCapacity -Confirm:$false | Out-Null }
$start = Get-Date
Start-VM -VM $vm -Confirm:$false | Out-Null
$deadline = $start.AddSeconds($TimeoutSeconds)
do {
    $events = @(Get-VIEvent -Server $Server -Entity $vm -Start $start)
    if ($events | Where-Object { $_ -is [VMware.Vim.CustomizationFailed] }) { throw "Guest customization failed on $Hostname." }
    if ($events | Where-Object { $_ -is [VMware.Vim.CustomizationSucceeded] }) { break }
    if ((Get-Date) -ge $deadline) { throw "Timed out waiting for customization on $Hostname." }
    Start-Sleep -Seconds 5
} while ($true)
if ($EnableRemoteDesktop -or $EnableFileSharing) {
    $ready = Wait-Tools -VM $vm -TimeoutSeconds $TimeoutSeconds
    if (!$ready) { throw "VMware Tools did not become ready on $Hostname." }
    $steps = @(
        '$ErrorActionPreference = "Stop"'
        if ($EnableRemoteDesktop) {
            'Set-ItemProperty -LiteralPath "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name UserAuthentication -Value 1'
            'Set-ItemProperty -LiteralPath "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -Value 0'
            'Enable-NetFirewallRule -DisplayGroup "Remote Desktop"'
        }
        if ($EnableFileSharing) { 'Enable-NetFirewallRule -DisplayGroup "File and Printer Sharing"' }
    )
    $result = Invoke-VMScript -VM $vm -GuestCredential $VMLocalCredential -ScriptType Powershell -ScriptText ($steps -join [Environment]::NewLine)
    if ($result.ExitCode -ne 0) { throw "Guest configuration failed on $Hostname. $($result.ScriptOutput)" }
}
$vm
