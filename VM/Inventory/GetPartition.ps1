Get-VM -ErrorAction Stop | Where-Object PowerState -EQ PoweredOn | ForEach-Object {
    $vm = $_
    foreach ($volume in $vm.ExtensionData.Guest.Disk) {
        if ($volume.DiskPath -ne 'C:\' -or $volume.Capacity -le 0 -or $null -eq $volume.FreeSpace) { continue }
        $usage = 100 * ($volume.Capacity - $volume.FreeSpace) / $volume.Capacity
        if ($usage -gt 85) {
            [pscustomobject]@{ VM = $vm.Name; Volume = $volume.DiskPath; FreeSpaceMB = [math]::Round($volume.FreeSpace / 1MB); 'Usage%' = [math]::Round($usage, 1) }
        }
    }
} | Export-Csv ./Partitions85Percent.csv
