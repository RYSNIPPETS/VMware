<#
.SYNOPSIS
Reports High Availability settings for clusters on connected vCenter servers.
#>
[CmdletBinding()]
param(
    [string[]]$Name,
    [string[]]$Server
)

Get-Cluster @PSBoundParameters |
    Select-Object Name, Uid, HAEnabled, HAAdmissionControlEnabled, HAFailoverLevel, HARestartPriority, HAIsolationResponse
