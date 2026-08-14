<#!
.SYNOPSIS
    Creates the disabled-by-default persistent supervisor task.

.DESCRIPTION
    The actual VM uses an interactive server session, so the supervisor is launched
    at logon for the intended server account with an Interactive principal. This
    preserves the possibility of seeing a console, but it also means the supervisor
    is unavailable while that account is logged off. The watcher remains fail-safe
    and skips maintenance whenever the supervisor heartbeat is absent or stale.
#>
[CmdletBinding()]
param(
    [string] $TaskName = 'AzerothCore Worldserver Supervisor',
    [string] $RunAsUser = "$env:USERDOMAIN\$env:USERNAME",
    [switch] $Enable,
    [switch] $Remove,
    [switch] $InspectOnly,
    [switch] $ReplaceExisting,
    [string] $InspectionTaskName = 'AzerothCore Worldserver Supervisor (Inspection)'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'Worldserver-Supervisor.ps1'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script from an elevated PowerShell.' }
if ($Remove) {
    $removeTaskName = if ($InspectOnly) { $InspectionTaskName } else { $TaskName }
    if (Get-ScheduledTask -TaskName $removeTaskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $removeTaskName -Confirm:$false; Write-Host "Removed $removeTaskName." } else { Write-Host "Not present: $removeTaskName" }
    exit 0
}
if ($InspectOnly -and $Enable) { throw '-InspectOnly cannot be combined with -Enable.' }
$effectiveTaskName = if ($InspectOnly) { $InspectionTaskName } else { $TaskName }
if ($InspectOnly -and $effectiveTaskName -eq $TaskName) { throw 'Inspection task name must be distinct from the production task name.' }
if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Missing $scriptPath" }
$existingTask = Get-ScheduledTask -TaskName $effectiveTaskName -ErrorAction SilentlyContinue
if (-not $InspectOnly -and $null -ne $existingTask -and -not $ReplaceExisting) {
    throw "Production task '$TaskName' already exists. Refusing to change it without -ReplaceExisting."
}
$wasEnabled = if ($null -ne $existingTask) { [bool]$existingTask.Settings.Enabled } else { $false }
$shouldEnable = if ($InspectOnly) { $false } elseif ($Enable) { $true } elseif ($null -ne $existingTask) { $wasEnabled } else { $false }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $scriptPath) -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $RunAsUser
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId $RunAsUser -LogonType Interactive -RunLevel Highest
$description = 'Persistent conservative worldserver owner; relaunches only from an exact unexpired Accepted automatic ticket for the exited PID/start time. Exit code is diagnostic only; publishes a heartbeat.'

Register-ScheduledTask -TaskName $effectiveTaskName -Description $description -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
if ($shouldEnable) { Enable-ScheduledTask -TaskName $effectiveTaskName | Out-Null } else { Disable-ScheduledTask -TaskName $effectiveTaskName | Out-Null }
if ($InspectOnly -or -not $shouldEnable) { Write-Host "Registered disabled supervisor task for inspection: $effectiveTaskName" } else { Write-Host "Registered and enabled: $effectiveTaskName" }
Get-ScheduledTask -TaskName $effectiveTaskName | Select-Object TaskName,State,@{n='StartWhenAvailable';e={$_.Settings.StartWhenAvailable}},@{n='MultipleInstances';e={$_.Settings.MultipleInstances}},@{n='ExecutionTimeLimit';e={$_.Settings.ExecutionTimeLimit}},@{n='Principal';e={$_.Principal.UserId}},@{n='LogonType';e={$_.Principal.LogonType}},@{n='Action';e={($_.Actions | ForEach-Object { $_.Execute + ' ' + $_.Arguments })}},@{n='Trigger';e={($_.Triggers | ForEach-Object { $_.TriggerType + ' user=' + $_.UserId })}} | Format-List
