Get-VM -Name (Get-Content ./ServerList.txt) -ErrorAction Stop | Select-Object Name, VMHost, NumCpu, MemoryGB, ProvisionedSpaceGB, UsedSpaceGB | Sort-Object Name | Export-Csv ./VMCpuRamDisk.csv
