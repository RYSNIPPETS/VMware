[CmdletBinding()]
param(
    [string]$Server,
    [pscredential]$GuestCredential,
    [string]$Path = './VMList.csv',
    [string]$SourceDirectory = (Join-Path $PSScriptRoot 'Directory'),
    [string]$DestinationDirectory = 'C:\Directory',
    [string]$InstallerName = 'NameofPackage.msi'
)

$ErrorActionPreference = 'Stop'
if (!$GuestCredential) { throw 'Supply -GuestCredential.' }
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
$source = Get-Item -LiteralPath $SourceDirectory
if (!$source.PSIsContainer) { throw 'SourceDirectory must be a directory.' }
$files = @(Get-ChildItem -LiteralPath $source.FullName -Recurse -File -Force)
if (!$files.Count) { throw 'The source directory contains no files.' }
if ($InstallerName -notmatch '^[^\\/":]+\.msi$' -or $files.FullName -notcontains (Join-Path $source.FullName $InstallerName)) { throw 'Specify an MSI in the source directory.' }
$guestPath = ($DestinationDirectory.TrimEnd('\') + '\' + $InstallerName).Replace("'", "''")
$install = @'
$ErrorActionPreference = 'Stop'
$package = 'MSIPATH'
if (!(Test-Path -LiteralPath $package -PathType Leaf)) { throw 'MSI was not copied.' }
$process = Start-Process msiexec.exe -ArgumentList ('/i "{0}" /qn /norestart' -f $package) -Wait -PassThru
exit $process.ExitCode
'@
foreach ($row in (Import-Csv -LiteralPath $Path)) {
    $vm = Get-ExactVM $row.Name
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($source.FullName, $file.FullName).Replace('/', '\')
        $destination = $DestinationDirectory.TrimEnd('\') + '\' + $relative
        Copy-VMGuestFile -VM $vm -Source $file.FullName -Destination $destination -LocalToGuest -GuestCredential $GuestCredential -Force -Confirm:$false
    }
    $result = Invoke-VMScript -VM $vm -GuestCredential $GuestCredential -ScriptType Powershell -ScriptText $install.Replace('MSIPATH', $guestPath)
    if ($result.ExitCode -notin 0, 1641, 3010) { throw "Windows Installer failed on $($vm.Name) with code $($result.ExitCode)." }
    [pscustomobject]@{ VM = $vm.Name; ExitCode = $result.ExitCode; RebootRequired = $result.ExitCode -in 1641, 3010 }
}
