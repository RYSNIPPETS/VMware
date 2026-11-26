Get-VM -ErrorAction Stop | ForEach-Object {
    $vm = $_
    foreach ($drive in ($vm | Get-CDDrive | Where-Object IsoPath)) {
        [pscustomobject]@{ VMName = $vm.Name; VMId = $vm.Id; InstanceUuid = $vm.ExtensionData.Client.ServiceContent.About.InstanceUuid; DriveId = $drive.Id; ISOPath = $drive.IsoPath }
    }
} | Export-Csv ./MountedISOs.csv
