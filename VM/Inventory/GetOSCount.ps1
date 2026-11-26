param([string[]]$Server)
function Get-VMOSList {
    param([Alias('vCenter')][string[]]$Server)
    $query = @{}
    if ($Server) { $query.Server = $Server }
    Get-VM @query -ErrorAction Stop | Select-Object @{Name = 'vCenter'; Expression = { ([uri]$_.ExtensionData.Client.ServiceUrl).Host } }, @{Name = 'OS'; Expression = { $_.ExtensionData.Config.GuestFullName } } |
        Group-Object vCenter, OS | ForEach-Object {
            [pscustomobject]@{ Name = $_.Group[0].OS; 'Total VMs' = $_.Count; vCenter = $_.Group[0].vCenter }
        }
}
Get-VMOSList -Server $Server | Export-Csv (Join-Path $PSScriptRoot 'OSCount.csv') -UseCulture
