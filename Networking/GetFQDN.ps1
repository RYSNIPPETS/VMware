param([string]$Path = './VMs.csv')
Import-Csv -LiteralPath $Path | ForEach-Object { Get-VM -Name ([WildcardPattern]::Escape($_.Name)) -ErrorAction Stop } |
    Select-Object Name, @{Name='FQDN'; Expression= {
            $dns = $_.ExtensionData.Guest.IpStack.DnsConfig | Where-Object HostName | Select-Object -First 1
            if ($dns.HostName) {
                if ($dns.DomainName -and $dns.HostName -notlike '*.*') { "$($dns.HostName).$($dns.DomainName)" } else { $dns.HostName }
            }
        }
    } | Export-Csv ./FQDN.csv
