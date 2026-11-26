function Get-VMInformation {
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(Position = 0, ParameterSetName = 'ByName')][Alias('VM')][string[]]$Name,
        [Parameter(ParameterSetName = 'ByName')][object[]]$Server,
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName, ParameterSetName = 'Pipeline')][psobject[]]$InputObject
    )
    process {
        if ($PSCmdlet.ParameterSetName -eq 'ByName') {
            $query = @{}
            if ($Name) { $query.Name = $Name }
            if ($Server) { $query.Server = $Server }
            $InputObject = Get-VM @query -ErrorAction Stop
        }
        foreach ($vm in $InputObject) {
            if (!$vm.PSObject.Properties['VMHost'] -or !$vm.PSObject.Properties['MemoryGB']) {
                Write-Error 'Expected a PowerCLI virtual machine object.'
                continue
            }
            $adapters = @($vm | Get-NetworkAdapter)
            [pscustomobject]@{
                Name=$vm.Name; Domain=$vm.ExtensionData.Guest.IpStack.DnsConfig.DomainName -join ', '
                IPAddress=$vm.Guest.IPAddress -join ', '; GuestOS=$vm.ExtensionData.Config.GuestFullName
                PowerState=$vm.PowerState; Datacenter=($vm.VMHost | Get-Datacenter).Name
                vCenter=([uri]$vm.ExtensionData.Client.ServiceUrl).Host; VMHost=$vm.VMHost
                Cluster=($vm.VMHost | Get-Cluster -ErrorAction SilentlyContinue).Name; FolderName=$vm.Folder
                Datastore=($vm | Get-Datastore).Name -join ', '; NetworkName=$adapters.NetworkName -join ', '
                MacAddress=$adapters.MacAddress -join ', '; VMTools=$vm.ExtensionData.Guest.ToolsVersionStatus2
            }
        }
    }
}
