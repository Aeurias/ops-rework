<#!
.SYNOPSIS
    Provision the SOAP PSCredential encrypted for the identity that runs the task.

.DESCRIPTION
    Export-Clixml uses Windows DPAPI.  The resulting file is intentionally tied to
    the current Windows user profile; run this script as the same identity selected
    for the scheduled watcher.  The password is never written to this source file
    or printed.
#>
[CmdletBinding()]
param(
    [string] $SoapUsername = 'restartbot',
    [string] $CredentialPath = (Join-Path $PSScriptRoot 'state\soap-credential.xml')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stateDir = Split-Path -Parent $CredentialPath
if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$credential = Get-Credential -UserName $SoapUsername -Message 'Enter the AzerothCore SOAP username and password. The password is DPAPI-protected and never logged.'
if ($credential.UserName -ne $SoapUsername) { throw "Use the intended SOAP username '$SoapUsername'." }

$tmp = '{0}.{1}.tmp' -f $CredentialPath, ([guid]::NewGuid().ToString('N'))
$credential | Export-Clixml -LiteralPath $tmp
Move-Item -LiteralPath $tmp -Destination $CredentialPath -Force

$acl = Get-Acl -LiteralPath $CredentialPath
$acl.SetAccessRuleProtection($true,$false)
$acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
foreach ($entry in @($identity,'NT AUTHORITY\SYSTEM','BUILTIN\Administrators')) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($entry,'Read','Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $CredentialPath -AclObject $acl
Write-Host "SOAP credential stored at $CredentialPath for DPAPI identity $identity."
Write-Host 'The scheduled task must run as this same Windows identity; SYSTEM cannot decrypt this file.'
