Get-VM -ErrorAction Stop | Select-Object Name, @{Name = 'IP Address'; Expression = { $_.Guest.IPAddress -join '; ' } } | Export-Csv ./IP_Addresses.csv
