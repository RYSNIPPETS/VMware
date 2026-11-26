Get-Datastore -ErrorAction Stop | Select-Object @{Name = 'Datastore'; Expression = { $_.Name } }, CapacityGB, FreeSpaceGB,
@{Name = 'UsedPercent'; Expression = { if ($_.CapacityGB -gt 0) { [math]::Round(100 * ($_.CapacityGB - $_.FreeSpaceGB) / $_.CapacityGB, 1) } } } |
    Export-Csv ./DataStoreUsedReport.csv
