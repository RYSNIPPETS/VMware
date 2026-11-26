Get-Datastore -ErrorAction Stop | Where-Object { $_.CapacityGB -gt 0 -and $null -ne $_.FreeSpaceGB -and ($_.FreeSpaceGB / $_.CapacityGB) -le 0.2 } |
    Select-Object @{Name = 'DataStoreName'; Expression = { $_.Name } },
    @{Name = 'Percentage Free Space(%)'; Expression = { [math]::Round(100 * $_.FreeSpaceGB / $_.CapacityGB, 2) } } |
    Export-Csv ./DatastoreUsage.csv
