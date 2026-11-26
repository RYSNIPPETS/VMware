[CmdletBinding()]
param(
    $list,
    $vcs
)

$ErrorActionPreference = 'Stop'

function Disconnect-ViIdleSession {
    param($list, $vcs)
    if (!$vcs) { throw 'Supply connected vCenter sessions with -vcs.' }
    foreach ($row in $list) {
        $targets = @($vcs | Where-Object { $_.Name -eq $row.Server })
        if ($targets.Count -ne 1 -or !$row.Key -or !$row.Username) { throw 'Invalid or ambiguous idle-session record.' }
        $manager = Get-View SessionManager -Server $targets[0] -ErrorAction Stop
        $hours = if ($row.IdleHours) { [int]$row.IdleHours } else { 8 }
        if ($hours -lt 1) { throw 'Invalid idle threshold.' }
        $inactive = $manager.SessionList | Where-Object { $_.Key -eq $row.Key -and $_.UserName -eq $row.Username -and $_.LastActiveTime.ToUniversalTime() -lt [datetime]::UtcNow.AddHours(-$hours) }
        if ($inactive -and $row.Key -ne $manager.CurrentSession.Key) { $manager.TerminateSession(@($row.Key)) }
    }
}
if ($MyInvocation.InvocationName -ne '.') { Disconnect-ViIdleSession @PSBoundParameters }
