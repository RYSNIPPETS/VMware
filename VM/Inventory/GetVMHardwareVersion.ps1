Get-VM -ErrorAction Stop | Select-Object Name, HardwareVersion | Export-Csv ./VMHardwareVersion.csv
