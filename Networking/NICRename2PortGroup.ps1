[CmdletBinding()]
param(
    [string]$Server,
    [pscredential]$GuestCredential
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
function ConvertTo-GuestData {
    param($Value)
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Compress -Depth 5)))
}
$renameScript = @'
$ErrorActionPreference = 'Stop'
$plan = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('DATA')) | ConvertFrom-Json
$adapters = @(Get-NetAdapter -IncludeHidden)
$changes = foreach ($item in $plan) {
    $matchesFound = @($adapters | Where-Object { $_.MacAddress -and ($_.MacAddress -replace '[:-]') -eq $item.Mac })
    if ($matchesFound.Count -ne 1) { throw "Expected one guest adapter for $($item.Mac)." }
    if ($matchesFound[0].Name -eq $item.Name) { continue }
    if ($adapters.Name -contains $item.Name) { throw "Adapter name already in use: $($item.Name)" }
    [pscustomobject]@{ Adapter=$matchesFound[0]; Name=$item.Name }
}
foreach ($change in $changes) { $change.Adapter | Rename-NetAdapter -NewName $change.Name -Confirm:$false }
'@
Get-VM -Server $Server | Where-Object { $_.PowerState -eq 'PoweredOn' -and $_.ExtensionData.Config.GuestFullName -match 'Windows' } | ForEach-Object {
    $vm = $_
    $plan = @($vm | Get-NetworkAdapter | ForEach-Object { @{ Mac = ($_.MacAddress -replace '[:-]'); Name = $_.NetworkName } })
    if (!$plan.Count) { return }
    $names = @($plan | ForEach-Object { $_.Name })
    if (($names | Sort-Object -Unique).Count -ne $plan.Count) { throw "More than one NIC requests the same port group name on $($vm.Name)." }
    $result = Invoke-VMScript -VM $vm -GuestCredential $GuestCredential -ScriptType Powershell -ScriptText $renameScript.Replace('DATA', (ConvertTo-GuestData $plan))
    if ($result.ExitCode -ne 0) { throw "Guest rename failed on $($vm.Name): $($result.ScriptOutput)" }
}
