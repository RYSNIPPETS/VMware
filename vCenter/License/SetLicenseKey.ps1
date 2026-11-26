[CmdletBinding()]
param(
    [string]$VMHost,
    [string]$LicKey,
    [string]$TypeId = 'vmware-vsphere',
    [string]$Name,
    $Server
)

$ErrorActionPreference = 'Stop'

function Set-LicenseKey {
    <#
    .SYNOPSIS
    Associates and applies a vSphere license key to a host.
    .DESCRIPTION
    This function uses the current LicenseDataManager API exposed by PowerCLI to
    associate a license key with a host and apply it immediately.
    .NOTES
    Source: Automating vSphere Administration
    .PARAMETER LicKey
    The license key to associate with the host.
    .PARAMETER VMHost
    The ESXi host that should receive the license key.
    .PARAMETER TypeId
    The VMware license type identifier. Defaults to vmware-vsphere.
    .PARAMETER Name
    Retained for backward compatibility. The current licensing API does not use
    a friendly name during assignment.
    .EXAMPLE
    Set-LicenseKey -LicKey "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE" -VMHost "esxhost01.contoso.com"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$VMHost,

        [Parameter(Mandatory)]
        [string]$LicKey,

        [string]$TypeId = "vmware-vsphere",

        [string]$Name,
        $Server
    )

    process {
        if (-not $Server) {
            $defaults = Get-Variable -Name DefaultVIServers -Scope Global -ValueOnly -ErrorAction SilentlyContinue
            if (!$defaults) { $defaults = Get-Variable -Name DefaultVIServer -Scope Global -ValueOnly -ErrorAction SilentlyContinue }
            $connections = @($defaults | Where-Object { $_ -and $_.IsConnected })
            if ($connections.Count -ne 1) { throw 'Specify -Server when there is not exactly one default vCenter connection.' }
            $Server = $connections[0]
        }
        if ([WildcardPattern]::ContainsWildcardCharacters([string]$Server)) { throw 'Specify one exact vCenter server.' }

        $about = (Get-View ServiceInstance -Server $Server -ErrorAction Stop).Content.About
        if (!$about.Version) { throw 'Unable to identify vCenter version.' }
        if ([version]$about.Version -ge [version]'9.0') { throw 'Use VCF Operations subscription licensing for vSphere 9 or later (Broadcom KB 428638).' }
        $targets = @(Get-VMHost -Server $Server -Name ([WildcardPattern]::Escape($VMHost)) | Where-Object Name -CEQ $VMHost)
        if ($targets.Count -ne 1) { throw 'Expected one exact host on the selected vCenter.' }
        $vmHostObject = $targets[0]
        $licenseDataManager = Get-LicenseDataManager -Server $Server

        $licenseData = New-Object Vmware.VimAutomation.License.Types.LicenseData
        $licenseKeyEntry = New-Object Vmware.VimAutomation.License.Types.LicenseKeyEntry
        $licenseKeyEntry.TypeId = $TypeId
        $licenseKeyEntry.LicenseKey = $LicKey
        $licenseData.LicenseKeys += $licenseKeyEntry

        if ($Name) {
            Write-Verbose "Ignoring legacy friendly name [$Name] because the current LicenseDataManager API does not persist it during assignment."
        }

        if ($PSCmdlet.ShouldProcess($vmHostObject.Name, "Associate and apply license key")) {
            $licenseDataManager.UpdateAssociatedLicenseData($vmHostObject.Uid, $licenseData)
            $licenseDataManager.ApplyAssociatedLicenseData($vmHostObject.Uid)
        }

        Get-VMHost -Server $Server -Id $vmHostObject.Id | Select-Object Name, LicenseKey, Uid
    }
}


if ($MyInvocation.InvocationName -ne '.') {
    if (!$VMHost -or !$LicKey) { throw 'Supply -VMHost and -LicKey.' }
    Set-LicenseKey @PSBoundParameters
}
