function New-DiskReportRow($vmName, $diskName, $capacity, $free) {
    [pscustomobject]@{
        VM            =$vmName
        Disk          =$diskName
        TotalCapacity =if ($null -ne $capacity) { [math]::Round($capacity / 1GB, 3) }
        FreeSpace     =if ($null -ne $free) { [math]::Round($free / 1GB, 3) }
        PercentFree   =if ($capacity -gt 0 -and $null -ne $free) { '{0:P0}' -f ($free / $capacity) }
    }
}
Get-View -ViewType VirtualMachine -Property Name, Guest.Disk -ErrorAction Stop | ForEach-Object {
    $vm = $_
    $disks = @($vm.Guest.Disk | Where-Object { $_ })
    foreach ($disk in $disks) { New-DiskReportRow -VMName $vm.Name -DiskName $disk.DiskPath -Capacity $disk.Capacity -Free $disk.FreeSpace }
    $capacity = if ($disks.Count -and !($disks | Where-Object { $null -eq $_.Capacity })) { ($disks | Measure-Object Capacity -Sum).Sum }
    $free = if ($disks.Count -and !($disks | Where-Object { $null -eq $_.FreeSpace })) { ($disks | Measure-Object FreeSpace -Sum).Sum }
    New-DiskReportRow -VMName $vm.Name -DiskName SubTotal -Capacity $capacity -Free $free
} | Export-Csv ./DiskUsageReport.csv -UseCulture
