[CmdletBinding()]
param(
    [string]$Server,
    [pscredential]$Credential
)

$ErrorActionPreference = 'Stop'
if (!$Server -or !$Credential) { throw 'Supply -Server and -Credential.' }
Connect-VIServer -Server $Server -Credential $Credential -Protocol https -Force
