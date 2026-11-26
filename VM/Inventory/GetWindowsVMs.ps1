Get-VM -ErrorAction Stop | Where-Object { $_.ExtensionData.Config.GuestFullName -match 'Windows' } |
    Select-Object Name, @{Name = 'Configured OS'; Expression = { $_.ExtensionData.Config.GuestFullName } } | Export-Csv ./WindowsVMs.csv -UseCulture
