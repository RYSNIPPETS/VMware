Get-VM -ErrorAction Stop | ForEach-Object {
    $vm = $_
    $vm | Get-NetworkAdapter | Where-Object Type -EQ E1000 | ForEach-Object {
        [pscustomobject]@{
            VM           = $vm.Name
            Adapter      = $_.Name
            AdapterType  = $_.Type
            vCenter      = ([uri]$vm.ExtensionData.Client.ServiceUrl).Host
            Cluster      = ($vm.VMHost | Get-Cluster -ErrorAction SilentlyContinue).Name
            ResourcePool = ($vm | Get-ResourcePool).Name
        }
    }
}
