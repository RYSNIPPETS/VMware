[CmdletBinding()]
param(
    $vclist,
    [string[]]$excluded,
    [ValidateRange(1, 8760)][int]$Hours = 8
)

$ErrorActionPreference = 'Stop'

function Get-ViIdleSession {
    param($vclist, [string[]]$excluded, [ValidateRange(1, 8760)][int]$Hours = 8)
    if (!$vclist) { throw 'Supply connected vCenter sessions with -vclist.' }
    $now = Get-Date
    foreach ($vc in $vclist) {
        $manager = Get-View SessionManager -Server $vc -ErrorAction Stop
        foreach ($session in $manager.SessionList) {
            if ($session.Key -eq $manager.CurrentSession.Key -or $session.UserName -in $excluded -or $session.LastActiveTime.ToUniversalTime() -ge $now.ToUniversalTime().AddHours(-$Hours)) { continue }
            [pscustomobject]@{ Username = $session.UserName; FullName = $session.FullName; TimeStamp = $now; Server = [string]$vc; LoginTime = $session.LoginTime; LastActiveTime = $session.LastActiveTime; Key = $session.Key; IdleHours = $Hours }
        }
    }
}
if ($MyInvocation.InvocationName -ne '.') { Get-ViIdleSession @PSBoundParameters }
