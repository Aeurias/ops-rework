<#!
.SYNOPSIS
    Read-only AzerothCore worldserver, supervisor, watcher, maintenance, and SOAP status.

.DESCRIPTION
    This script only queries processes, task metadata, JSON state, configuration,
    and TCP ports. It never repairs or changes any of them. DryRun/TestScenario
    are non-production display-test hooks.
#>
[CmdletBinding()]
param(
    [switch] $DryRun,
    [ValidateSet('Live','Healthy','Maintenance','StaleSupervisor','PidMismatch','Offline','WatcherError','WatcherDisabled','DuplicateWorld','PathUnavailable','PathMismatch','MissingSupervisor','MalformedSupervisor')]
    [string] $TestScenario = 'Live'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OpsRoot = $PSScriptRoot
$BinDir = 'C:\azeroth\build\bin\RelWithDebInfo'
$WorldExe = Join-Path $BinDir 'worldserver.exe'
$SupervisorScript = Join-Path $OpsRoot 'Worldserver-Supervisor.ps1'
$SupervisorStateFile = Join-Path $OpsRoot 'state\supervisor-state.json'
$MaintenanceMarker = Join-Path $OpsRoot 'state\maintenance-active.json'
$WorldConfig = Join-Path $BinDir 'configs\worldserver.conf'
$SoapCredentialFile = Join-Path $OpsRoot 'state\soap-credential.xml'
$RestartWatcherTaskName = 'AzerothCore Worldserver Restart Watcher'
$SupervisorTaskName = 'AzerothCore Worldserver Supervisor'
$HeartbeatMaxAgeSeconds = 30
$SoapHost = '127.0.0.1'
$SoapPort = 7878
$script:TestWorldStartUtc = [datetime]::UtcNow.AddHours(-1)

function ConvertTo-UtcDateTime {
    param([Parameter(Mandatory)][object] $Value)
    return ([datetime]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
}

function Get-TaskSnapshot {
    param([Parameter(Mandatory)][string] $TaskName)
    if ($DryRun) {
        switch ($TestScenario) {
            'Offline' { return [pscustomobject]@{ Exists = $true; AccessUnavailable = $false; TaskName = $TaskName; Enabled = $false; State = 'Ready'; LastRunTime = $null; LastTaskResult = 0; NextRunTime = $null } }
            'Maintenance' { return [pscustomobject]@{ Exists = $true; AccessUnavailable = $false; TaskName = $TaskName; Enabled = $false; State = 'Ready'; LastRunTime = $null; LastTaskResult = 0; NextRunTime = $null } }
            'WatcherError' { if ($TaskName -eq $RestartWatcherTaskName) { return [pscustomobject]@{ Exists = $true; AccessUnavailable = $false; TaskName = $TaskName; Enabled = $true; State = 'Ready'; LastRunTime = $null; LastTaskResult = 1; NextRunTime = $null } }; return [pscustomobject]@{ Exists = $true; AccessUnavailable = $false; TaskName = $TaskName; Enabled = $true; State = 'Running'; LastRunTime = $null; LastTaskResult = 0; NextRunTime = $null } }
            'WatcherDisabled' { if ($TaskName -eq $RestartWatcherTaskName) { return [pscustomobject]@{ Exists = $true; AccessUnavailable = $false; TaskName = $TaskName; Enabled = $false; State = 'Ready'; LastRunTime = $null; LastTaskResult = 0; NextRunTime = $null } }; return [pscustomobject]@{ Exists = $true; AccessUnavailable = $false; TaskName = $TaskName; Enabled = $true; State = 'Running'; LastRunTime = $null; LastTaskResult = 0; NextRunTime = $null } }
            default { return [pscustomobject]@{ Exists = $true; AccessUnavailable = $false; TaskName = $TaskName; Enabled = $true; State = if ($TaskName -eq $SupervisorTaskName) { 'Running' } else { 'Ready' }; LastRunTime = $null; LastTaskResult = 0; NextRunTime = $null } }
        }
    }
    try { $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { return [pscustomobject]@{ Exists = $false; AccessUnavailable = $false; TaskName = $TaskName; Enabled = $false; State = 'Absent'; LastRunTime = $null; LastTaskResult = $null; NextRunTime = $null } }
    catch { return [pscustomobject]@{ Exists = $null; AccessUnavailable = $true; TaskName = $TaskName; Enabled = $null; State = 'Access unavailable'; LastRunTime = $null; LastTaskResult = $null; NextRunTime = $null } }
    try { $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop } catch { $info = $null }
    [pscustomobject]@{ Exists = $true; AccessUnavailable = $false; TaskName = $TaskName; Enabled = [bool]$task.Settings.Enabled; State = [string]$task.State; LastRunTime = if ($info) { $info.LastRunTime } else { $null }; LastTaskResult = if ($info) { $info.LastTaskResult } else { $null }; NextRunTime = if ($info) { $info.NextRunTime } else { $null } }
}

function Get-WorldserverProcesses {
    if ($DryRun) {
        if ($TestScenario -in @('Offline','Maintenance')) { return @() }
        if ($TestScenario -eq 'DuplicateWorld') { return @([pscustomobject]@{ Pid = 4201; StartTime = $script:TestWorldStartUtc.ToLocalTime(); StartTimeUtc = $script:TestWorldStartUtc; Path = $WorldExe; PathVerification = 'Verified' },[pscustomobject]@{ Pid = 4202; StartTime = $script:TestWorldStartUtc.AddHours(-1).ToLocalTime(); StartTimeUtc = $script:TestWorldStartUtc.AddHours(-1); Path = $WorldExe; PathVerification = 'Verified' }) }
        if ($TestScenario -eq 'PathUnavailable') { return @([pscustomobject]@{ Pid = 4201; StartTime = $script:TestWorldStartUtc.ToLocalTime(); StartTimeUtc = $script:TestWorldStartUtc; Path = $null; PathVerification = 'Unavailable' }) }
        if ($TestScenario -eq 'PathMismatch') { return @([pscustomobject]@{ Pid = 4201; StartTime = $script:TestWorldStartUtc.ToLocalTime(); StartTimeUtc = $script:TestWorldStartUtc; Path = 'C:\unexpected\worldserver.exe'; PathVerification = 'Mismatch' }) }
        return @([pscustomobject]@{ Pid = 4201; StartTime = $script:TestWorldStartUtc.ToLocalTime(); StartTimeUtc = $script:TestWorldStartUtc; Path = $WorldExe; PathVerification = 'Verified' })
    }
    $expected = [IO.Path]::GetFullPath($WorldExe).TrimEnd('\').ToLowerInvariant()
    $processes = @(Get-Process -Name 'worldserver' -ErrorAction SilentlyContinue)
    $result = foreach ($process in $processes) {
        $start = $null
        try { $start = $process.StartTime } catch { }
        $path = $null
        try { if (-not [string]::IsNullOrWhiteSpace([string]$process.Path)) { $path = [string]$process.Path } } catch { }
        if ([string]::IsNullOrWhiteSpace($path)) {
            try {
                $row = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)" -ErrorAction SilentlyContinue
                if ($row -and -not [string]::IsNullOrWhiteSpace([string]$row.ExecutablePath)) { $path = [string]$row.ExecutablePath }
            } catch { }
        }
        $verification = 'Unavailable'
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            try { $verification = if (([IO.Path]::GetFullPath($path).TrimEnd('\').ToLowerInvariant() -eq $expected)) { 'Verified' } else { 'Mismatch' } }
            catch { $verification = 'Mismatch' }
        }
        [pscustomobject]@{
            Pid = [int]$process.Id
            StartTime = $start
            StartTimeUtc = if ($null -ne $start) { $start.ToUniversalTime() } else { $null }
            Path = $path
            PathVerification = $verification
        }
    }
    return @($result)
}

function Read-JsonState {
    param([Parameter(Mandatory)][string] $Path)
    if ($DryRun -and $Path -eq $SupervisorStateFile) {
        $state = [pscustomobject]@{ SupervisorPid = 4200; WorldserverPid = 4201; WorldserverStartTimeUtc = $script:TestWorldStartUtc.ToString('o'); SupervisorStartedUtc = $script:TestWorldStartUtc.ToString('o'); LastHeartbeatUtc = ([datetime]::UtcNow).ToString('o'); Status = 'Supervising'; SupervisorScriptPath = $SupervisorScript }
        if ($TestScenario -eq 'StaleSupervisor') { $state.LastHeartbeatUtc = ([datetime]::UtcNow).AddMinutes(-5).ToString('o') }
        if ($TestScenario -eq 'PidMismatch') { $state.WorldserverPid = 9999 }
        if ($TestScenario -eq 'MalformedSupervisor') { return [pscustomobject]@{ Invalid = $true; Reason = 'test malformed supervisor state' } }
        if ($TestScenario -eq 'MissingSupervisor') { $state.SupervisorPid = 9998 }
        return $state
    }
    try { $item = Get-Item -LiteralPath $Path -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { return $null }
    catch { return [pscustomobject]@{ Unavailable = $true; Reason = $_.Exception.Message } }
    try { return Get-Content -LiteralPath $item.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json }
    catch [System.UnauthorizedAccessException] { return [pscustomobject]@{ Unavailable = $true; Reason = $_.Exception.Message } }
    catch { return [pscustomobject]@{ Invalid = $true; Reason = $_.Exception.Message } }
}

function Read-MaintenanceMarker {
    if ($DryRun) {
        if ($TestScenario -eq 'Maintenance') { return [pscustomobject]@{ Active = $true; StartedUtc = ([datetime]::UtcNow).AddMinutes(-10).ToString('o'); StartedBy = 'TEST\operator'; Reason = 'Manual maintenance' } }
        return $null
    }
    if (-not (Test-Path -LiteralPath $MaintenanceMarker)) { return $null }
    try { return Get-Content -LiteralPath $MaintenanceMarker -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return [pscustomobject]@{ Invalid = $true; Reason = $_.Exception.Message } }
}

function Test-TcpPort {
    param([Parameter(Mandatory)][int] $Port, [int] $TimeoutMilliseconds = 1000)
    if ($DryRun) { return ($TestScenario -ne 'Offline') }
    $client = New-Object System.Net.Sockets.TcpClient
    try { $async = $client.BeginConnect($SoapHost,$Port,$null,$null); if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds,$false)) { return $false }; $client.EndConnect($async); return $true } catch { return $false } finally { $client.Dispose() }
}

function Test-SupervisorProcessIdentity {
    param([Parameter(Mandatory)][int] $SupervisorPid, [Parameter(Mandatory)] $Task)
    if ($DryRun) { return [pscustomobject]@{ Ok = ($TestScenario -ne 'MissingSupervisor'); Reason = if ($TestScenario -eq 'MissingSupervisor') { 'test supervisor PID is absent' } else { 'test supervisor process identity' } } }
    try {
        $process = Get-Process -Id $SupervisorPid -ErrorAction Stop
        if ($process.ProcessName -notmatch '(?i)^(powershell|pwsh)$') { return [pscustomobject]@{ Ok = $false; Reason = 'supervisor PID is not PowerShell' } }
        $row = Get-CimInstance Win32_Process -Filter "ProcessId=$SupervisorPid" -ErrorAction SilentlyContinue
        $commandLine = if ($row) { ([string]$row.CommandLine).ToLowerInvariant().Replace('/','\') } else { '' }
        $expected = [IO.Path]::GetFullPath($SupervisorScript).ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($commandLine)) { return [pscustomobject]@{ Ok = ($commandLine -match [regex]::Escape($expected)); Reason = 'supervisor command-line inspection' } }
        $actionText = if ($Task.Exists) { ($Task.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ' } else { '' }
        return [pscustomobject]@{ Ok = ($Task.Exists -and $Task.State -eq 'Running' -and $actionText.ToLowerInvariant().Replace('/','\') -match [regex]::Escape($expected)); Reason = 'supervisor task action corroboration' }
    } catch { return [pscustomobject]@{ Ok = $false; Reason = $_.Exception.Message } }
}

function Get-RawTask {
    param([Parameter(Mandatory)][string] $TaskName)
    if ($DryRun) { return [pscustomobject]@{ Exists = $true; State = if ($TaskName -eq $SupervisorTaskName) { 'Running' } else { 'Ready' }; Actions = @([pscustomobject]@{ Execute = 'powershell.exe'; Arguments = "-File `"$SupervisorScript`"" }) } }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) { return [pscustomobject]@{ Exists = $false; State = 'Absent'; Actions = @() } }
    return [pscustomobject]@{ Exists = $true; State = [string]$task.State; Actions = @($task.Actions) }
}

function Test-SupervisorHealth {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Worlds, [Parameter(Mandatory)] $TaskSnapshot, [Parameter(Mandatory)] $RawTask, [Parameter(Mandatory)][AllowNull()] $State)
    $age = $null; $pidMatch = $null; $startMatch = $null; $supervisorAlive = $null; $identityOk = $null; $reason = 'healthy'
    if ($null -eq $State) { return [pscustomobject]@{ Ok = $false; Reason = 'supervisor-state.json is missing'; Age = $age; HeartbeatFresh = $null; PidMatch = $pidMatch; StartMatch = $startMatch; SupervisorAlive = $supervisorAlive; ProcessIdentity = $identityOk; StateValid = $false } }
    if ($State.PSObject.Properties.Name -contains 'Unavailable' -and [bool]$State.Unavailable) { return [pscustomobject]@{ Ok = $false; Reason = "supervisor-state.json access unavailable: $($State.Reason)"; Age = $age; HeartbeatFresh = $null; PidMatch = $pidMatch; StartMatch = $startMatch; SupervisorAlive = $supervisorAlive; ProcessIdentity = $identityOk; StateValid = $null } }
    if ($State.PSObject.Properties.Name -contains 'Invalid' -and [bool]$State.Invalid) { return [pscustomobject]@{ Ok = $false; Reason = "supervisor-state.json is invalid: $($State.Reason)"; Age = $age; HeartbeatFresh = $null; PidMatch = $pidMatch; StartMatch = $startMatch; SupervisorAlive = $supervisorAlive; ProcessIdentity = $identityOk; StateValid = $false } }
    foreach ($property in @('SupervisorPid','WorldserverPid','WorldserverStartTimeUtc','LastHeartbeatUtc','Status')) {
        if (-not ($State.PSObject.Properties.Name -contains $property)) { return [pscustomobject]@{ Ok = $false; Reason = "supervisor state lacks $property"; Age = $age; HeartbeatFresh = $null; PidMatch = $pidMatch; StartMatch = $startMatch; SupervisorAlive = $supervisorAlive; ProcessIdentity = $identityOk; StateValid = $false } }
    }
    try { $heartbeat = ConvertTo-UtcDateTime $State.LastHeartbeatUtc; $age = ([datetime]::UtcNow - $heartbeat).TotalSeconds } catch { $reason = "invalid LastHeartbeatUtc: $($_.Exception.Message)" }
    try { $stateStart = ConvertTo-UtcDateTime $State.WorldserverStartTimeUtc } catch { if ($reason -eq 'healthy') { $reason = "invalid WorldserverStartTimeUtc: $($_.Exception.Message)" }; $stateStart = $null }
    try {
        $supervisorPid = [int]$State.SupervisorPid
        $supervisorAlive = if ($DryRun) { $TestScenario -ne 'MissingSupervisor' } else { $null -ne (Get-Process -Id $supervisorPid -ErrorAction SilentlyContinue) }
        $identity = Test-SupervisorProcessIdentity -SupervisorPid $supervisorPid -Task $RawTask
        $identityOk = [bool]$identity.Ok
    } catch { $supervisorAlive = $false; $identityOk = $false; if ($reason -eq 'healthy') { $reason = "invalid SupervisorPid: $($_.Exception.Message)" } }
    if ($Worlds.Count -eq 1) {
        $world = $Worlds[0]
        try { $pidMatch = ([int]$State.WorldserverPid -eq $world.Pid) } catch { $pidMatch = $false }
        if ($null -ne $world.StartTimeUtc -and $null -ne $stateStart) { $startMatch = ($stateStart.Ticks -eq $world.StartTimeUtc.Ticks) }
    }
    $heartbeatFresh = if ($null -eq $age) { $null } else { ($age -ge -5 -and $age -le $HeartbeatMaxAgeSeconds) }
    if ($reason -eq 'healthy' -and [string]$State.Status -ne 'Supervising') { $reason = "status is '$($State.Status)'" }
    elseif ($reason -eq 'healthy' -and $heartbeatFresh -ne $true) { $reason = "heartbeat is $([math]::Round($age,1)) seconds old" }
    elseif ($reason -eq 'healthy' -and (-not $TaskSnapshot.Exists -or -not $TaskSnapshot.Enabled -or $TaskSnapshot.State -ne 'Running')) { $reason = 'supervisor task is not enabled and running' }
    elseif ($reason -eq 'healthy' -and $supervisorAlive -ne $true) { $reason = 'supervisor PID is not alive' }
    elseif ($reason -eq 'healthy' -and $identityOk -ne $true) { $reason = $identity.Reason }
    elseif ($reason -eq 'healthy' -and $Worlds.Count -eq 0) { $reason = 'worldserver is absent' }
    elseif ($reason -eq 'healthy' -and $Worlds.Count -gt 1) { $reason = 'duplicate worldserver processes' }
    elseif ($reason -eq 'healthy' -and $Worlds[0].PathVerification -eq 'Mismatch') { $reason = 'worldserver executable path does not match the expected binary' }
    elseif ($reason -eq 'healthy' -and $pidMatch -ne $true) { $reason = 'state WorldserverPid does not match actual worldserver' }
    elseif ($reason -eq 'healthy' -and $startMatch -ne $true) { $reason = if ($null -eq $startMatch) { 'actual worldserver StartTime is unavailable' } else { 'state WorldserverStartTimeUtc does not match actual worldserver' } }
    return [pscustomobject]@{ Ok = ($reason -eq 'healthy'); Reason = $reason; Age = $age; HeartbeatFresh = $heartbeatFresh; PidMatch = $pidMatch; StartMatch = $startMatch; SupervisorAlive = $supervisorAlive; ProcessIdentity = $identityOk; StateValid = $true }
}

function Format-Value {
    param($Value)
    if ($null -eq $Value) { return 'N/A' }
    return [string]$Value
}

function Format-YesNoUnknown {
    param($Value)
    if ($null -eq $Value) { return 'N/A' }
    if ([bool]$Value) { return 'Yes' }
    return 'No'
}

$worlds = @(Get-WorldserverProcesses)
$world = if ($worlds.Count -eq 1) { $worlds[0] } else { $null }
$supervisorTask = Get-TaskSnapshot -TaskName $SupervisorTaskName
$watcherTask = Get-TaskSnapshot -TaskName $RestartWatcherTaskName
$rawSupervisorTask = Get-RawTask -TaskName $SupervisorTaskName
$supervisorState = Read-JsonState -Path $SupervisorStateFile
$maintenance = Read-MaintenanceMarker
$supervisorHealth = Test-SupervisorHealth -Worlds $worlds -TaskSnapshot $supervisorTask -RawTask $rawSupervisorTask -State $supervisorState
$soapEnabled = $false; $soapIp = 'N/A'; $soapConfiguredPort = 'N/A'
if (Test-Path -LiteralPath $WorldConfig) { foreach($line in Get-Content -LiteralPath $WorldConfig){ if($line -match '^\s*SOAP\.(Enabled|IP|Port)\s*=\s*(.+?)\s*$'){ switch($matches[1]){ 'Enabled'{$soapEnabled=($matches[2].Trim() -eq '1')}; 'IP'{$soapIp=$matches[2].Trim()}; 'Port'{$soapConfiguredPort=$matches[2].Trim()} } } } }
$soapPortReachable = Test-TcpPort -Port $SoapPort

Write-Host '========================================' -ForegroundColor Cyan
Write-Host 'AZEROTHCORE STATUS' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''
Write-Host 'WORLD SERVER' -ForegroundColor Yellow
Write-Host "Running          : $(if($worlds.Count -gt 0){'Yes'}else{'No'})"
Write-Host "PID              : $(if($world){$world.Pid}elseif($worlds.Count -gt 1){'Multiple'}else{'N/A'})"
Write-Host "Start time       : $(if($world -and $world.StartTime){$world.StartTime.ToString('o')}else{'N/A'})"
Write-Host "Uptime           : $(if($world -and $world.StartTime){((Get-Date)-$world.StartTime).ToString()}else{'N/A'})"
Write-Host "Executable path  : $(if($world){if($world.Path){$world.Path}else{'Unavailable in current context'}}else{$WorldExe})"
Write-Host "Path verification: $(if($world){$world.PathVerification}else{'N/A'})"
if ($worlds.Count -gt 1) {
    Write-Host "World processes  : $($worlds.Count) (ERROR - no process selected)" -ForegroundColor Red
    foreach ($item in $worlds) {
        $itemPath = if ($item.Path) { $item.Path } else { 'Unavailable in current context' }
        $itemStart = if ($item.StartTime) { $item.StartTime.ToString('o') } else { 'Unavailable' }
        Write-Host "  PID=$($item.Pid); Start=$itemStart; Path=$itemPath; Verification=$($item.PathVerification)"
    }
}
Write-Host ''
Write-Host 'SUPERVISOR' -ForegroundColor Yellow
Write-Host "Task enabled     : $(if($supervisorTask.AccessUnavailable){'ACCESS UNAVAILABLE'}elseif($supervisorTask.Exists){if($supervisorTask.Enabled){'Enabled'}else{'Disabled'}}else{'MISSING'})"
Write-Host "Task state       : $(Format-Value $supervisorTask.State)"
Write-Host "State file       : $(if($null -eq $supervisorState){'Missing'}elseif($supervisorState.PSObject.Properties.Name -contains 'Unavailable' -and $supervisorState.Unavailable){'ACCESS UNAVAILABLE'}elseif($supervisorState.PSObject.Properties.Name -contains 'Invalid' -and $supervisorState.Invalid){'INVALID'}else{'Present'})"
Write-Host "SupervisorPid    : $(if($supervisorState -and $supervisorState.PSObject.Properties.Name -contains 'SupervisorPid'){$supervisorState.SupervisorPid}else{'N/A'})"
Write-Host "PID alive        : $(Format-YesNoUnknown $supervisorHealth.SupervisorAlive)"
Write-Host "LastHeartbeatUtc : $(if($supervisorState -and $supervisorState.PSObject.Properties.Name -contains 'LastHeartbeatUtc'){$supervisorState.LastHeartbeatUtc}else{'N/A'})"
Write-Host "Heartbeat age    : $(if($null -ne $supervisorHealth.Age){('{0:N1} seconds' -f $supervisorHealth.Age)}else{'N/A'})"
Write-Host "Heartbeat fresh  : $(Format-YesNoUnknown $supervisorHealth.HeartbeatFresh)"
Write-Host "Status           : $(if($supervisorState -and $supervisorState.PSObject.Properties.Name -contains 'Status'){$supervisorState.Status}else{'N/A'})"
Write-Host "WorldserverPid   : $(if($supervisorState -and $supervisorState.PSObject.Properties.Name -contains 'WorldserverPid'){$supervisorState.WorldserverPid}else{'N/A'})"
Write-Host "State StartTime  : $(if($supervisorState -and $supervisorState.PSObject.Properties.Name -contains 'WorldserverStartTimeUtc'){$supervisorState.WorldserverStartTimeUtc}else{'N/A'})"
Write-Host "PID matches      : $(Format-YesNoUnknown $supervisorHealth.PidMatch)"
Write-Host "StartTime matches: $(Format-YesNoUnknown $supervisorHealth.StartMatch)"
$supervisorValidity = if ($supervisorHealth.Ok -and $world -and $world.PathVerification -eq 'Unavailable') { 'Degraded (PID/start-time match; executable path unavailable in current context)' } elseif ($supervisorHealth.Ok) { 'Yes' } else { "No ($($supervisorHealth.Reason))" }
Write-Host "Supervisor valid : $supervisorValidity"
Write-Host ''
Write-Host 'RESTART WATCHER' -ForegroundColor Yellow
Write-Host "Task enabled     : $(if($watcherTask.AccessUnavailable){'ACCESS UNAVAILABLE'}elseif($watcherTask.Exists){if($watcherTask.Enabled){'Enabled'}else{'Disabled'}}else{'MISSING'})"
Write-Host "State            : $(Format-Value $watcherTask.State)"
Write-Host "LastRunTime      : $(Format-Value $watcherTask.LastRunTime)"
Write-Host "LastTaskResult   : $(Format-Value $watcherTask.LastTaskResult)"
Write-Host "NextRunTime      : $(Format-Value $watcherTask.NextRunTime)"
Write-Host ''
Write-Host 'MAINTENANCE' -ForegroundColor Yellow
Write-Host "Marker present   : $(if($null -ne $maintenance){'Yes'}else{'No'})"
Write-Host "StartedUtc       : $(if($maintenance -and $maintenance.PSObject.Properties.Name -contains 'StartedUtc'){$maintenance.StartedUtc}else{'N/A'})"
Write-Host "StartedBy        : $(if($maintenance -and $maintenance.PSObject.Properties.Name -contains 'StartedBy'){$maintenance.StartedBy}else{'N/A'})"
Write-Host "Reason           : $(if($maintenance -and $maintenance.PSObject.Properties.Name -contains 'Reason'){$maintenance.Reason}else{'N/A'})"
Write-Host ''
Write-Host 'SOAP' -ForegroundColor Yellow
Write-Host "Enabled          : $soapEnabled"
Write-Host "Configured IP    : $soapIp"
Write-Host "Configured port  : $soapConfiguredPort"
Write-Host "127.0.0.1:7878   : $(if($soapPortReachable){'Reachable'}else{'Unreachable'})"

$maintenanceActive = $maintenance -and $maintenance.PSObject.Properties.Name -contains 'Active' -and [bool]$maintenance.Active
$maintenanceInvalid = $maintenance -and $maintenance.PSObject.Properties.Name -contains 'Invalid' -and [bool]$maintenance.Invalid
$overall = 'ERROR'
if ($worlds.Count -gt 1) { $overall = 'ERROR' }
elseif ($maintenanceInvalid) { $overall = 'ERROR' }
elseif ($maintenanceActive -and ($watcherTask.Enabled -or $supervisorTask.Enabled)) { $overall = 'ERROR' }
elseif ($maintenanceActive -and $worlds.Count -eq 0 -and -not $watcherTask.Enabled -and -not $supervisorTask.Enabled) { $overall = 'MAINTENANCE' }
elseif ($worlds.Count -eq 0 -and -not $maintenanceActive) { $overall = 'OFFLINE' }
elseif ($world -and $world.PathVerification -eq 'Mismatch') { $overall = 'ERROR' }
elseif ($supervisorHealth.StateValid -eq $false) { $overall = 'ERROR' }
elseif ($world -and $world.PathVerification -eq 'Unavailable') { $overall = 'DEGRADED' }
elseif ($world -and $supervisorHealth.Ok -and $watcherTask.Exists -and $watcherTask.Enabled -and $watcherTask.State -ne 'Disabled' -and ($null -eq $watcherTask.LastTaskResult -or [int64]$watcherTask.LastTaskResult -eq 0)) { $overall = 'HEALTHY' }
elseif ($world) { $overall = 'DEGRADED' }
Write-Host ''
Write-Host "OVERALL STATE: $overall" -ForegroundColor $(if($overall -in @('HEALTHY','MAINTENANCE')){'Green'}elseif($overall -eq 'DEGRADED'){'Yellow'}else{'Red'})
if ($overall -eq 'HEALTHY') { exit 0 }
if ($overall -eq 'MAINTENANCE') { exit 0 }
exit 1
