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
    [switch] $InspectInteractive,
    [switch] $ReplaceExisting,
    [string] $InspectionTaskName = 'AzerothCore Worldserver Restart Watcher (Inspection)'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'Restart-Watcher.ps1'
$credentialPath = Join-Path $PSScriptRoot 'state\soap-credential.xml'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script from an elevated PowerShell.' }
if ($Remove) {
    $removeTaskName = if ($InspectOnly) { $InspectionTaskName } else { $TaskName }
    if (Get-ScheduledTask -TaskName $removeTaskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $removeTaskName -Confirm:$false; Write-Host "Removed $removeTaskName." } else { Write-Host "Not present: $removeTaskName" }
    exit 0
}
if ($InspectOnly -and $Enable) { throw '-InspectOnly cannot be combined with -Enable.' }
if ($InspectInteractive -and -not $InspectOnly) { throw '-InspectInteractive requires -InspectOnly.' }
$effectiveTaskName = if ($InspectOnly) { $InspectionTaskName } else { $TaskName }
if ($InspectOnly -and $effectiveTaskName -eq $TaskName) { throw 'Inspection task name must be distinct from the production task name.' }
if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Missing $scriptPath" }
if (-not (Test-Path -LiteralPath $credentialPath) -and -not $InspectInteractive) { throw "Missing DPAPI credential file $credentialPath. Run Set-SoapCredential.ps1 as $RunAsUser first." }
$existingTask = Get-ScheduledTask -TaskName $effectiveTaskName -ErrorAction SilentlyContinue
if (-not $InspectOnly -and $null -ne $existingTask -and -not $ReplaceExisting) {
    throw "Production task '$TaskName' already exists. Refusing to change it without -ReplaceExisting."
}
$wasEnabled = if ($null -ne $existingTask) { [bool]$existingTask.Settings.Enabled } else { $false }
$shouldEnable = if ($InspectOnly) { $false } elseif ($Enable) { $true } elseif ($null -ne $existingTask) { $wasEnabled } else { $false }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath) -WorkingDirectory $PSScriptRoot
$start = (Get-Date).AddMinutes(1)
$trigger = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = if ($InspectInteractive) { New-ScheduledTaskPrincipal -UserId $RunAsUser -LogonType Interactive -RunLevel Highest } else { New-ScheduledTaskPrincipal -UserId $RunAsUser -LogonType Password -RunLevel Highest }
$description = 'Uptime-based worldserver maintenance watcher; validates the exact live supervisor, writes an exact automatic ticket, announces, and requests graceful localhost SOAP server shutdown 300. Preflight only is read-only.'

if ($InspectInteractive) {
    $task = Register-ScheduledTask -TaskName $effectiveTaskName -Description $description -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
} else {
    $taskCredential = Get-Credential -UserName $RunAsUser -Message 'Windows password for the identity that provisioned the DPAPI SOAP credential'
    $task = Register-ScheduledTask -TaskName $effectiveTaskName -Description $description -Action $action -Trigger $trigger -Settings $settings -User $taskCredential.UserName -Password $taskCredential.GetNetworkCredential().Password -RunLevel Highest -Force
}
if ($shouldEnable) { Enable-ScheduledTask -TaskName $effectiveTaskName | Out-Null } else { Disable-ScheduledTask -TaskName $effectiveTaskName | Out-Null }
if ($InspectOnly -or -not $shouldEnable) { Write-Host "Registered disabled task for inspection: $effectiveTaskName" } else { Write-Host "Registered and enabled: $effectiveTaskName" }
Get-ScheduledTask -TaskName $effectiveTaskName | Select-Object TaskName,State,@{n='StartWhenAvailable';e={$_.Settings.StartWhenAvailable}},@{n='MultipleInstances';e={$_.Settings.MultipleInstances}},@{n='ExecutionTimeLimit';e={$_.Settings.ExecutionTimeLimit}},@{n='Principal';e={$_.Principal.UserId}},@{n='Action';e={($_.Actions | ForEach-Object { $_.Execute + ' ' + $_.Arguments })}},@{n='Trigger';e={($_.Triggers | ForEach-Object { $_.StartBoundary + ' repetition=' + $_.Repetition.Interval + ' duration=' + $_.Repetition.Duration })}} | Format-List
