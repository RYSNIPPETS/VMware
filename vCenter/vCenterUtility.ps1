<#
.SYNOPSIS
Runs one of the domain migration utility actions on the selected vCenter.
.EXAMPLE
./vCenterUtility.ps1 -Action 91a -Server vc.example.org -VMName web01
.EXAMPLE
./vCenterUtility.ps1 -Action 11b -Server vc.example.org -VMListPath ./VMList.txt -GuestCredential $localAdmin
#>
[CmdletBinding()]
param(
    [ValidateSet('1', '2', '3', '4', '11a', '11b', '12a', '12b', '13a', '21a', '21b', '22a', '22b', '23a', '23b', '24a', '24b', '25a', '25b', '31a', '31b', '32a', '32b', '41a', '41b', '42a', '42b', '43a', '43b', '44a', '44b', '44c', '51a', '51b', '52a', '52b', '61a', '61b', '62a', '62b', '64a', '64b', '65a', '65b', '71a', '71b', '72a', '72b', '81a', '81b', '91a', '91b', '92a', '92b', '101a', '101b', '102a', '103a', '104a', '105a', '111a', '111b', '112a', '112b', '121a', '121b', '122a', '122b', '48a', '48b', 'help', 'q')][string]$Action = 'help',
    $Server,
    [string]$VMName,
    [string]$VMListPath = (Join-Path $PSScriptRoot 'VMList.txt'),
    [Alias("GuestCreds")][pscredential]$GuestCredential,
    [Alias("ADMTCreds")][pscredential]$DomainCredential,
    [pscredential]$vCenterCredential,
    [ValidatePattern('^[a-zA-Z0-9.-]+$')][string]$Domain,
    [ValidatePattern('^[a-zA-Z0-9.-]+$')][string]$DC,
    [ipaddress]$DCIP,
    [ipaddress]$PrimaryDnsServer,
    [ipaddress]$SecondaryDnsServer,
    [string]$ServiceAccountMatch
)

$ErrorActionPreference = 'Stop'

$GuestCreds = $GuestCredential
$ADMTCreds = $DomainCredential
$accountData = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$DomainCredential.UserName))
$serviceData = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$ServiceAccountMatch))
$PingDC = "ping $DC.$Domain"
$PingDCIP = "ping $DCIP"
$UsersInGroup = @'
if (Get-Command -Name Get-LocalGroupMember -ErrorAction SilentlyContinue) {
    Get-LocalGroupMember -Group 'Administrators' |
        Select-Object Name, ObjectClass, PrincipalSource |
        Sort-Object Name |
        Format-Table -AutoSize | Out-String
}
else {
    ([ADSI]'WinNT://./Administrators,group').psbase.Invoke('Members') |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.GetType().InvokeMember('Name', 'GetProperty', $null, $_, $null)
                Path = $_.GetType().InvokeMember('AdsPath', 'GetProperty', $null, $_, $null)
            }
        } |
        Sort-Object Name |
        Format-Table -AutoSize | Out-String
}
'@
$Add2GroupCD = $null
$GetDomainOnVM = @'
if (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue) {
    (Get-CimInstance -ClassName Win32_ComputerSystem).Domain
}
else {
    (Get-WmiObject -Class Win32_ComputerSystem).Domain
}
'@
$GetDNSAddress = @'
if (Get-Command -Name Get-DnsClientServerAddress -ErrorAction SilentlyContinue) {
    Get-DnsClientServerAddress -AddressFamily IPv4 |
        Where-Object { $_.ServerAddresses } |
        Select-Object InterfaceAlias, @{ Name = 'ServerAddresses'; Expression = { $_.ServerAddresses -join ', ' } } |
        Format-Table -AutoSize | Out-String
}
else {
    Get-WmiObject -Class Win32_NetworkAdapterConfiguration |
        Where-Object { $_.IPEnabled -and $_.DNSServerSearchOrder } |
        Select-Object Description, @{ Name = 'ServerAddresses'; Expression = { $_.DNSServerSearchOrder -join ', ' } } |
        Format-Table -AutoSize | Out-String
}
'@
$SetDNSAddress = @"
`$dnsServers = @('$PrimaryDnsServer', '$SecondaryDnsServer')
if (Get-Command -Name Set-DnsClientServerAddress -ErrorAction SilentlyContinue) {
    `$adapterIndexes = Get-DnsClientServerAddress -AddressFamily IPv4 |
        Where-Object { `$_.InterfaceAlias -notmatch 'Loopback|isatap|Teredo' } |
        Select-Object -ExpandProperty InterfaceIndex -Unique
    if (-not `$adapterIndexes) {
        throw 'No compatible IPv4 adapters were found.'
    }
    foreach (`$adapterIndex in `$adapterIndexes) {
        Set-DnsClientServerAddress -InterfaceIndex `$adapterIndex -ServerAddresses `$dnsServers -ErrorAction Stop
    }
    Get-DnsClientServerAddress -AddressFamily IPv4 |
        Where-Object { `$_.InterfaceIndex -in `$adapterIndexes } |
        Select-Object InterfaceAlias, @{ Name = 'ServerAddresses'; Expression = { `$_.ServerAddresses -join ', ' } } |
        Format-Table -AutoSize | Out-String
}
else {
    `$adapters = Get-WmiObject -Class Win32_NetworkAdapterConfiguration | Where-Object { `$_.IPEnabled }
    if (-not `$adapters) {
        throw 'No IP-enabled adapters were found.'
    }
    foreach (`$adapter in `$adapters) {
        `$result = `$adapter.SetDNSServerSearchOrder(`$dnsServers)
        if (`$result.ReturnValue -notin 0, 1) {
            throw \"SetDNSServerSearchOrder failed with code `$(`$result.ReturnValue).\"
        }
    }
    `$adapters |
        Select-Object Description, @{ Name = 'ServerAddresses'; Expression = { `$_.DNSServerSearchOrder -join ', ' } } |
        Format-Table -AutoSize | Out-String
}
"@
$RegisterDNS = @'
if (Get-Command -Name Register-DnsClient -ErrorAction SilentlyContinue) {
    Register-DnsClient | Out-Null
    'DNS registration initiated.'
}
else {
    ipconfig /registerdns | Out-String
}
'@
$GetSvcOnVM = @'
$services = if (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue) {
    Get-CimInstance -ClassName Win32_Service
}
else {
    Get-WmiObject -Class Win32_Service
}
$services |
    Sort-Object Name |
    Select-Object Name, StartName |
    Format-Table -AutoSize | Out-String
'@
$GetDomainSvc = @"
`$serviceAccountMatch = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$serviceData'))
`$services = if (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue) {
    Get-CimInstance -ClassName Win32_Service
}
else {
    Get-WmiObject -Class Win32_Service
}
`$services |
    Where-Object { `$_.StartName -and `$_.StartName -match [regex]::Escape(`$serviceAccountMatch) } |
    Sort-Object StartName |
    Select-Object Name, StartName |
    Format-Table -AutoSize | Out-String
"@
$FWStatus = @'
if (Get-Command -Name Get-NetFirewallProfile -ErrorAction SilentlyContinue) {
    Get-NetFirewallProfile |
        Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction |
        Format-Table -AutoSize | Out-String
}
else {
    netsh advfirewall show allprofiles state | Out-String
}
'@
$FWDisable = @'
if (Get-Command -Name Set-NetFirewallProfile -ErrorAction SilentlyContinue) {
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
    Get-NetFirewallProfile |
        Select-Object Name, Enabled |
        Format-Table -AutoSize | Out-String
}
else {
    netsh advfirewall set allprofiles state off | Out-String
}
'@
$TestADMTPortsScript = @"
function Test-GuestTcpPort {
    param(
        [Parameter(Mandatory)][string]`$ComputerName,
        [Parameter(Mandatory)][int]`$Port,
        [int]`$TimeoutMilliseconds = 2000
    )

    `$client = [System.Net.Sockets.TcpClient]::new()
    try {
        `$async = `$client.BeginConnect(`$ComputerName, `$Port, `$null, `$null)
        if (-not `$async.AsyncWaitHandle.WaitOne(`$TimeoutMilliseconds, `$false)) {
            return `$false
        }

        `$client.EndConnect(`$async)
        return `$true
    }
    catch {
        return `$false
    }
    finally {
        `$client.Dispose()
    }
}

`$target = '$DCIP'
([ordered]@{
    DNS      = 53
    Kerberos = 88
    RPC      = 135
    LDAP     = 389
    SMB      = 445
    GC       = 3268
}).GetEnumerator() |
    ForEach-Object {
        [pscustomobject]@{
            Target   = `$target
            PortName = `$_.Key
            Port     = `$_.Value
            Open     = Test-GuestTcpPort -ComputerName `$target -Port `$_.Value
        }
    } |
    Format-Table -AutoSize | Out-String
"@
$Add2GroupCD = @"
`$memberName = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$accountData'))
if (Get-Command -Name Add-LocalGroupMember -ErrorAction SilentlyContinue) {
    `$memberExists = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
        Where-Object { `$_.Name -eq `$memberName }
    if (-not `$memberExists) {
        Add-LocalGroupMember -Group 'Administrators' -Member `$memberName -ErrorAction Stop
    }
}
else {
    net localgroup Administrators "`$memberName" /add | Out-Null
}
"`$memberName is a member of the local Administrators group."
"@
function Join-GuestDomain {
    param($VM, [string]$Domain, [pscredential]$GuestCredential, [pscredential]$DomainCredential)
    $guestName = $VM.ExtensionData.Guest.HostName
    $uuid = $VM.ExtensionData.Config.Uuid
    if (!$guestName -or !$uuid) { throw "Missing guest DNS name or BIOS UUID for $($VM.Name)." }
    $joinScript = {
        param([string]$Domain, [pscredential]$JoinCredential, [guid]$Uuid)
        $ErrorActionPreference = 'Stop'
        $actual = [guid](Get-CimInstance Win32_ComputerSystemProduct).UUID
        $raw = $Uuid.ToString('N')
        $bytes = for ($i = 0; $i -lt 32; $i += 2) { [Convert]::ToByte($raw.Substring($i, 2), 16) }
        if ($actual -ne $Uuid -and $actual -ne [guid]::new([byte[]]$bytes)) { throw 'Guest BIOS UUID does not match the selected VM.' }
        $computer = Get-CimInstance Win32_ComputerSystem
        if ($computer.PartOfDomain -and $computer.Domain -eq $Domain) { return }
        $joined = Add-Computer -DomainName $Domain -Credential $JoinCredential -Force -PassThru -ErrorAction Stop
        if (!$joined.HasSucceeded) { throw 'Domain join failed.' }
        shutdown.exe /r /t 10
        if ($LASTEXITCODE -ne 0) { throw "Joined domain but could not schedule reboot ($LASTEXITCODE)." }
    }
    Invoke-Command -ComputerName $guestName -UseSSL -ConfigurationName Microsoft.PowerShell -Credential $GuestCredential -ArgumentList $Domain, $DomainCredential, $uuid -ErrorAction Stop -ScriptBlock $joinScript
}

function Get-ExactVM {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'A VM name is required.' }
    $matchesFound = @(Get-VM -Server $Server -Name ([WildcardPattern]::Escape($Name)) | Where-Object Name -EQ $Name)
    if ($matchesFound.Count -ne 1) { throw "Expected one VM named '$Name' on '$Server'. Found $($matchesFound.Count)." }
    $matchesFound[0]
}

function Invoke-CheckedGuestScript {
    param($VM, [pscredential]$GuestCredential, [string]$ScriptType, [string]$ScriptText)
    if (!$GuestCredential) { throw 'Supply -GuestCredential for this guest operation.' }
    $prefix = '$ErrorActionPreference = "Stop"; $LASTEXITCODE = 0' + [Environment]::NewLine
    $suffix = [Environment]::NewLine + 'if ($LASTEXITCODE) { exit $LASTEXITCODE }'
    $result = Invoke-VMScript -VM $VM -GuestCredential $GuestCredential -ScriptType $ScriptType -ScriptText ($prefix + $ScriptText + $suffix) -ErrorAction Stop
    if ($null -eq $result.ExitCode -or $result.ExitCode -ne 0) { throw "Guest operation failed on $($VM.Name): $($result.ScriptOutput)" }
    $result
}

function Update-EligibleVMTool($Target) {
    $guest = $Target.ExtensionData.Guest
    if ($Target.PowerState -eq 'PoweredOn' -and $guest.ToolsRunningStatus -eq 'guestToolsRunning' -and
        $guest.ToolsVersionStatus2 -in 'guestToolsNeedUpgrade', 'guestToolsSupportedOld', 'guestToolsTooOld', 'guestToolsBlacklisted') {
        Update-Tools -VM $Target -NoReboot
    }
}

function Show-Menu {
    param (
        [string]$Title = 'Domain Migration Utility v1.4'
    )
    Write-Output "================ $Title ================"

    Write-Output "VCENTER AND VM LIST"
    Write-Output "1: connect to vCenter."
    Write-Output "2: disconnect from vCenter."
    Write-Output "3: show VMs in list."
    Write-Output "4: see if VMs are in vCenter."

    Write-Output "VMWARE TOOLS STATUS"
    Write-Output "91a: check VMware Tools on specific VM."
    Write-Output "91b: check VMware Tools on each VM."
    Write-Output "92a: update VMware Tools on specific VM."
    Write-Output "92b: update VMware Tools on each VM."

    Write-Output "VM POWER AND REBOOT"
    Write-Output "101a: check Power Status on specific VM."
    Write-Output "101b: check Power Status on each VM."
    Write-Output "102a: reboot a specific VM."
    Write-Output "103a: power on a specific VM."
    Write-Output "104a: shutdown a specific VM."
    Write-Output "105a: power off a specific VM."

    Write-Output "VM CPU AND MEMORY"
    Write-Output "121a: get weekly CPU and Memory usage report on specific VM."
    Write-Output "121b: get weekly CPU and Memory usage report on each VM."
    Write-Output "122a: get monthly CPU and Memory usage report on specific VM."
    Write-Output "122b: get monthly CPU and Memory usage report on each VM."

    Write-Output "WINDOWS ADMIN ACCOUNTS"
    Write-Output "11a: show users in Admins group on specific VM."
    Write-Output "11b: show users in Admins group on each VM."
    Write-Output "12a: add ADMT account to Admins group on specific VM."
    Write-Output "12b: add ADMT account to Admins group on each VM."
    Write-Output "13a: test authentication of ADMT account."

    Write-Output "WINDOWS SERVICES"
    Write-Output "31a: get all services on specific VM."
    Write-Output "31b: get all services on each VM."
    Write-Output "32a: check for a specific Service on specific VM."
    Write-Output "32b: check for a specific Service on each VM."

    Write-Output "IP AND DNS ADDRESSES"
    Write-Output "21a: get IP Address for specific VM."
    Write-Output "21b: get IP Address for each VM."
    Write-Output "22a: get the current Domain for specific VM."
    Write-Output "22b: get the current Domain for each VM."
    Write-Output "23a: get DNS Server Address on specific VM."
    Write-Output "23b: get DNS Server Address for each VM."
    Write-Output "24a: set the DNS Server Address on specific VM."
    Write-Output "24b: set the DNS Server Address on each VM."
    Write-Output "25a: register DNS on specific VM."
    Write-Output "25b: register DNS on each VM."

    Write-Output "NETWORK CONNECTIVITY"
    Write-Output "41a: ping ComputerName of specific VM."
    Write-Output "41b: ping ComputerName of each VM."
    Write-Output "42a: ping IP Address of specific VM."
    Write-Output "42b: ping IP Address of each VM."
    Write-Output "43a: ping the Admin share on specific VM."
    Write-Output "43b: ping the Admin share on each VM."
    Write-Output "44a: test reachability of DC from specific VM."
    Write-Output "44b: test reachability of DC from each VM."
    Write-Output "44c: test reachability of DC IP from each VM."
    Write-Output "48a: check ADMT ports on specific VM."
    Write-Output "48b: check ADMT ports on each VM."

    Write-Output "WINDOWS FIREWALL"
    Write-Output "51a: get status of Windows Firewall on specific VM."
    Write-Output "51b: get status of Windows Firewall on each VM."
    Write-Output "52a: disable Windows Firewall on specific VM."
    Write-Output "52b: disable Windows Firewall on each VM."

    Write-Output "BACKUP POLICY"
    Write-Output "61a: check Backup Policy on specific VM is set to Exclude."
    Write-Output "61b: check Backup Policy on each VM is set to Exclude."
    Write-Output "62a: check Backup Policy on specific VM is set to Snapshot."
    Write-Output "62b: check Backup Policy on each VM is set to Snapshot."
    Write-Output "64a: set Backup Policy to Exclude on specific VM."
    Write-Output "64b: set Backup Policy to Exclude on each VM."
    Write-Output "65a: set Backup Policy to Snapshot on specific VM."
    Write-Output "65b: set Backup Policy to Snapshot on each VM."

    Write-Output "MANUAL MOVES"
    Write-Output "81a: manually move specific VM to new domain."
    Write-Output "81b: manually move each VM to new domain."

    Write-Output "SNAPSHOTS"
    Write-Output "71a: take Snapshot of specific VM."
    Write-Output "71b: take Snapshot of each VM."
    Write-Output "72a: remove all Snapshots of specific VM."
    Write-Output "72b: remove all Snapshots of each VM."

    Write-Output "VMOTION"
    Write-Output "111a: get 24-hours of VMotion events of specific VM."
    Write-Output "111b: get 24-hours of VMotion events of each VM."
    Write-Output "112a: get 1-week of VMotion events of specific VM."
    Write-Output "112b: get 1-week of VMotion events of each VM."

}

<# VCENTER AND LIST VERIFICATION #>
function Connect-2vCenter {
    Connect-VIServer -Server $Server -Credential $vCenterCredential -Force -ErrorAction Stop
}

function Get-PrimaryIPv4Address {
    param (
        [Parameter(Mandatory)]
        $VMName
    )

    $guestInfo = Get-VMGuest -VM $VMName -ErrorAction Stop
    $ipAddress = $guestInfo.IPAddress |
        Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } |
        Select-Object -First 1

    if (-not $ipAddress) {
        throw "Unable to determine an IPv4 address for $VMName. Verify VMware Tools is running and the guest has an IPv4 address."
    }

    $ipAddress
}

function Test-TcpPort {
    param (
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [int]$Port,

        [int]$TimeoutMilliseconds = 2000
    )

    $client = [System.Net.Sockets.TcpClient]::new()

    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }

        $client.EndConnect($async)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Show-AdminShareStatus {
    param (
        [Parameter(Mandatory)]
        [string]$ComputerName
    )

    if ($env:OS -eq 'Windows_NT') {
        if (Test-Path "\\$ComputerName\Admin$") {
            Write-Output "Admin share is reachable on $ComputerName"
        }
        else {
            Write-Output "Admin share is not reachable on $ComputerName"
        }

        return
    }

    if (Test-TcpPort -ComputerName $ComputerName -Port 445) {
        Write-Output "TCP 445 is reachable on $ComputerName. Share-level validation requires a Windows host."
    }
    else {
        Write-Output "TCP 445 is not reachable on $ComputerName"
    }
}

function Get-LocationOfVM {
    $found = @(Get-VM -Name ([WildcardPattern]::Escape($VM)) -Server $Server -ErrorAction SilentlyContinue | Where-Object Name -EQ $VM)
    [pscustomobject]@{VM = $VM; Server = [string]$Server; Matches = $found.Count }
}

<# VM CPU AND MEMORY #>
function Get-WeeklyCPURAM4VM {
    Write-Verbose "Getting CPU and Memory Weekly Usage Report for $TargetVM"
    $AllVMs = @()
    $TargetVM | ForEach-Object {
        $vmstat = '' | Select-Object VmName, CPUMin, CPUAvg, CPUMax, MemMin, MemAvg, MemMax
        $vmstat.VmName = "$TargetVM"
        $statcpuweek = Get-Stat -Server $Server -Instance '' -Entity ($TargetVM) -Start (Get-Date).AddDays(-7) -Finish (Get-Date) -MaxSamples 100 -Stat cpu.usage.average
        $statmemweek = Get-Stat -Server $Server -Instance '' -Entity ($TargetVM) -Start (Get-Date).AddDays(-7) -Finish (Get-Date) -MaxSamples 100 -Stat mem.usage.average
        $cpuweek = $statcpuweek | Measure-Object -Property Value -Average -Maximum -Minimum
        $memweek = $statmemweek | Measure-Object -Property Value -Average -Maximum -Minimum
        $vmstat.CPUMax = if ($cpuweek.Count) { [math]::Round($cpuweek.Maximum) }
        $vmstat.CPUAvg = if ($cpuweek.Count) { [math]::Round($cpuweek.Average) }
        $vmstat.CPUMin = if ($cpuweek.Count) { [math]::Round($cpuweek.Minimum) }
        $vmstat.MemMax = if ($memweek.Count) { [math]::Round($memweek.Maximum) }
        $vmstat.MemAvg = if ($memweek.Count) { [math]::Round($memweek.Average) }
        $vmstat.MemMin = if ($memweek.Count) { [math]::Round($memweek.Minimum) }
        $AllVMs += $vmstat
    }
    $AllVMs | Select-Object VmName, CPUMin, CPUAvg, CPUMax, MemMin, MemAvg, MemMax
}

function Get-WeeklyCPURAM4All {
    Write-Verbose "Getting CPU and Memory Weekly Usage Report for $VM"
    $AllVMs = @()
    $VM | ForEach-Object {
        $vmstat = '' | Select-Object VmName, CPUMin, CPUAvg, CPUMax, MemMin, MemAvg, MemMax
        $vmstat.VmName = "$VM"
        $statcpuweek = Get-Stat -Server $Server -Instance '' -Entity ($VM) -Start (Get-Date).AddDays(-7) -Finish (Get-Date) -MaxSamples 100 -Stat cpu.usage.average
        $statmemweek = Get-Stat -Server $Server -Instance '' -Entity ($VM) -Start (Get-Date).AddDays(-7) -Finish (Get-Date) -MaxSamples 100 -Stat mem.usage.average
        $cpuweek = $statcpuweek | Measure-Object -Property Value -Average -Maximum -Minimum
        $memweek = $statmemweek | Measure-Object -Property Value -Average -Maximum -Minimum
        $vmstat.CPUMax = if ($cpuweek.Count) { [math]::Round($cpuweek.Maximum) }
        $vmstat.CPUAvg = if ($cpuweek.Count) { [math]::Round($cpuweek.Average) }
        $vmstat.CPUMin = if ($cpuweek.Count) { [math]::Round($cpuweek.Minimum) }
        $vmstat.MemMax = if ($memweek.Count) { [math]::Round($memweek.Maximum) }
        $vmstat.MemAvg = if ($memweek.Count) { [math]::Round($memweek.Average) }
        $vmstat.MemMin = if ($memweek.Count) { [math]::Round($memweek.Minimum) }
        $AllVMs += $vmstat
    }
    $AllVMs | Select-Object VmName, CPUMin, CPUAvg, CPUMax, MemMin, MemAvg, MemMax
}

function Get-MonthlyCPURAM4VM {
    Write-Verbose "Getting CPU and Memory Monthly Usage Report for $TargetVM"
    $AllVMs = @()
    $TargetVM | ForEach-Object {
        $vmstat = '' | Select-Object VmName, CPUMin, CPUAvg, CPUMax, MemMin, MemAvg, MemMax
        $vmstat.VmName = "$TargetVM"
        $statcpumonth = Get-Stat -Server $Server -Instance '' -Entity ($TargetVM) -Start (Get-Date).AddDays(-30) -Finish (Get-Date) -MaxSamples 1000 -Stat cpu.usage.average
        $statmemmonth = Get-Stat -Server $Server -Instance '' -Entity ($TargetVM) -Start (Get-Date).AddDays(-30) -Finish (Get-Date) -MaxSamples 1000 -Stat mem.usage.average
        $cpumonth = $statcpumonth | Measure-Object -Property value -Average -Maximum -Minimum
        $memmonth = $statmemmonth | Measure-Object -Property value -Average -Maximum -Minimum
        $vmstat.CPUMax = if ($cpumonth.Count) { [math]::Round($cpumonth.Maximum) }
        $vmstat.CPUAvg = if ($cpumonth.Count) { [math]::Round($cpumonth.Average) }
        $vmstat.CPUMin = if ($cpumonth.Count) { [math]::Round($cpumonth.Minimum) }
        $vmstat.MemMax = if ($memmonth.Count) { [math]::Round($memmonth.Maximum) }
        $vmstat.MemAvg = if ($memmonth.Count) { [math]::Round($memmonth.Average) }
        $vmstat.MemMin = if ($memmonth.Count) { [math]::Round($memmonth.Minimum) }
        $AllVMs += $vmstat
    }
    $AllVMs | Select-Object VmName, CPUMin, CPUAvg, CPUMax, MemMin, MemAvg, MemMax
}

function Get-MonthlyCPURAM4All {
    Write-Verbose "Getting CPU and Memory Monthly Usage Report for $VM"
    $AllVMs = @()
    $VM | ForEach-Object {
        $vmstat = '' | Select-Object VmName, CPUMin, CPUAvg, CPUMax, MemMin, MemAvg, MemMax
        $vmstat.VmName = "$VM"
        $statcpumonth = Get-Stat -Server $Server -Instance '' -Entity ($VM) -Start (Get-Date).AddDays(-30) -Finish (Get-Date) -MaxSamples 1000 -Stat cpu.usage.average
        $statmemmonth = Get-Stat -Server $Server -Instance '' -Entity ($VM) -Start (Get-Date).AddDays(-30) -Finish (Get-Date) -MaxSamples 1000 -Stat mem.usage.average
        $cpumonth = $statcpumonth | Measure-Object -Property value -Average -Maximum -Minimum
        $memmonth = $statmemmonth | Measure-Object -Property value -Average -Maximum -Minimum
        $vmstat.CPUMax = if ($cpumonth.Count) { [math]::Round($cpumonth.Maximum) }
        $vmstat.CPUAvg = if ($cpumonth.Count) { [math]::Round($cpumonth.Average) }
        $vmstat.CPUMin = if ($cpumonth.Count) { [math]::Round($cpumonth.Minimum) }
        $vmstat.MemMax = if ($memmonth.Count) { [math]::Round($memmonth.Maximum) }
        $vmstat.MemAvg = if ($memmonth.Count) { [math]::Round($memmonth.Average) }
        $vmstat.MemMin = if ($memmonth.Count) { [math]::Round($memmonth.Minimum) }
        $AllVMs += $vmstat
    }
    $AllVMs | Select-Object VmName, CPUMin, CPUAvg, CPUMax, MemMin, MemAvg, MemMax
}

<# WINDOWS ADMIN ACCOUNTS #>
function Get-UsersInAdminGroup {
    Write-Verbose "Getting users in Administrators group on $TargetVM"
    $SO = Invoke-CheckedGuestScript -VM ($TargetVM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $UsersInGroup
    $SO.ScriptOutput
}

function Get-UsersInAdminGroupAll {
    Write-Verbose "Getting users in Administrators group on $VM"
    $SO = Invoke-CheckedGuestScript -VM ($VM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $UsersInGroup
    $SO.ScriptOutput
}

function Add-Account2Group {
    Write-Output "Adding $ADMTAccount to Administrators group on $TargetVM"
    $SO = Invoke-CheckedGuestScript -VM ($TargetVM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $Add2GroupCD
    $SO.ScriptOutput
}

function Add-Account2GroupAll {
    Write-Output "Adding $ADMTAccount to Administrators group on $VM"
    $SO = Invoke-CheckedGuestScript -VM ($VM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $Add2GroupCD
    $SO.ScriptOutput
}

function Test-ADAuthentication {
    Write-Verbose "Testing ADMT authentication against $DCIP"

    $targetDirectoryServer = if ([string]::IsNullOrWhiteSpace($DCIP)) {
        "$DC.$Domain"
    }
    else {
        $DCIP
    }

    $ldapConnection = $null

    try {
        $directoryIdentifier = [System.DirectoryServices.Protocols.LdapDirectoryIdentifier]::new($targetDirectoryServer, 389, $false, $false)
        $ldapConnection = [System.DirectoryServices.Protocols.LdapConnection]::new($directoryIdentifier)
        $ldapConnection.AuthType = [System.DirectoryServices.Protocols.AuthType]::Negotiate
        $ldapConnection.SessionOptions.ProtocolVersion = 3
        $ldapConnection.Credential = $ADMTCreds.GetNetworkCredential()
        $ldapConnection.Bind()

        Write-Output "ADMT authentication succeeded."
        $true
    }
    catch {
        Write-Warning "ADMT authentication failed: $($_.Exception.Message)"
        $false
    }
    finally {
        if ($null -ne $ldapConnection) {
            $ldapConnection.Dispose()
        }
    }
}

<# IP AND DNS ADDRESSES #>
function Get-IPAddress4VM {
    Write-Verbose "Getting IP of $TargetVM"
    Get-PrimaryIPv4Address -VMName $TargetVM
}
function Get-IPAddress4VMAll {
    Write-Verbose "Getting IP of $VM"
    Get-PrimaryIPv4Address -VMName $VM
}

function Get-DomainOnVM {
    Write-Verbose "Getting Domain of $TargetVM"
    $SO = Invoke-CheckedGuestScript -VM ($TargetVM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $GetDomainOnVM
    $SO.ScriptOutput
}

function Get-DomainOnVMAll {
    Write-Verbose "Getting Domain of $VM"
    $SO = Invoke-CheckedGuestScript -VM ($VM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $GetDomainOnVM
    $SO.ScriptOutput
}

function Get-DNSServerAddress {
    Write-Verbose "Getting DNS Server Address on $TargetVM"
    $SO = Invoke-CheckedGuestScript -VM ($TargetVM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $GetDNSAddress
    $SO.ScriptOutput
}

function Get-DNSServerAddressAll {
    Write-Verbose "Getting DNS Server Address on $VM"
    $SO = Invoke-CheckedGuestScript -VM ($VM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $GetDNSAddress
    $SO.ScriptOutput
}

function Set-DNSServerAddress {
    Write-Verbose "Setting DNS Server Addresses on $TargetVM..."
    $SO = Invoke-CheckedGuestScript -VM ($TargetVM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $SetDNSAddress
    $SO.ScriptOutput
    Write-Output "DNS Server Addresses on $TargetVM have been updated."
}

function Set-DNSServerAddressAll {
    Write-Verbose "Setting DNS Server Addresses on $VM..."
    $SO = Invoke-CheckedGuestScript -VM ($VM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $SetDNSAddress
    $SO.ScriptOutput
    Write-Output "DNS Server Addresses on $VM have been updated."
}

function Invoke-RegisterDNS {
    Write-Output "Registering DNS on $TargetVM"
    $SO = Invoke-CheckedGuestScript -VM ($TargetVM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $RegisterDNS
    $SO.ScriptOutput
}

function Invoke-RegisterDNSAll {
    Write-Output "Registering DNS on $VM"
    $SO = Invoke-CheckedGuestScript -VM ($VM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $RegisterDNS
    $SO.ScriptOutput
}

<# WINDOWS SERVICES #>
function Get-ServicesOnVM {
    Write-Verbose "Getting List of all Services on $TargetVM"
    $SO = Invoke-CheckedGuestScript -VM ($TargetVM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $GetSvcOnVM
    $SO.ScriptOutput
}

function Get-ServicesAll {
    Write-Verbose "Getting List of all Services on $VM"
    $SO = Invoke-CheckedGuestScript -VM ($VM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $GetSvcOnVM
    $SO.ScriptOutput
}

function Get-SpecificSVC {
    Write-Verbose "Finding Service on $TargetVM"
    $SO1 = Invoke-CheckedGuestScript -VM ($TargetVM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $GetDomainSvc
    if (-not [string]::IsNullOrWhiteSpace($SO1.ScriptOutput)) {
        Write-Output "Service Found on $TargetVM"
        $SO1.ScriptOutput
    }
    else {
        Write-Output "Service not Found on $TargetVM"
    }
}

function Get-SpecificSVCAll {
    Write-Verbose "Finding Service on $VM"
    $SO1 = Invoke-CheckedGuestScript -VM ($VM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $GetDomainSvc
    if (-not [string]::IsNullOrWhiteSpace($SO1.ScriptOutput)) {
        Write-Output "Service Found on $VM"
        $SO1.ScriptOutput
    }
    else {
        Write-Output "Service not Found on $VM"
    }
}

<# NETWORK CONNECTIVITY #>
function Get-PingStatus {
    Write-Verbose "Pinging $TargetVM"
    Test-Connection -TargetName $TargetVM -ResolveDestination | Select-Object -ExpandProperty Status
}

function Get-PingStatusAll {
    Write-Verbose "Pinging $VM"
    Test-Connection -TargetName $VM -ResolveDestination | Select-Object -ExpandProperty Status
}

function Get-PingStatusIP {
    Write-Verbose "Pinging IP of $TargetVM"
    $IP = Get-PrimaryIPv4Address -VMName $TargetVM
    Test-Connection -TargetName $IP -IPv4 -ResolveDestination | Select-Object -ExpandProperty Status
}

function Get-PingStatusIPAll {
    Write-Verbose "Pinging IP of $VM"
    $IP = Get-PrimaryIPv4Address -VMName $VM
    Test-Connection -TargetName $IP -IPv4 -ResolveDestination | Select-Object -ExpandProperty Status
}

function Get-PingStatusAdmin {
    Write-Verbose "Checking Admin Share on $TargetVM"
    Show-AdminShareStatus -ComputerName $TargetVM
}

function Get-PingStatusAdminAll {
    Write-Verbose "Checking Admin Share on $VM"
    Show-AdminShareStatus -ComputerName $VM
}

function Test-ReachDomain {
    Write-Verbose "Testing $DC.$Domain reachability from $TargetVM"
    $SO = Invoke-CheckedGuestScript -VM ($TargetVM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $PingDC
    $SO.ScriptOutput
}

function Test-ReachDomainAll {
    Write-Verbose "Testing $DC.$Domain reachability from $VM"
    $SO = Invoke-CheckedGuestScript -VM ($VM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $PingDC
    $SO.ScriptOutput
}

function Test-ReachDomainDCIP {
    Write-Verbose "Testing $DCIP reachability from $VM"
    $SO = Invoke-CheckedGuestScript -VM ($VM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $PingDCIP
    $SO.ScriptOutput
}

function Test-ADMTPort {
    Write-Verbose "Checking ADMT-related ports from $TargetVM to $DCIP"
    $SO = Invoke-CheckedGuestScript -VM ($TargetVM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $TestADMTPortsScript
    $SO.ScriptOutput
}

function Test-ADMTPortsAll {
    Write-Verbose "Checking ADMT-related ports from $VM to $DCIP"
    $SO = Invoke-CheckedGuestScript -VM ($VM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $TestADMTPortsScript
    $SO.ScriptOutput
}

<# WINDOWS FIREWALL #>
function Get-WinFirewallStatus {
    Write-Verbose "Getting Firewall Status on $TargetVM"
    $SO = Invoke-CheckedGuestScript -VM ($TargetVM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $FWStatus
    $SO.ScriptOutput
}

function Get-WinFirewallStatusAll {
    Write-Verbose "Getting Firewall Status on $VM"
    $SO = Invoke-CheckedGuestScript -VM ($VM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $FWStatus
    $SO.ScriptOutput
}

function Set-WinFirewallOff {
    Write-Output "Disabling Windows Firewall on $TargetVM"
    $SO = Invoke-CheckedGuestScript -VM ($TargetVM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $FWDisable
    $SO.ScriptOutput
}

function Set-WinFirewallOffAll {
    Write-Output "Disabling Windows Firewall on $VM"
    $SO = Invoke-CheckedGuestScript -VM ($VM) -GuestCredential $GuestCreds -ScriptType Powershell -ScriptText $FWDisable
    $SO.ScriptOutput
}

<# BACKUP FUNCTIONS #>
function Show-BackupPolicyExclude {
    Write-Verbose "Checking Backup Policy on $TargetVM"
    $BUExclude = Get-Annotation -Entity $TargetVM -CustomAttribute "BackupPolicy" | Select-Object Value
    if ($BUExclude.Value -eq "Exclude") {
        Write-Output "Backup Policy on $TargetVM set to Exclude"
    }
    else {
        Write-Output "Backup Policy on $TargetVM NOT set to Exclude"
    }
}

function Show-BackupPolicyExcludeAll {
    Write-Verbose "Checking Backup Policy on $VM"
    $BUExclude = Get-Annotation -Entity $VM -CustomAttribute "BackupPolicy" | Select-Object Value
    if ($BUExclude.Value -eq "Exclude") {
        Write-Output "Backup Policy on $VM set to Exclude"
    }
    else {
        Write-Output "Backup Policy on $VM NOT set to Exclude"
    }
}

function Show-BackupPolicySnapshot {
    Write-Verbose "Checking Backup Policy on $TargetVM"
    $BUSnapshot = Get-Annotation -Entity $TargetVM -CustomAttribute "BackupPolicy" | Select-Object Value
    if ($BUSnapshot.Value -eq "Snapshot") {
        Write-Output "Backup Policy on $TargetVM set to Snapshot"
    }
    else {
        Write-Output "Backup Policy on $TargetVM NOT set to Snapshot"
    }
}

function Show-BackupPolicySnapshotAll {
    Write-Verbose "Checking Backup Policy on $VM"
    $BUSnapshot = Get-Annotation -Entity $VM -CustomAttribute "BackupPolicy" | Select-Object Value
    if ($BUSnapshot.Value -eq "Snapshot") {
        Write-Output "Backup Policy on $VM set to Snapshot"
    }
    else {
        Write-Output "Backup Policy on $VM NOT set to Snapshot"
    }
}

function Set-BackupPolicy2Exclude {
    Write-Verbose "Setting VMs Backup Policy to Exclude"
    if ((Get-Annotation -Entity $TargetVM -CustomAttribute "BackupPolicy" | Select-Object -ExpandProperty Value) -ne "Exclude") {
        Write-Verbose "Setting Backup Policy on $TargetVM to Exclude"
        Set-Annotation -Entity $TargetVM -CustomAttribute "BackupPolicy" -Value "Exclude"
    }
    Write-Verbose "Finished setting Backup Policy on $TargetVM"
}

function Set-BackupPolicy2ExcludeAll {
    Write-Verbose "Setting VMs Backup Policy to Exclude"
    if ((Get-Annotation -Entity $VM -CustomAttribute "BackupPolicy" | Select-Object -ExpandProperty Value) -ne "Exclude") {
        Write-Verbose "Setting Backup Policy on $VM to Exclude"
        Set-Annotation -Entity $VM -CustomAttribute "BackupPolicy" -Value "Exclude"
    }
    Write-Verbose "Finished setting Backup Policy on $VM"
}

function Set-BackupPolicy2Snapshot {
    Write-Verbose "Setting VMs Backup Policy to Snapshot"
    if ((Get-Annotation -Entity $TargetVM -CustomAttribute "BackupPolicy" | Select-Object -ExpandProperty Value) -ne "Snapshot") {
        Write-Verbose "Setting Backup Policy on $TargetVM to Snapshot"
        Set-Annotation -Entity $TargetVM -CustomAttribute "BackupPolicy" -Value "Snapshot"
    }
    Write-Verbose "Finished setting Backup Policy on $TargetVM"
}

function Set-BackupPolicy2SnapshotAll {
    Write-Verbose "Setting VMs Backup Policy to Snapshot"
    if ((Get-Annotation -Entity $VM -CustomAttribute "BackupPolicy" | Select-Object -ExpandProperty Value) -ne "Snapshot") {
        Write-Verbose "Setting Backup Policy on $VM to Snapshot"
        Set-Annotation -Entity $VM -CustomAttribute "BackupPolicy" -Value "Snapshot"
    }
    Write-Verbose "Finished setting Backup Policy on $VM"
}

<# SNAPSHOT FUNCTIONS #>
function New-Snap4Salvation {
    Write-Output "Creating new snapshot of $TargetVM"
    New-Snapshot -VM $TargetVM -Name "$TargetVM.SNAPSHOT" -Description "Snapshot" -Quiesce -Memory:$false -Confirm:$false
    Write-Verbose "Finished creating new snapshot of $TargetVM"
}

function New-Snap4SalvationAll {
    Write-Output "Creating new snapshot of $VM"
    New-Snapshot -VM $VM -Name "$VM.SNAPSHOT" -Description "Snapshot" -Quiesce -Memory:$false -Confirm:$false
    Write-Verbose "Finished creating new snapshot of $VM"
}

function Remove-AllSnapshots4VM {
    Write-Output "Removing Snapshots for $TargetVM"
    $TargetVM | Get-Snapshot | ForEach-Object { Remove-Snapshot $_ -Confirm:$false }
    Write-Verbose "Finished removing Snapshots for $TargetVM"

}

function Remove-AllSnapshots4All {
    Write-Output "Removing Snapshots for each $VM"
    $VM | Get-Snapshot | ForEach-Object { Remove-Snapshot $_ -Confirm:$false }
    Write-Verbose "Finished removing Snapshots for $VM"
}

<# MANUAL MOVE FUNCTIONS #>
function Add-VM2NewDomain {
    Write-Verbose "Moving $TargetVM to new domain..."
    Join-GuestDomain -VM $TargetVM -Domain $Domain -GuestCredential $GuestCredential -DomainCredential $DomainCredential
    Write-Verbose "Done!"
}

function Add-VM2NewDomainAll {
    Write-Verbose "Moving $VM to new domain..."
    Join-GuestDomain -VM $VM -Domain $Domain -GuestCredential $GuestCredential -DomainCredential $DomainCredential
    Write-Verbose "Done!"
}

<# VMWARE TOOLS STATUS #>
function Get-VMwareToolsStatusOfVM {
    Write-Verbose "Getting VMware Tools Status of $TargetVM"
    ($TargetVM | Get-View).Guest.ToolsStatus
}

function Get-VMwareToolsStatusOfVMAll {
    Write-Verbose "Getting VMware Tools Status of $VM"
    ($VM | Get-View).Guest.ToolsStatus
}

function Update-VmWareToolsOnVM {
    Write-Verbose "Updating VmWare Tools on $TargetVM"
    Update-EligibleVMTool $TargetVM
}

function Update-VmWareToolsOnVMAll {
    Write-Verbose "Updating VmWare Tools on $VM"
    Update-EligibleVMTool $VM
}

<# VM POWER AND REBOOT #>
function Get-PowerStatusOfVM {
    Write-Verbose "Getting Power Status of $TargetVM"
    $TargetVM | Select-Object Powerstate
}

function Get-PowerStatusOfVMAll {
    Write-Verbose "Getting Power Status of $VM"
    $VM | Select-Object Powerstate
}

function Invoke-RebootOfVM {
    Write-Output "Restarting $TargetVM"
    Restart-VMGuest -VM $TargetVM -Confirm:$false
}

function Start-PoweredOffVM {
    Write-Output "Starting $TargetVM"
    Start-VM -VM $TargetVM -Confirm:$false
}

function Invoke-ShutdownOfVM {
    Write-Output "Shutting down $TargetVM"
    Stop-VMGuest -VM $TargetVM -Confirm:$false
}

function Invoke-PowerOffOfVM {
    Write-Output "Powering off $TargetVM"
    Stop-VM -VM $TargetVM -Confirm:$False
}

<# VMOTION #>
function Get-VMotion {
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$VM,

        [int]$Days = 1
    )

    process {
        $ResolvedVM = if ($VM -is [string]) {
            Get-ExactVM $VM
        }
        else {
            $VM
        }

        Get-VIEvent -Server $Server -Entity $ResolvedVM -Start (Get-Date).AddDays(-$Days) |
            Where-Object {
                $_.FullFormattedMessage -match '(?i)vmotion|migrat' -or
                $_.GetType().Name -match 'Migrat'
            } |
            Select-Object CreatedTime, UserName, FullFormattedMessage
    }
}

function Get-DailyVmotion4VM {
    Write-Verbose "Getting 24-hour vMotion events for $TargetVM"
    $TargetVM | Get-VMotion -Days 1 | Format-List *
}

function Get-DailyVmotion4All {
    Write-Verbose "Getting 24-hour vMotion events for $VM"
    $VM | Get-VMotion -Days 1 | Format-List *
}

function Get-WeeklyVmotion4VM {
    Write-Verbose "Getting 1-week vMotion events for $TargetVM"
    $TargetVM | Get-VMotion -Days 7 | Format-List *
}

function Get-WeeklyVmotion4All {
    Write-Verbose "Getting 1-week vMotion events for $VM"
    $VM | Get-VMotion -Days 7 | Format-List *
}

if ($Action -eq 'help') { Show-Menu; return }
if ($Action -eq 'q') { return }
if ($Action -eq '3') { Get-Content -LiteralPath $VMListPath; return }
if ($Action -eq '1') {
    if (!$Server -or !$vCenterCredential -or [WildcardPattern]::ContainsWildcardCharacters([string]$Server)) { throw 'Supply one exact -Server and -vCenterCredential.' }
    Connect-2vCenter
    return
}
if ($Action -eq '13a') {
    if (!$DomainCredential -or (!$DCIP -and (!$DC -or !$Domain))) { throw 'Supply domain credentials and a directory server.' }
    Test-ADAuthentication
    return
}
if (-not $Server) {
    $defaults = Get-Variable -Name DefaultVIServers -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if (!$defaults) { $defaults = Get-Variable -Name DefaultVIServer -Scope Global -ValueOnly -ErrorAction SilentlyContinue }
    $connections = @($defaults | Where-Object { $_ -and $_.IsConnected })
    if ($connections.Count -ne 1) { throw 'Specify -Server when there is not exactly one default vCenter connection.' }
    $Server = $connections[0]
}
if ([WildcardPattern]::ContainsWildcardCharacters([string]$Server)) { throw 'Specify one exact vCenter server.' }

if ($Action -in '12a', '12b' -and !$DomainCredential) { throw 'Supply -DomainCredential for the account name.' }
if ($Action -like '24*' -and (!$PrimaryDnsServer -or !$SecondaryDnsServer)) { throw 'Supply both DNS server addresses.' }
if ($Action -like '32*' -and !$ServiceAccountMatch) { throw 'Supply -ServiceAccountMatch.' }
if ($Action -in '44a', '44b' -and (!$DC -or !$Domain)) { throw 'Supply -DC and -Domain.' }
if ($Action -in '44c', '48a', '48b' -and !$DCIP) { throw 'Supply -DCIP.' }
if ($Action -like '81*' -and (!$GuestCredential -or !$DomainCredential -or !$Domain)) { throw 'Supply -GuestCredential, -DomainCredential and -Domain.' }
if ($Action.EndsWith('b', [StringComparison]::OrdinalIgnoreCase) -or $Action -eq '44c' -or $Action -eq '4') {
    $names = @(Get-Content -LiteralPath $VMListPath | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    $VMs = if ($Action -eq '4') { $names } else { foreach ($name in $names) { Get-ExactVM $name } }
}
elseif ($Action.EndsWith('a', [StringComparison]::OrdinalIgnoreCase)) { $TargetVM = Get-ExactVM $VMName }
switch ($Action) {

    <# VCENTER AND LIST VERIFICATION #>
    '2' {
        'Disconnecting from vCenter...'
        Disconnect-VIServer -Server $Server -Confirm:$false
    }
    '4' {
        'Checking list of VMs for existence in vCenter...'
        foreach ($VM in $VMs) {
            Get-LocationOfVM
        }
    }

    <# WINDOWS ADMIN ACCOUNTS #>
    '11a' {
        'Getting users in Admins group on specific VM...'
        Get-UsersInAdminGroup
    }
    '11b' {
        'Getting users in Admins group on each VM...'
        foreach ($VM in $VMs) {
            Get-UsersInAdminGroupAll
        }
    }
    '12a' {
        'Adding ADMT account to Admins group on specific VM...'
        Add-Account2Group
    }
    '12b' {
        'Adding ADMT account to Admins group on each VM...'
        foreach ($VM in $VMs) {
            Add-Account2GroupAll
        }
    }

    <# IP AND DNS ADDRESSES #>
    '21a' {
        'Getting IP Address for each VM...'
        Get-IPAddress4VM
    }
    '21b' {
        'Getting IP Address for each VM...'
        foreach ($VM in $VMs) {
            Get-IPAddress4VMAll
        }
    }
    '22a' {
        'Getting Domain for each VM...'
        Get-DomainOnVM
    }
    '22b' {
        'Getting Domain for each VM...'
        foreach ($VM in $VMs) {
            Get-DomainOnVMAll
        }
    }
    '23a' {
        'Getting DNS Server Address on specific VM...'
        Get-DNSServerAddress
    }
    '23b' {
        'Getting DNS Server Address for each VM...'
        foreach ($VM in $VMs) {
            Get-DNSServerAddressAll
        }
    }
    '24a' {
        'Setting the DNS Server Address on specific VM...'
        Set-DNSServerAddress
    }
    '24b' {
        'Setting the DNS Server Address on each VM...'
        foreach ($VM in $VMs) {
            Set-DNSServerAddressAll
        }
    }
    '25a' {
        'Registering DNS on specific VM...'
        Invoke-RegisterDNS
    }
    '25b' {
        'Registering DNS on each VM...'
        foreach ($VM in $VMs) {
            Invoke-RegisterDNSAll
        }
    }

    <# WINDOWS SERVICES #>
    '31a' {
        'Getting list of all Services on specific VM...'
        Get-ServicesOnVM
    }
    '31b' {
        'Getting list of all Services on each VM...'
        foreach ($VM in $VMs) {
            Get-ServicesAll
        }
    }
    '32a' {
        'Finding Service on specific VM...'
        Get-SpecificSVC
    }
    '32b' {
        'Finding Service on each VM...'
        foreach ($VM in $VMs) {
            Get-SpecificSVCAll
        }
    }

    <# NETWORK CONNECTIVITY #>
    '41a' {
        'Pinging specific VM by ComputerName...'
        Get-PingStatus
    }
    '41b' {
        'Pinging each VM by ComputerName...'
        foreach ($VM in $VMs) {
            Get-PingStatusAll
        }
    }
    '42a' {
        'Pinging specific VM by IP...'
        Get-PingStatusIP
    }
    '42b' {
        'Pinging each VM by IP...'
        foreach ($VM in $VMs) {
            Get-PingStatusIPAll
        }
    }
    '43a' {
        'Pinging the Admin share on each VM...'
        Get-PingStatusAdmin
    }
    '43b' {
        'Pinging the Admin share on each VM...'
        foreach ($VM in $VMs) {
            Get-PingStatusAdminAll
        }
    }
    '44a' {
        'Testing reachability of DC on specific VM...'
        Test-ReachDomain
    }
    '44b' {
        'Testing reachability of DC from each VM...'
        foreach ($VM in $VMs) {
            Test-ReachDomainAll
        }
    }
    '44c' {
        'Testing reachability of DC IP from each VM...'
        foreach ($VM in $VMs) {
            Test-ReachDomainDCIP
        }
    }

    '48a' { Test-ADMTPort }
    '48b' { foreach ($VM in $VMs) { Test-ADMTPortsAll } }
    <# WINDOWS FIREWALL #>
    '51a' {
        'Getting status of Windows Firewall on specific VM...'
        Get-WinFirewallStatus
    }
    '51b' {
        'Getting status of Windows Firewall on each VM...'
        foreach ($VM in $VMs) {
            Get-WinFirewallStatusAll
        }
    }
    '52a' {
        'Disabling Windows Firewall on specific VM...'
        Set-WinFirewallOff
    }
    '52b' {
        'Disabling Windows Firewall on each VM...'
        foreach ($VM in $VMs) {
            Set-WinFirewallOffAll
        }
    }

    <# BACKUP POLICY #>
    '61a' {
        'Show list of VMs with Backup Policy set to Exclude...'
        Show-BackupPolicyExclude
    }
    '61b' {
        'Show list of VMs with Backup Policy set to Exclude...'
        foreach ($VM in $VMs) {
            Show-BackupPolicyExcludeAll
        }
    }
    '62a' {
        'Show list of VMs with Backup Policy set to Snapshot...'
        Show-BackupPolicySnapshot
    }
    '62b' {
        'Show list of VMs with Backup Policy set to Snapshot...'
        foreach ($VM in $VMs) {
            Show-BackupPolicySnapshotAll
        }
    }
    '64a' {
        'Set Backup Policy to Exclude on each VM...'
        Set-BackupPolicy2Exclude
    }
    '64b' {
        'Set Backup Policy to Exclude on each VM...'
        foreach ($VM in $VMs) {
            Set-BackupPolicy2ExcludeAll
        }
    }
    '65a' {
        'Set Backup Policy to Snapshot on each VM...'
        Set-BackupPolicy2Snapshot
    }
    '65b' {
        'Set Backup Policy to Snapshot on each VM...'
        foreach ($VM in $VMs) {
            Set-BackupPolicy2SnapshotAll
        }
    }

    <# SNAPSHOTS #>
    '71a' {
        'Take Snapshot of specific VM...'
        New-Snap4Salvation
    }
    '71b' {
        'Take Snapshot of each VM...'
        foreach ($VM in $VMs) {
            New-Snap4SalvationAll
        }
    }
    '72a' {
        'Remove Snapshots of specific VM...'
        Remove-AllSnapshots4VM
    }
    '72b' {
        'Remove Snapshots of each VM...'
        foreach ($VM in $VMs) {
            Remove-AllSnapshots4All
        }
    }

    <# MANUAL MOVES #>
    '81a' {
        'Manually moving specific VM...'
        Add-VM2NewDomain
    }
    '81b' {
        'Manually moving each VM...'
        foreach ($VM in $VMs) {
            Add-VM2NewDomainAll
        }
    }

    <# VMWARE TOOLS STATUS #>
    '91a' {
        'Getting VMware Tools Status on VM...'
        Get-VMwareToolsStatusOfVM
    }
    '91b' {
        'Getting VMware Tools Status on VMs...'
        foreach ($VM in $VMs) {
            Get-VMwareToolsStatusOfVMAll
        }
    }
    '92a' {
        'Updating VMware Tools on VM...'
        Update-VmWareToolsOnVM
    }
    '92b' {
        'Updating VMware Tools on VMs...'
        foreach ($VM in $VMs) {
            Update-VmWareToolsOnVMAll
        }
    }

    <# VM POWER AND REBOOT #>
    '101a' {
        'Getting Power Status of VM...'
        Get-PowerStatusOfVM
    }
    '101b' {
        'Getting Power Status of VMs...'
        foreach ($VM in $VMs) {
            Get-PowerStatusOfVMAll
        }
    }
    '102A' {
        'Getting list of VMs...'
        Invoke-RebootOfVM
    }
    '103A' {
        'Powering On specific VM...'
        Start-PoweredOffVM
    }
    '104A' {
        'Shutting Down specific VM...'
        Invoke-ShutdownOfVM
    }
    '105A' {
        'Powering Off specific VM...'
        Invoke-PowerOffOfVM
    }

    <# VMOTION#>
    '111a' {
        'Getting 24-hour vMotion events of VM...'
        Get-DailyVmotion4VM
    }
    '111b' {
        'Getting 24-hour vMotion events of VMs...'
        foreach ($VM in $VMs) {
            Get-DailyVmotion4All
        }
    }
    '112a' {
        'Getting 1-week vMotion events of VM...'
        Get-WeeklyVmotion4VM
    }
    '112b' {
        'Getting 1-week vMotion events of VMs...'
        foreach ($VM in $VMs) {
            Get-WeeklyVmotion4All
        }
    }

    <# VM CPU AND MEMORY #>
    '121a' {
        'Checking CPU and Memory on VM...'
        Get-WeeklyCPURAM4VM
    }
    '121b' {
        'Checking CPU and Memory on VMs...'
        foreach ($VM in $VMs) {
            Get-WeeklyCPURAM4All
        }
    }
    '122a' {
        'Checking CPU and Memory on VM...'
        Get-MonthlyCPURAM4VM
    }
    '122b' {
        'Checking CPU and Memory on VMs...'
        foreach ($VM in $VMs) {
            Get-MonthlyCPURAM4All
        }
    }
}
