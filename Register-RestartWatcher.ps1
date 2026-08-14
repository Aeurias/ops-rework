<#!
.SYNOPSIS
    Creates the one-minute AzerothCore worldserver restart watcher task.

.DESCRIPTION
    Registration defaults to a disabled task for XML inspection.  Use -Enable only
    after review and an administrator-controlled rollout decision.  No legacy task
    is recreated and no StartWhenAvailable setting is emitted.
#>
[CmdletBinding()]
param(
    [string] $TaskName = 'AzerothCore Worldserver Restart Watcher',
    [string] $RunAsUser = "$env:USERDOMAIN\$env:USERNAME",
    [switch] $Enable,
    [switch] $Remove,
    [switch] $InspectOnly,
    [switch] $InspectInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'Restart-Watcher.ps1'
$credentialPath = Join-Path $PSScriptRoot 'state\soap-credential.xml'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script from an elevated PowerShell.' }
if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Write-Host "Removed $TaskName." } else { Write-Host "Not present: $TaskName" }
    exit 0
}
if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Missing $scriptPath" }
if (-not (Test-Path -LiteralPath $credentialPath) -and -not $InspectInteractive) { throw "Missing DPAPI credential file $credentialPath. Run Set-SoapCredential.ps1 as $RunAsUser first." }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath) -WorkingDirectory $PSScriptRoot
$start = (Get-Date).AddMinutes(1)
$trigger = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = if ($InspectInteractive) { New-ScheduledTaskPrincipal -UserId $RunAsUser -LogonType Interactive -RunLevel Highest } else { New-ScheduledTaskPrincipal -UserId $RunAsUser -LogonType Password -RunLevel Highest }
$description = 'Read-only uptime watcher that requests only a graceful localhost SOAP worldserver restart; SOAP failure does nothing.'

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
if ($InspectInteractive) {
    if (-not $InspectOnly -or $Enable) { throw '-InspectInteractive is only for a disabled inspection task.' }
    $task = Register-ScheduledTask -TaskName $TaskName -Description $description -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
} else {
    $taskCredential = Get-Credential -UserName $RunAsUser -Message 'Windows password for the identity that provisioned the DPAPI SOAP credential'
    $task = Register-ScheduledTask -TaskName $TaskName -Description $description -Action $action -Trigger $trigger -Settings $settings -User $taskCredential.UserName -Password $taskCredential.GetNetworkCredential().Password -RunLevel Highest -Force
}
Disable-ScheduledTask -TaskName $TaskName | Out-Null
if ($Enable) { Enable-ScheduledTask -TaskName $TaskName | Out-Null }
if ($InspectOnly -or -not $Enable) { Write-Host "Registered disabled task for inspection: $TaskName" } else { Write-Host "Registered and enabled: $TaskName" }
Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName,State,@{n='StartWhenAvailable';e={$_.Settings.StartWhenAvailable}},@{n='MultipleInstances';e={$_.Settings.MultipleInstances}},@{n='ExecutionTimeLimit';e={$_.Settings.ExecutionTimeLimit}},@{n='Principal';e={$_.Principal.UserId}},@{n='Action';e={($_.Actions | ForEach-Object { $_.Execute + ' ' + $_.Arguments })}},@{n='Trigger';e={($_.Triggers | ForEach-Object { $_.StartBoundary + ' repetition=' + $_.Repetition.Interval + ' duration=' + $_.Repetition.Duration })}} | Format-List
