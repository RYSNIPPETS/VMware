[CmdletBinding()]
param(
    [string]$InstallerPath,
    [string]$TemplatePath,
    [string]$OutputPath,
    [hashtable]$Setting = @{},
    [switch]$NoSslCertificateVerification,
    [switch]$SkipDeployment
)

$ErrorActionPreference = 'Stop'

function Set-JsonValueByPath {
    <#
    .SYNOPSIS
    Updates a JSON object by using a slash-delimited property path.
    .DESCRIPTION
    The path format is /section/subsection/property. This avoids ambiguity with
    JSON keys that contain periods in their names.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$InputObject,

        [Parameter(Mandatory)]
        [string]$Path,

        [AllowNull()]
        $Value
    )

    $segments = $Path.Trim("/") -split "/"
    if (-not $segments -or [string]::IsNullOrWhiteSpace($segments[0])) {
        throw "Invalid JSON path [$Path]. Use a slash-delimited path such as /new_vcsa/esxi/hostname."
    }

    $current = $InputObject

    for ($index = 0; $index -lt ($segments.Count - 1); $index++) {
        $segment = $segments[$index]
        $property = $current.PSObject.Properties[$segment]

        if (-not $property) {
            $child = [pscustomobject]@{}
            $current | Add-Member -MemberType NoteProperty -Name $segment -Value $child
            $current = $child
            continue
        }

        if ($null -eq $property.Value) {
            $property.Value = [pscustomobject]@{}
        }

        $current = $property.Value
    }

    $leafName = $segments[-1]
    $leafProperty = $current.PSObject.Properties[$leafName]

    if ($leafProperty) {
        $leafProperty.Value = $Value
    }
    else {
        $current | Add-Member -MemberType NoteProperty -Name $leafName -Value $Value
    }
}

function Invoke-VcsaCliInstall {
    <#
    .SYNOPSIS
    Deploys a modern vCenter Server Appliance by using the supported CLI installer.
    .DESCRIPTION
    This script starts from one of the JSON templates shipped with the vCenter
    ISO, applies override values, writes a generated configuration file, and
    optionally runs vcsa-deploy install.
    .PARAMETER InstallerPath
    Path to the current vcsa-deploy executable, for example
    D:\vcsa-cli-installer\win32\vcsa-deploy.exe.
    .PARAMETER TemplatePath
    Path to a current installer template, for example
    D:\vcsa-cli-installer\templates\install\embedded_vCSA_on_ESXi.json.
    .PARAMETER OutputPath
    Path where the generated JSON file should be written.
    .PARAMETER Setting
    Hashtable of slash-delimited JSON paths to values. Example:
    @{
        "/new_vcsa/esxi/hostname" = "esxi01.contoso.com"
        "/new_vcsa/esxi/username" = "root"
        "/new_vcsa/esxi/password" = $password
        "/new_vcsa/appliance/name" = "vcsa01"
        "/new_vcsa/network/ip_family" = "ipv4"
        "/new_vcsa/network/mode" = "static"
        "/new_vcsa/network/ip" = "10.0.0.10"
        "/new_vcsa/network/prefix" = "24"
        "/new_vcsa/network/gateway" = "10.0.0.1"
        "/new_vcsa/network/dns_servers" = @("10.0.0.5", "10.0.0.6")
        "/new_vcsa/os/password" = $password
        "/new_vcsa/os/ntp_servers" = "0.pool.ntp.org"
        "/new_vcsa/sso/password" = $password
        "/new_vcsa/sso/domain_name" = "vsphere.local"
        "/new_vcsa/sso/site_name" = "Default-First-Site"
        "/ceip/settings/ceip_enabled" = $false
    }
    .PARAMETER NoSslCertificateVerification
    Adds the CLI flag that skips SSL verification during deployment.
    .PARAMETER SkipDeployment
    Generates the updated JSON file without running the installer.
    .EXAMPLE
    $settings = @{
        "/new_vcsa/esxi/hostname" = "esxi01.contoso.com"
        "/new_vcsa/esxi/username" = "root"
        "/new_vcsa/esxi/password" = $password
        "/new_vcsa/appliance/name" = "vcsa01"
    }
    Invoke-VcsaCliInstall -InstallerPath "D:\vcsa-cli-installer\win32\vcsa-deploy.exe" `
        -TemplatePath "D:\vcsa-cli-installer\templates\install\embedded_vCSA_on_ESXi.json" `
        -OutputPath "C:\Temp\vcsa-install.generated.json" `
        -Setting $settings `
        -NoSslCertificateVerification
    #>
    [CmdletBinding()]
    param(
        [string]$InstallerPath,

        [string]$TemplatePath,

        [string]$OutputPath,

        [hashtable]$Setting = @{},

        [switch]$NoSslCertificateVerification,

        [switch]$SkipDeployment
    )

    if (!$SkipDeployment -and (!$InstallerPath -or !(Test-Path -LiteralPath $InstallerPath -PathType Leaf))) {
        throw "Installer path [$InstallerPath] was not found."
    }

    if (!$TemplatePath -or !(Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        throw "Template path [$TemplatePath] was not found."
    }

    $ephemeral = !$OutputPath -and !$SkipDeployment
    if (!$OutputPath) {
        $OutputPath = Join-Path ([IO.Path]::GetTempPath()) ("vcsa-{0}.json" -f [guid]::NewGuid())
    }
    $outputFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $templateFile = (Get-Item -LiteralPath $TemplatePath).FullName
    if ($outputFile -eq $templateFile) { throw 'Choose an output file separate from the template.' }
    $config = Get-Content -LiteralPath $TemplatePath -Raw | ConvertFrom-Json -Depth 100
    foreach ($entry in ($Setting.GetEnumerator() | Sort-Object Key)) {
        Set-JsonValueByPath -InputObject $config -Path $entry.Key -Value $entry.Value
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($config | ConvertTo-Json -Depth 100))
    $directory = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputFile))
    $stage = Join-Path $directory.FullName ([IO.Path]::GetRandomFileName())
    try {
        if ($IsWindows) {
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl = [Security.AccessControl.FileSecurity]::new()
            $acl.SetAccessRuleProtection($true, $false)
            $acl.SetOwner($sid)
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
            $stream = [IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($stage), 'CreateNew', 'FullControl', 'None', 4096, 'None', $acl)
        }
        else {
            $options = [IO.FileStreamOptions]::new()
            $options.Mode = 'CreateNew'
            $options.Access = 'Write'
            $options.Share = 'None'
            $options.UnixCreateMode = [IO.UnixFileMode]'UserRead,UserWrite'
            $stream = [IO.File]::Open($stage, $options)
        }
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        [IO.File]::Move($stage, $outputFile, $true)
        if ($SkipDeployment) { Get-Item -LiteralPath $outputFile; return }

        $arguments = @('install', '--accept-eula')
        if ($NoSslCertificateVerification) { $arguments += '--no-ssl-certificate-verification' }
        $arguments += $outputFile
        & (Get-Item -LiteralPath $InstallerPath).FullName @arguments
        if ($LASTEXITCODE -ne 0) { throw "vcsa-deploy failed with exit code $LASTEXITCODE." }
    }
    finally {
        [IO.File]::Delete($stage)
        if ($ephemeral) { [IO.File]::Delete($outputFile) }
    }
}

if ($PSBoundParameters.Count -gt 0) { Invoke-VcsaCliInstall @PSBoundParameters }
