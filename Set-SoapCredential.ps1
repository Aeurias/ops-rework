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
    [string] $CredentialPath = (Join-Path $PSScriptRoot 'state\soap-credential.xml'),
    [Management.Automation.PSCredential] $Credential,
    [switch] $TestFailAfterReplacement
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CredentialPath = [IO.Path]::GetFullPath($CredentialPath)
$testArtifactRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'test-artifacts'))
 $tempTestRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'ops-rework-credential-test'))
if ($TestFailAfterReplacement -and -not ($CredentialPath.StartsWith($testArtifactRoot + '\',[StringComparison]::OrdinalIgnoreCase) -or $CredentialPath.StartsWith($tempTestRoot + '\',[StringComparison]::OrdinalIgnoreCase))) {
    throw '-TestFailAfterReplacement is restricted to test-artifacts paths.'
}
$stateDir = Split-Path -Parent $CredentialPath
if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
if ($null -eq $Credential) { $Credential = Get-Credential -UserName $SoapUsername -Message 'Enter the AzerothCore SOAP username and password. The password is DPAPI-protected and never logged.' }
if ($Credential.UserName -ne $SoapUsername) { throw "Use the intended SOAP username '$SoapUsername'." }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
function Set-CredentialFileAcl {
    param([Parameter(Mandatory)][string] $Path)
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($existingRule in @($acl.Access)) { [void]$acl.RemoveAccessRuleAll($existingRule) }
    foreach ($entry in @([pscustomobject]@{Name=$identity;Rights='Modify'},[pscustomobject]@{Name='NT AUTHORITY\SYSTEM';Rights='ReadAndExecute'},[pscustomobject]@{Name='BUILTIN\Administrators';Rights='ReadAndExecute'})) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($entry.Name,$entry.Rights,'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

$tmp = '{0}.{1}.tmp' -f $CredentialPath, ([guid]::NewGuid().ToString('N'))
$backup = '{0}.{1}.lastgood.bak' -f $CredentialPath, ([guid]::NewGuid().ToString('N'))
$replacementCompleted = $false
$rotationSucceeded = $false
$backupPreserved = $false
try {
    $Credential | Export-Clixml -LiteralPath $tmp
    Set-CredentialFileAcl -Path $tmp
    $roundTrip = Import-Clixml -LiteralPath $tmp
    if ($roundTrip -isnot [Management.Automation.PSCredential] -or [string]$roundTrip.UserName -ne $SoapUsername) { throw 'DPAPI credential verification failed before replacement.' }
    if (Test-Path -LiteralPath $CredentialPath) { [IO.File]::Replace($tmp,$CredentialPath,$backup,$true) } else { [IO.File]::Move($tmp,$CredentialPath) }
    $replacementCompleted = $true
    if ($TestFailAfterReplacement) { throw 'Injected post-replacement failure for isolated credential recovery testing.' }
    Set-CredentialFileAcl -Path $CredentialPath
    $finalRoundTrip = Import-Clixml -LiteralPath $CredentialPath
    if ($finalRoundTrip -isnot [Management.Automation.PSCredential] -or [string]$finalRoundTrip.UserName -ne $SoapUsername) { throw 'DPAPI credential verification failed after replacement.' }
    $rotationSucceeded = $true
} catch {
    if ($replacementCompleted -and (Test-Path -LiteralPath $backup)) {
        $restoreResidual = '{0}.{1}.restore-failed.bak' -f $CredentialPath, ([guid]::NewGuid().ToString('N'))
        try {
            [IO.File]::Replace($backup,$CredentialPath,$restoreResidual,$true)
            if (Test-Path -LiteralPath $restoreResidual) { Remove-Item -LiteralPath $restoreResidual -Force -ErrorAction SilentlyContinue }
            Write-Warning 'Credential rotation failed after replacement; the previous credential was restored.'
        } catch {
            $backupPreserved = $true
            throw "Credential rotation failed and restoration also failed. Preserve and inspect the known-good backup at $backup. Original error: $($_.Exception.Message)"
        }
    }
    throw
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    if ($rotationSucceeded -and (Test-Path -LiteralPath $backup)) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
    elseif (-not $backupPreserved -and -not $replacementCompleted -and (Test-Path -LiteralPath $backup)) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
}
Write-Host "SOAP credential stored at $CredentialPath for DPAPI identity $identity."
Write-Host 'The scheduled task must run as this same Windows identity; SYSTEM cannot decrypt this file.'
