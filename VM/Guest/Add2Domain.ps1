# Requires a Windows PowerShell remoting HTTPS listener on each selected guest.
[CmdletBinding()]
param(
    [string]$Server,
    [string]$DomainName,
    [pscredential]$GuestCredential,
    [pscredential]$DomainCredential,
    [string]$Path = './ServerNames.csv'
)

$ErrorActionPreference = 'Stop'
if (!$DomainName -or !$GuestCredential -or !$DomainCredential) { throw 'Supply -DomainName, -GuestCredential and -DomainCredential.' }
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
foreach ($row in (Import-Csv -LiteralPath $Path -Header OldName, NewName)) {
    if ($row.OldName -eq 'OldName' -and $row.NewName -eq 'NewName') { continue }
    Join-GuestDomain -VM (Get-ExactVM $row.OldName) -Domain $DomainName -GuestCredential $GuestCredential -DomainCredential $DomainCredential
}
