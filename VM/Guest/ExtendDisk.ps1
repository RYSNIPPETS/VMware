[CmdletBinding()]
param(
    [string]$Server,
    [string]$VMName,
    [string]$HardDiskName = 'Hard disk 1',
    [ValidatePattern('^[A-Za-z]$')][string]$DriveLetter = 'C',
    [decimal]$TargetCapacityGB,
    [pscredential]$GuestCredential
)

$ErrorActionPreference = 'Stop'
if (!$VMName -or !$GuestCredential -or $TargetCapacityGB -le 0) { throw 'Supply -VMName, -GuestCredential and a positive absolute -TargetCapacityGB.' }
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
$vm = Get-ExactVM $VMName
$disks = @($vm | Get-HardDisk | Where-Object Name -EQ $HardDiskName)
if ($disks.Count -ne 1) { throw 'Expected one virtual disk with the requested name.' }
$disk = $disks[0]
$uuid = $disk.ExtensionData.Backing.Uuid -replace '[\s:-]'
if ($uuid -notmatch '^[0-9A-Fa-f]{32}$') { throw 'A VMDK backing UUID is required to match the Windows disk serial number.' }
if ($disk.CapacityGB -gt $TargetCapacityGB) { throw 'The target capacity is smaller than the current disk.' }
$verify = @'
$ErrorActionPreference = 'Stop'
Update-HostStorageCache
$volume = Get-Partition -DriveLetter 'LETTER'
$disk = Get-Disk -Number $volume.DiskNumber
if (($disk.SerialNumber -replace '[\s:-]') -ne 'DISKUUID') { throw 'Guest volume is on a different disk or its serial number is unavailable.' }
'@
$verify = $verify.Replace('LETTER', $DriveLetter).Replace('DISKUUID', $uuid)
function Invoke-VolumeStep([string]$Text) {
    $result = Invoke-VMScript -VM $vm -GuestCredential $GuestCredential -ScriptType Powershell -ScriptText $Text
    if ($result.ExitCode -ne 0) { throw "Guest disk operation failed: $($result.ScriptOutput)" }
}
Invoke-VolumeStep $verify
if ($disk.CapacityGB -lt $TargetCapacityGB) {
    Set-HardDisk -HardDisk $disk -CapacityGB $TargetCapacityGB -Confirm:$false | Out-Null
}
$resize = @'

if ($disk.Size -lt TARGETBYTES) { throw 'Guest does not yet see the requested disk capacity. Retry with the same target size.' }
$limit = Get-PartitionSupportedSize -DiskNumber $disk.Number -PartitionNumber $volume.PartitionNumber
if ($limit.SizeMax -gt $volume.Size) {
    Resize-Partition -DiskNumber $disk.Number -PartitionNumber $volume.PartitionNumber -Size $limit.SizeMax -Confirm:$false
}
'@
Invoke-VolumeStep ($verify + [Environment]::NewLine + $resize.Replace('TARGETBYTES', [string][long]($TargetCapacityGB * 1GB)))
