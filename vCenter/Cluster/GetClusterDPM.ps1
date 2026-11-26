<#
.SYNOPSIS
Reports Distributed Power Management settings for clusters on connected vCenter servers.
#>
[CmdletBinding()]
param(
    [string[]]$Name,
    [string[]]$Server
)

Get-Cluster @PSBoundParameters | ForEach-Object {
    $dpm = $_.ExtensionData.ConfigurationEx.DpmConfigInfo
    [pscustomobject]@{
        Name               = $_.Name
        Uid                = $_.Uid
        DpmEnabled         = if ($dpm) { $dpm.Enabled }
        DefaultDpmBehavior = if ($dpm) { $dpm.DefaultDpmBehavior }
    }
}
