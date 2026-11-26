[CmdletBinding()]
param(
    $Server,
    [string]$Cluster = 'Cluster01',
    [ValidateSet('Off', 'Manual', 'Automated')][string]$Behavior = 'Automated'
)

$ErrorActionPreference = 'Stop'

function Set-DPM {
    param([string]$Cluster, [ValidateSet('Off', 'Manual', 'Automated')][string]$Behavior, $Server)
    if (!$Cluster -or !$Behavior) { throw 'Supply Cluster and Behavior.' }
    if (-not $Server) {
        $defaults = Get-Variable -Name DefaultVIServers -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if (!$defaults) { $defaults = Get-Variable -Name DefaultVIServer -Scope Global -ValueOnly -ErrorAction SilentlyContinue }
        $connections = @($defaults | Where-Object { $_ -and $_.IsConnected })
        if ($connections.Count -ne 1) { throw 'Specify -Server when there is not exactly one default vCenter connection.' }
        $Server = $connections[0]
    }
    if ([WildcardPattern]::ContainsWildcardCharacters([string]$Server)) { throw 'Specify one exact vCenter server.' }

    $targets = @(Get-Cluster -Server $Server | Where-Object Name -CEQ $Cluster)
    if ($targets.Count -ne 1) { throw "Expected one cluster named $Cluster." }
    $view = $targets[0].ExtensionData
    $spec = [VMware.Vim.ClusterConfigSpecEx]::new()
    $spec.DpmConfig = [VMware.Vim.ClusterDpmConfigInfo]::new()
    $spec.DpmConfig.Enabled = $Behavior -ne 'Off'
    if ($spec.DpmConfig.Enabled) { $spec.DpmConfig.DefaultDpmBehavior = $Behavior.ToLowerInvariant() }
    $task = $view.ReconfigureComputeResource_Task($spec, $true)
    Get-Task -Server $Server -Id "Task-$($task.Value)" | Wait-Task -ErrorAction Stop | Out-Null
    $view.UpdateViewData('ConfigurationEx.DpmConfigInfo')
    [pscustomobject]@{Cluster = $view.Name; DPMEnabled = $view.ConfigurationEx.DpmConfigInfo.Enabled; DefaultDpmBehavior = $view.ConfigurationEx.DpmConfigInfo.DefaultDpmBehavior }
}
if ($MyInvocation.InvocationName -ne '.') { Set-DPM -Cluster $Cluster -Behavior $Behavior -Server $Server }
