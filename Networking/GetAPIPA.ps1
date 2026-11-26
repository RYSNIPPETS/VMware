Get-View -ViewType VirtualMachine -Property Name, Guest.Net, Guest.IpAddress -ErrorAction Stop | ForEach-Object {
    $addresses = @($_.Guest.IpAddress) + @($_.Guest.Net | ForEach-Object { $_.IpAddress })
    $linkLocal = @($addresses | Where-Object { $_ -match '^169\.254\.(?:\d{1,3}\.)\d{1,3}$' } | Sort-Object -Unique)
    if ($linkLocal.Count) { [pscustomobject]@{ Name = $_.Name; IP = $linkLocal -join '; ' } }
} | Export-Csv ./APIPAIPAddresses.csv
