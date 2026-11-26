$finish = Get-Date
$start = $finish.AddDays(-30)
Get-VMHost -ErrorAction Stop | ForEach-Object {
    $row = [ordered]@{ HostName = $_.Name }
    foreach ($metric in 'cpu', 'mem') {
        $samples = @(Get-Stat -Entity $_ -Start $start -Finish $finish -MaxSamples 1000 -Stat "$metric.usage.average" | Where-Object { $null -ne $_.Value -and -not $_.Instance })
        $stats = $samples | Measure-Object -Property Value -Maximum -Average -Minimum
        $prefix = if ($metric -eq 'cpu') { 'CPU' } else { 'Mem' }
        foreach ($stat in 'Maximum', 'Average', 'Minimum') {
            $row[$prefix + $stat.Substring(0, 3).Replace('Ave', 'Avg')] = if ($samples.Count) { [math]::Round($stats.$stat) }
        }
    }
    [pscustomobject]$row
} | Export-Csv ./CPURAMPerfHosts.csv
