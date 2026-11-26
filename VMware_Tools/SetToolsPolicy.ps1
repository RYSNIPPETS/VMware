[CmdletBinding()]
param(
    $Server,
    [string[]]$VMName,
    [ValidateSet('manual', 'upgradeAtPowerCycle')][string]$Policy = 'manual'
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

function Get-ExactVM {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'A VM name is required.' }
    $matchesFound = @(Get-VM -Server $Server -Name ([WildcardPattern]::Escape($Name)) | Where-Object Name -EQ $Name)
    if ($matchesFound.Count -ne 1) { throw "Expected one VM named '$Name' on '$Server'. Found $($matchesFound.Count)." }
    $matchesFound[0]
}

$targets = if ($VMName) { foreach ($name in $VMName) { Get-ExactVM $name } } else { Get-VM -Server $Server }
foreach ($vm in $targets) {
    $view = $vm.ExtensionData
    if ($view.Config.Template -or $view.Config.Tools.ToolsUpgradePolicy -eq $Policy) { continue }
    $spec = [VMware.Vim.VirtualMachineConfigSpec]::new()
    $spec.ChangeVersion = $view.Config.ChangeVersion
    $spec.Tools = [VMware.Vim.ToolsConfigInfo]::new()
    $spec.Tools.ToolsUpgradePolicy = $Policy
    $task = $view.ReconfigVM_Task($spec)
    Get-Task -Server $Server -Id "Task-$($task.Value)" | Wait-Task -ErrorAction Stop
}
