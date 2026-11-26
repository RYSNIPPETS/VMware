[CmdletBinding()]
param(
    [string]$Server,
    [pscredential]$GuestCredential,
    [string]$Path = './VMs.csv',
    [string]$OutputPath = './SQLVersions.txt'
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
$query = @'
$ErrorActionPreference = 'Stop'
$instances = foreach ($view in 'Registry64','Registry32') {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine',$view)
    $root = 'SOFTWARE\Microsoft\Microsoft SQL Server'
    $names = $base.OpenSubKey("$root\Instance Names\SQL")
    if ($names) {
        foreach ($name in $names.GetValueNames()) {
            $id = $names.GetValue($name)
            $setup = $base.OpenSubKey("$root\$id\Setup")
            if ($setup) {
                [pscustomobject]@{ Instance=$name; Version=$setup.GetValue('PatchLevel',$setup.GetValue('Version')); Edition=$setup.GetValue('Edition') }
                $setup.Close()
            }
        }
        $names.Close()
    }
    $base.Close()
}
ConvertTo-Json -InputObject @($instances | Sort-Object Instance -Unique) -Compress
'@
Import-Csv -LiteralPath $Path | ForEach-Object {
    $vm = Get-ExactVM $_.Name
    $result = Invoke-VMScript -VM $vm -GuestCredential $GuestCredential -ScriptType Powershell -ScriptText $query
    if ($result.ExitCode -ne 0) { throw "SQL instance query failed on $($vm.Name): $($result.ScriptOutput)" }
    foreach ($instance in ($result.ScriptOutput | ConvertFrom-Json)) {
        [pscustomobject]@{ VM = $vm.Name; Instance = $instance.Instance; Version = $instance.Version; Edition = $instance.Edition }
    }
} | Export-Csv -LiteralPath $OutputPath
