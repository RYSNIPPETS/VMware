[CmdletBinding()]
param(
    $Server,
    [string]$Path = './DeployedVMs.csv'
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

$finish = Get-Date
Get-VIEvent -Server $Server -Start $finish.AddDays(-7) -Finish $finish -MaxSamples ([int]::MaxValue) |
    Where-Object { $_.GetType().Name -eq 'VmDeployedEvent' } |
    Select-Object @{Name = 'VM'; Expression = { $_.Vm.Name } }, UserName, CreatedTime, FullFormattedMessage |
    Export-Csv -LiteralPath $Path
