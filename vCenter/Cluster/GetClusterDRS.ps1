<#
.SYNOPSIS
Reports Distributed Resource Scheduler settings for clusters on connected vCenter servers.
#>
[CmdletBinding()]
param(
    [string[]]$Name,
    [string[]]$Server
)

Get-Cluster @PSBoundParameters | Select-Object Name, Uid, DrsEnabled, DrsAutomationLevel
