[CmdletBinding()]
param(
    [string]$Server
)

function Get-VSphereClientUrl {
    <#
    .SYNOPSIS
    Returns the browser URL for the modern vSphere Client.
    .DESCRIPTION
    The legacy Windows vSphere Client has been retired. Current environments are
    managed through the browser-based vSphere Client at /ui.
    .PARAMETER Server
    The vCenter Server FQDN or IP address.
    .EXAMPLE
    Get-VSphereClientUrl -Server "vcsa01.contoso.com"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Server
    )

    $address = $null
    $inputName = $Server.Trim()
    if ([ipaddress]::TryParse($inputName.Trim('[', ']'), [ref]$address)) {
        $builder = [UriBuilder]::new('https', $address.ToString())
    }
    else {
        if ($inputName -notmatch '^https?://') { $inputName = "https://$inputName" }
        $builder = [UriBuilder]::new($inputName)
        if (!$builder.Host -or $builder.UserName -or $builder.Password -or $builder.Query -or $builder.Fragment -or $builder.Path.Trim('/') -notin '', 'ui') { throw 'Supply a vCenter host name, IP address or client URL.' }
        if ($builder.Scheme -eq 'http' -and $builder.Port -eq 80) { $builder.Port = -1 }
        $builder.Scheme = 'https'
    }
    $builder.Path = '/ui'
    [pscustomobject]@{
        Server = $builder.Uri.Authority
        Url    = $builder.Uri.AbsoluteUri
        Note   = "Use the browser-based vSphere Client. The legacy Windows client is no longer installed separately."
    }
}

if ($PSBoundParameters.Count -gt 0) {
    Get-VSphereClientUrl @PSBoundParameters
}
