[CmdletBinding()]
param(
    [string]$ResourcePool = 'testpool',
    [ValidatePattern('^KB[0-9]+$')][string[]]$HotfixIDs = @('KB5040442', 'KB5039894'),
    [pscredential]$GuestCredential,
    [string]$OutputPath = './Output.csv'
)

$ErrorActionPreference = 'Stop'
if (!$GuestCredential) { throw 'Supply -GuestCredential.' }
$filter = $HotfixIDs -join "','"
$guestScript = @'
$ErrorActionPreference = 'Stop'
$wanted = @('HOTFIXES')
Get-CimInstance Win32_QuickFixEngineering | Where-Object { $wanted -contains $_.HotFixID } | Select-Object -ExpandProperty HotFixID
'@
Get-ResourcePool -Name $ResourcePool | ForEach-Object {
    $pool = $_
    Get-VM -Location $pool | ForEach-Object {
        $vm = $_
        try {
            $result = Invoke-VMScript -VM $vm -GuestCredential $GuestCredential -ScriptType Powershell -ScriptText $guestScript.Replace('HOTFIXES', $filter)
            if ($result.ExitCode -ne 0) { throw "Guest exited $($result.ExitCode): $($result.ScriptOutput)" }
            $message = if ($result.ScriptOutput.Trim()) { ($result.ScriptOutput.Trim() -split '\r?\n') -join ', ' } else { 'No matching hotfixes found' }
        }
        catch { $message = "Query failed: $($_.Exception.Message)" }
        [pscustomobject]@{ Name = $vm.Name; OS = $vm.Guest.OSFullName; IP = $vm.Guest.IPAddress -join '|'; RP = $pool.Name; Result = $message }
    }
} | Export-Csv -LiteralPath $OutputPath
