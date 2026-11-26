Get-VM -ErrorAction Stop | Where-Object PowerState -EQ PoweredOn | ForEach-Object {
    $vm = $_
    foreach ($nic in ($vm | Get-NetworkAdapter)) {
        $guestNic = $vm.ExtensionData.Guest.Net | Where-Object { $_.DeviceConfigId -eq $nic.ExtensionData.Key }
        [pscustomobject]@{ VMName = $vm.Name; Name = $nic.Name; Type = $nic.Type; MacAddress = $nic.MacAddress; NetworkName = $nic.NetworkName; IPAddress = $guestNic.IpAddress -join '; ' }
    }
} | Export-Csv ./NetworkInfo.csv
