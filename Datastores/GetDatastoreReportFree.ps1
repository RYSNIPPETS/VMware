param([string]$DatastoreName = 'VMHostingDataStore-01')
$datastores = @(Get-Datastore -Name $DatastoreName -ErrorAction Stop)
$datastores | Select-Object Name, CapacityGB, FreeSpaceGB,
@{Name = 'UsedGB'; Expression = { [math]::Round($_.CapacityGB - $_.FreeSpaceGB, 2) } },
@{Name = 'FreePercent'; Expression = { if ($_.CapacityGB -gt 0) { [math]::Round(100 * $_.FreeSpaceGB / $_.CapacityGB, 1) } } } |
    Export-Csv ./DataStoreReport.csv
$datastores | Get-View -Property Name, Info | ForEach-Object {
    if ($_.Info -is [VMware.Vim.VmfsDatastoreInfo]) {
        $name = $_.Name
        foreach ($extent in $_.Info.Vmfs.Extent) {
            [pscustomobject]@{ Datastore = $name; DiskName = $extent.DiskName; Partition = $extent.Partition }
        }
    }
} | Export-Csv ./DataStoreExpandReport.csv
