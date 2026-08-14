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
    [switch] $InspectOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'Worldserver-Supervisor.ps1'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script from an elevated PowerShell.' }
if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Write-Host "Removed $TaskName." } else { Write-Host "Not present: $TaskName" }
    exit 0
}
if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Missing $scriptPath" }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $scriptPath) -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $RunAsUser
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId $RunAsUser -LogonType Interactive -RunLevel Highest
$description = 'Persistent conservative worldserver owner; relaunches only AzerothCore intentional restart exit code 2 and publishes a heartbeat.'

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
Register-ScheduledTask -TaskName $TaskName -Description $description -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Disable-ScheduledTask -TaskName $TaskName | Out-Null
if ($Enable) { Enable-ScheduledTask -TaskName $TaskName | Out-Null }
if ($InspectOnly -or -not $Enable) { Write-Host "Registered disabled supervisor task for inspection: $TaskName" } else { Write-Host "Registered and enabled: $TaskName" }
Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName,State,@{n='StartWhenAvailable';e={$_.Settings.StartWhenAvailable}},@{n='MultipleInstances';e={$_.Settings.MultipleInstances}},@{n='ExecutionTimeLimit';e={$_.Settings.ExecutionTimeLimit}},@{n='Principal';e={$_.Principal.UserId}},@{n='LogonType';e={$_.Principal.LogonType}},@{n='Action';e={($_.Actions | ForEach-Object { $_.Execute + ' ' + $_.Arguments })}},@{n='Trigger';e={($_.Triggers | ForEach-Object { $_.TriggerType + ' user=' + $_.UserId })}} | Format-List
