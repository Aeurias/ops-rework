[CmdletBinding()]
param([string] $TestRoot = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { (Get-Location).Path } else { $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($TestRoot)) { $TestRoot = Join-Path ([IO.Path]::GetTempPath()) 'ops-rework-credential-test' }
if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }
New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null
$path = Join-Path $TestRoot 'soap-credential.xml'
$first = [pscredential]::new('restartbot',(ConvertTo-SecureString 'dummy-one-not-production' -AsPlainText -Force))
$second = [pscredential]::new('restartbot',(ConvertTo-SecureString 'dummy-two-not-production' -AsPlainText -Force))
& (Join-Path $PSScriptRoot 'Set-SoapCredential.ps1') -CredentialPath $path -Credential $first | Out-Null
$firstRead = Import-Clixml -LiteralPath $path
try { & (Join-Path $PSScriptRoot 'Set-SoapCredential.ps1') -CredentialPath $path -Credential $second -TestFailAfterReplacement 2>&1 | Out-Null } catch { }
$restoredRead = Import-Clixml -LiteralPath $path
$backupAfterFailure = @(Get-ChildItem -LiteralPath $TestRoot -Filter '*.lastgood.bak')
& (Join-Path $PSScriptRoot 'Set-SoapCredential.ps1') -CredentialPath $path -Credential $second | Out-Null
$secondRead = Import-Clixml -LiteralPath $path
$acl = Get-Acl -LiteralPath $path
$result = [pscustomobject]@{
    FirstCredentialRoundTrip = ($firstRead.UserName -eq 'restartbot')
    PostReplacementFailureRestored = ($restoredRead.GetNetworkCredential().Password -eq 'dummy-one-not-production' -and $backupAfterFailure.Count -eq 0)
    SecondCredentialRoundTrip = ($secondRead.UserName -eq 'restartbot')
    RotationChanged = ($secondRead.GetNetworkCredential().Password -eq 'dummy-two-not-production')
    TemporaryFilesClean = (@(Get-ChildItem -LiteralPath $TestRoot -Filter '*.tmp').Count -eq 0)
    BackupFilesClean = (@(Get-ChildItem -LiteralPath $TestRoot -Filter '*.lastgood.bak').Count -eq 0)
    ProvisioningIdentityCanModify = (@($acl.Access | Where-Object { $_.IdentityReference.ToString() -eq [Security.Principal.WindowsIdentity]::GetCurrent().Name -and $_.FileSystemRights.ToString() -match 'Modify' }).Count -gt 0)
}
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $TestRoot 'result.json') -Encoding UTF8
if (@($result.PSObject.Properties | Where-Object { $_.Value -ne $true }).Count -gt 0) { exit 1 }
Write-Host 'Credential rotation dummy test passed.'
