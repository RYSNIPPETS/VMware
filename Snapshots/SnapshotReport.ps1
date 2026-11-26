$cutoff = (Get-Date).AddDays(-30)
Get-VM -ErrorAction Stop | Get-Snapshot | Where-Object { $_.Created -lt $cutoff } |
    Select-Object @{Name = 'vCenter'; Expression = { ([uri]$_.VM.ExtensionData.Client.ServiceUrl).Host } }, VM, Name, Created |
    Export-Csv ./Snapshots30Days.csv
