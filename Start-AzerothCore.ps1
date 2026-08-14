<#!
.SYNOPSIS
    Safely leave manual maintenance and restore the existing supervisor/watcher.

.DESCRIPTION
    The supervisor remains responsible for starting or adopting worldserver.exe.
    This script never launches worldserver.exe directly. The watcher remains
    disabled until supervisor heartbeat validation and the existing read-only
    Restart-Watcher.ps1 -Preflight both succeed.
#>
[CmdletBinding()]
param(
    [switch] $DryRun,
    [ValidateSet('Live','Healthy','AlreadyHealthy','MissingTask','SupervisorEnableFails','SupervisorStartFails','SupervisorStateTimeout','StaleHeartbeat','PidMismatch','StartTimeMismatch','MissingWorld','DuplicateWorld','PathMismatch','PreflightFails','WatcherEnableFails')]
    [string] $TestScenario = 'Live',
    [int] $StartupTimeoutSeconds = 300,
    [int] $HoldLockSeconds = 0,
    [string] $LogPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OpsRoot = $PSScriptRoot
$BinDir = 'C:\azeroth\build\bin\RelWithDebInfo'
$WorldExe = Join-Path $BinDir 'worldserver.exe'
$SupervisorScript = Join-Path $OpsRoot 'Worldserver-Supervisor.ps1'
$WatcherScript = Join-Path $OpsRoot 'Restart-Watcher.ps1'
$SoapCredentialFile = Join-Path $OpsRoot 'state\soap-credential.xml'
$SupervisorStateFile = Join-Path $OpsRoot 'state\supervisor-state.json'
$MaintenanceMarker = Join-Path $OpsRoot 'state\maintenance-active.json'
$RestartWatcherTaskName = 'AzerothCore Worldserver Restart Watcher'
$SupervisorTaskName = 'AzerothCore Worldserver Supervisor'
$DefaultLogPath = Join-Path $OpsRoot ('logs\operator-maintenance-{0}.log' -f (Get-Date -Format 'yyyy-MM'))
$HeartbeatMaxAgeSeconds = 30
$MutexName = 'Global\AzerothCoreManualMaintenanceControl'
$script:TestWatcherEnabled = $false
$script:TestSupervisorEnabled = $false
$script:TestSupervisorRunning = $false
$script:TestStateInitialized = $false
$script:WatcherWasEnabled = $false

if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = $DefaultLogPath }

function Write-OperatorLog {
    param([Parameter(Mandatory)][string] $Message, [ValidateSet('INFO','WARN','ERROR','OK')][string] $Level = 'INFO')
    $directory = Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    Add-Content -LiteralPath $LogPath -Value ('{0} [{1,-5}] START {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message) -Encoding UTF8
}

function Test-IsAdministrator {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ElevationArguments {
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(('"{0}"' -f $PSCommandPath)));
    foreach ($entry in $script:OriginalBoundParameters.GetEnumerator()) {
        if ($entry.Key -eq 'LogPath') { $arguments += @('-LogPath',(('"{0}"' -f $entry.Value))); continue }
        if ($entry.Value -is [switch]) { if ([bool]$entry.Value) { $arguments += ('-{0}' -f $entry.Key) }; continue }
        if ($null -ne $entry.Value -and [string]$entry.Value -ne '') { $arguments += @('-{0}' -f $entry.Key, [string]$entry.Value) }
    }
    return $arguments
}

function Ensure-Elevation {
    if ($DryRun) { return $true }
    if (Test-IsAdministrator) { return $true }
    Write-Host 'Administrator rights are required. Requesting elevation through Windows UAC...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList (Get-ElevationArguments) | Out-Null
        Write-Host 'The elevated START operation was launched. This window will now close.' -ForegroundColor Yellow
        return $false
    } catch {
        Write-Host "Could not request elevation: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function ConvertTo-UtcDateTime {
    param([Parameter(Mandatory)][object] $Value)
    return ([datetime]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
}

function Get-TaskSnapshot {
    param([Parameter(Mandatory)][string] $TaskName)
    if ($DryRun) {
        if (-not $script:TestStateInitialized) {
            if ($TestScenario -eq 'AlreadyHealthy') { $script:TestSupervisorEnabled = $true; $script:TestSupervisorRunning = $true; $script:TestWatcherEnabled = $true }
            $script:TestStateInitialized = $true
        }
        if ($TestScenario -eq 'MissingTask' -and $TaskName -eq $SupervisorTaskName) { return [pscustomobject]@{ Exists = $false; TaskName = $TaskName; Enabled = $false; State = 'Absent'; LastRunTime = $null; LastTaskResult = $null; NextRunTime = $null } }
        if ($TestScenario -eq 'MissingTask' -and $TaskName -eq $RestartWatcherTaskName) { return [pscustomobject]@{ Exists = $false; TaskName = $TaskName; Enabled = $false; State = 'Absent'; LastRunTime = $null; LastTaskResult = $null; NextRunTime = $null } }
        return [pscustomobject]@{ Exists = $true; TaskName = $TaskName; Enabled = if ($TaskName -eq $SupervisorTaskName) { $script:TestSupervisorEnabled } else { $script:TestWatcherEnabled }; State = if ($TaskName -eq $SupervisorTaskName -and $script:TestSupervisorRunning) { 'Running' } else { 'Ready' }; LastRunTime = $null; LastTaskResult = 0; NextRunTime = $null }
    }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) { return [pscustomobject]@{ Exists = $false; TaskName = $TaskName; Enabled = $false; State = 'Absent'; LastRunTime = $null; LastTaskResult = $null; NextRunTime = $null } }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    [pscustomobject]@{ Exists = $true; TaskName = $TaskName; Enabled = [bool]$task.Settings.Enabled; State = [string]$task.State; LastRunTime = if ($info) { $info.LastRunTime } else { $null }; LastTaskResult = if ($info) { $info.LastTaskResult } else { $null }; NextRunTime = if ($info) { $info.NextRunTime } else { $null } }
}

function Disable-Watcher {
    Write-OperatorLog "Disabling task '$RestartWatcherTaskName' for the entire startup transaction."
    if ($DryRun) { $script:TestWatcherEnabled = $false; return }
    Disable-ScheduledTask -TaskName $RestartWatcherTaskName -ErrorAction Stop | Out-Null
}

function Enable-Supervisor {
    if ($DryRun -and $TestScenario -eq 'SupervisorEnableFails') { throw 'test failure enabling supervisor task' }
    Write-OperatorLog "Enabling task '$SupervisorTaskName'."
    if ($DryRun) { $script:TestSupervisorEnabled = $true; return }
    Enable-ScheduledTask -TaskName $SupervisorTaskName -ErrorAction Stop | Out-Null
}

function Start-SupervisorIfNeeded {
    $task = Get-TaskSnapshot -TaskName $SupervisorTaskName
    if ($task.State -eq 'Running') { Write-OperatorLog 'Supervisor task is already Running; no duplicate start requested.' 'INFO'; return }
    if ($DryRun -and $TestScenario -eq 'SupervisorStartFails') { throw 'test failure starting supervisor task' }
    Write-OperatorLog "Starting task '$SupervisorTaskName'."
    if ($DryRun) { $script:TestSupervisorRunning = $true; return }
    Start-ScheduledTask -TaskName $SupervisorTaskName -ErrorAction Stop
}

function Get-ExactWorldserverProcesses {
    if ($DryRun) {
        if ($TestScenario -eq 'MissingWorld') { return @() }
        if ($TestScenario -eq 'PathMismatch') { throw "Safety stop: worldserver PID=4299 has unexpected executable path 'C:\unexpected\worldserver.exe'; supervisor startup is refused." }
        if ($TestScenario -eq 'DuplicateWorld') { return @([pscustomobject]@{ Pid = 4201; StartTime = (Get-Date).AddHours(-1); StartTimeUtc = ([datetime]::UtcNow).AddHours(-1); Process = $null; Path = $WorldExe },[pscustomobject]@{ Pid = 4202; StartTime = (Get-Date).AddHours(-2); StartTimeUtc = ([datetime]::UtcNow).AddHours(-2); Process = $null; Path = $WorldExe }) }
        return @([pscustomobject]@{ Pid = 4201; StartTime = (Get-Date).AddHours(-1); StartTimeUtc = ([datetime]::UtcNow).AddHours(-1); Process = $null; Path = $WorldExe })
    }
    $expected = [IO.Path]::GetFullPath($WorldExe).TrimEnd('\').ToLowerInvariant()
    try { $rows = @(Get-CimInstance Win32_Process -Filter "Name='worldserver.exe'" -ErrorAction Stop) } catch { throw "Could not inspect worldserver executable paths: $($_.Exception.Message)" }
    $result = foreach ($row in $rows) {
        $path = [string]$row.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($path)) { throw "Safety stop: worldserver PID=$($row.ProcessId) exists but its executable path is unavailable; supervisor startup is refused." }
        try { $actual = [IO.Path]::GetFullPath($path).TrimEnd('\').ToLowerInvariant() } catch { throw "Safety stop: worldserver PID=$($row.ProcessId) has an unreadable executable path; supervisor startup is refused." }
        if ($actual -ne $expected) { throw "Safety stop: worldserver PID=$($row.ProcessId) has unexpected executable path '$path'; supervisor startup is refused." }
        $process = Get-Process -Id ([int]$row.ProcessId) -ErrorAction Stop
        [pscustomobject]@{ Pid = [int]$row.ProcessId; StartTime = $process.StartTime; StartTimeUtc = $process.StartTime.ToUniversalTime(); Process = $process; Path = $path }
    }
    if (@($rows).Count -gt 1) { throw "Safety stop: $(@($rows).Count) worldserver.exe processes exist; supervisor startup is refused." }
    return @($result)
}

function Read-SupervisorState {
    if ($DryRun) { return [pscustomobject]@{ SupervisorPid = 4200; WorldserverPid = 4201; WorldserverStartTimeUtc = ([datetime]::UtcNow).AddHours(-1).ToString('o'); SupervisorStartedUtc = ([datetime]::UtcNow).AddHours(-1).ToString('o'); LastHeartbeatUtc = ([datetime]::UtcNow).ToString('o'); Status = 'Supervising'; SupervisorScriptPath = $SupervisorScript } }
    if (-not (Test-Path -LiteralPath $SupervisorStateFile)) { return [pscustomobject]@{ Invalid = $true; Reason = 'supervisor-state.json is missing' } }
    try { $state = Get-Content -LiteralPath $SupervisorStateFile -Raw -Encoding UTF8 | ConvertFrom-Json; if ($null -eq $state) { throw 'state is null' }; return $state } catch { return [pscustomobject]@{ Invalid = $true; Reason = $_.Exception.Message } }
}

function Test-SupervisorProcessIdentity {
    param([Parameter(Mandatory)][int] $SupervisorPid)
    if ($DryRun) { return [pscustomobject]@{ Ok = $true; Reason = 'test supervisor identity' } }
    try {
        $process = Get-Process -Id $SupervisorPid -ErrorAction Stop
        if ($process.ProcessName -notmatch '(?i)^(powershell|pwsh)$') { return [pscustomobject]@{ Ok = $false; Reason = "PID $SupervisorPid is not PowerShell" } }
        $row = Get-CimInstance Win32_Process -Filter "ProcessId=$SupervisorPid" -ErrorAction SilentlyContinue
        $commandLine = if ($row) { ([string]$row.CommandLine).ToLowerInvariant().Replace('/','\') } else { '' }
        $expected = [IO.Path]::GetFullPath($SupervisorScript).ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($commandLine)) {
            if ($commandLine -match [regex]::Escape($expected)) { return [pscustomobject]@{ Ok = $true; Reason = 'supervisor command line identifies the expected script' } }
            return [pscustomobject]@{ Ok = $false; Reason = 'supervisor command line does not identify Worldserver-Supervisor.ps1' }
        }
        $task = Get-ScheduledTask -TaskName $SupervisorTaskName -ErrorAction SilentlyContinue
        $actionText = if ($task) { ($task.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ' } else { '' }
        if ($task -and [string]$task.State -eq 'Running' -and $actionText.ToLowerInvariant().Replace('/','\') -match [regex]::Escape($expected)) { return [pscustomobject]@{ Ok = $true; Reason = 'running supervisor task action identifies the expected script' } }
        return [pscustomobject]@{ Ok = $false; Reason = 'supervisor command line was unavailable and the running task action could not corroborate the script' }
    } catch { return [pscustomobject]@{ Ok = $false; Reason = "could not verify supervisor process: $($_.Exception.Message)" } }
}

function Test-SupervisorHealth {
    param([Parameter(Mandatory)] $World)
    if ($DryRun) {
        switch ($TestScenario) {
            'SupervisorStateTimeout' { return [pscustomobject]@{ Ok = $false; Reason = 'supervisor state did not become healthy (test)'; HeartbeatAgeSeconds = $null } }
            'StaleHeartbeat' { return [pscustomobject]@{ Ok = $false; Reason = 'supervisor heartbeat is stale (test)'; HeartbeatAgeSeconds = 300 } }
            'PidMismatch' { return [pscustomobject]@{ Ok = $false; Reason = 'supervisor WorldserverPid mismatches actual PID (test)'; HeartbeatAgeSeconds = 0 } }
            'StartTimeMismatch' { return [pscustomobject]@{ Ok = $false; Reason = 'supervisor WorldserverStartTimeUtc mismatches actual process (test)'; HeartbeatAgeSeconds = 0 } }
            default { return [pscustomobject]@{ Ok = $true; Reason = 'test supervisor healthy'; HeartbeatAgeSeconds = 0 } }
        }
    }
    $state = Read-SupervisorState
    if ($state.PSObject.Properties.Name -contains 'Invalid' -and [bool]$state.Invalid) { return [pscustomobject]@{ Ok = $false; Reason = [string]$state.Reason } }
    foreach ($property in @('SupervisorPid','WorldserverPid','WorldserverStartTimeUtc','LastHeartbeatUtc','Status','SupervisorScriptPath')) { if (-not ($state.PSObject.Properties.Name -contains $property)) { return [pscustomobject]@{ Ok = $false; Reason = "supervisor state lacks $property" } } }
    if ([string]$state.Status -ne 'Supervising') { return [pscustomobject]@{ Ok = $false; Reason = "supervisor status is '$($state.Status)'" } }
    try { $heartbeat = ConvertTo-UtcDateTime $state.LastHeartbeatUtc; $age = ([datetime]::UtcNow - $heartbeat).TotalSeconds; $stateStart = ConvertTo-UtcDateTime $state.WorldserverStartTimeUtc } catch { return [pscustomobject]@{ Ok = $false; Reason = "invalid supervisor timestamp: $($_.Exception.Message)" } }
    if ($age -lt -5 -or $age -gt $HeartbeatMaxAgeSeconds) { return [pscustomobject]@{ Ok = $false; Reason = "supervisor heartbeat is $([math]::Round($age,1)) seconds old" } }
    if ([int]$state.WorldserverPid -ne $World.Pid) { return [pscustomobject]@{ Ok = $false; Reason = "state PID $($state.WorldserverPid) does not match actual PID $($World.Pid)" } }
    if ($stateStart.Ticks -ne $World.StartTimeUtc.Ticks) { return [pscustomobject]@{ Ok = $false; Reason = 'state WorldserverStartTimeUtc does not match actual process' } }
    try { if ([IO.Path]::GetFullPath([string]$state.SupervisorScriptPath).ToLowerInvariant() -ne [IO.Path]::GetFullPath($SupervisorScript).ToLowerInvariant()) { return [pscustomobject]@{ Ok = $false; Reason = 'state identifies a different supervisor script' } } } catch { return [pscustomobject]@{ Ok = $false; Reason = 'state contains an invalid supervisor script path' } }
    $task = Get-TaskSnapshot -TaskName $SupervisorTaskName
    if (-not $task.Exists -or -not $task.Enabled -or $task.State -ne 'Running') { return [pscustomobject]@{ Ok = $false; Reason = 'supervisor task is not enabled and running' } }
    $identity = Test-SupervisorProcessIdentity -SupervisorPid ([int]$state.SupervisorPid)
    if (-not $identity.Ok) { return $identity }
    return [pscustomobject]@{ Ok = $true; Reason = $identity.Reason; HeartbeatAgeSeconds = $age }
}

function Invoke-ExistingPreflight {
    if ($DryRun) {
        if ($TestScenario -eq 'PreflightFails') { return 1 }
        Write-OperatorLog 'DryRun: would run Restart-Watcher.ps1 -Preflight; no restart/announcement/shutdown command is sent.'
        return 0
    }
    Write-OperatorLog 'Running existing non-destructive Restart-Watcher.ps1 -Preflight.'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $WatcherScript -Preflight | Out-Host
    return [int]$LASTEXITCODE
}

function Remove-MaintenanceMarker {
    if ($DryRun) { Write-OperatorLog 'DryRun: would remove maintenance-active.json after all startup checks succeeded.'; return }
    if (Test-Path -LiteralPath $MaintenanceMarker) { Remove-Item -LiteralPath $MaintenanceMarker -Force -ErrorAction Stop }
    Write-OperatorLog 'Maintenance marker removed after successful startup.' 'OK'
}

function Disable-WatcherAfterFailure {
    try {
        if ($DryRun) { $script:TestWatcherEnabled = $false; return }
        $task = Get-ScheduledTask -TaskName $RestartWatcherTaskName -ErrorAction SilentlyContinue
        if ($task -and $task.Settings.Enabled) { Disable-ScheduledTask -TaskName $RestartWatcherTaskName -ErrorAction Stop | Out-Null }
    } catch { Write-OperatorLog "Could not re-disable watcher after startup failure: $($_.Exception.Message)" 'ERROR' }
}

function Write-SuccessSummary {
    param([Parameter(Mandatory)] $World, [Parameter(Mandatory)] $Health)
    Write-Host ''
    Write-Host '========================================' -ForegroundColor Green
    Write-Host 'AZEROTHCORE ONLINE' -ForegroundColor Green
    Write-Host '========================================' -ForegroundColor Green
    Write-Host 'Worldserver       : RUNNING'
    Write-Host "Worldserver PID   : $($World.Pid)"
    Write-Host 'Supervisor        : RUNNING'
    Write-Host 'Heartbeat         : HEALTHY'
    Write-Host 'SOAP preflight    : OK'
    Write-Host 'Restart watcher   : ENABLED'
    Write-Host 'Maintenance mode  : INACTIVE'
    Write-Host ''
    Write-Host 'Automatic 6-hour restarts are active.' -ForegroundColor Green
    Write-Host '========================================' -ForegroundColor Green
}

$script:OriginalBoundParameters = $PSBoundParameters
if (-not $DryRun -and $TestScenario -ne 'Live') { throw 'TestScenario values other than Live require -DryRun.' }
$elevation = Ensure-Elevation
if ($null -eq $elevation) { exit 1 }
if (-not $elevation) { exit 0 }

$mutex = New-Object System.Threading.Mutex($false,$MutexName)
$haveLock = $false
try {
    try { $haveLock = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $haveLock = $true; Write-OperatorLog 'Recovered an abandoned maintenance mutex.' 'WARN' }
    if (-not $haveLock) { Write-Host 'Another START or STOP operation is already running. No action was taken.' -ForegroundColor Yellow; exit 0 }
    if ($HoldLockSeconds -gt 0) { if (-not $DryRun) { throw '-HoldLockSeconds requires -DryRun' }; Start-Sleep -Seconds $HoldLockSeconds }
    Write-OperatorLog ("Manual START requested by {0}; DryRun={1}; Scenario={2}" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name,$DryRun,$TestScenario)
    foreach ($path in @($WorldExe,$SupervisorScript,$WatcherScript,$SoapCredentialFile)) { if (-not (Test-Path -LiteralPath $path)) { throw "Required file is missing: $path" } }
    $watcher = Get-TaskSnapshot -TaskName $RestartWatcherTaskName
    $supervisor = Get-TaskSnapshot -TaskName $SupervisorTaskName
    if (-not $watcher.Exists -or -not $supervisor.Exists) { throw 'Required scheduled task is missing; no startup was attempted.' }
    Write-OperatorLog "Initial watcher state: Enabled=$($watcher.Enabled), State=$($watcher.State), LastRun=$($watcher.LastRunTime), LastResult=$($watcher.LastTaskResult), NextRun=$($watcher.NextRunTime)."
    Write-OperatorLog "Initial supervisor state: Enabled=$($supervisor.Enabled), State=$($supervisor.State), LastRun=$($supervisor.LastRunTime), LastResult=$($supervisor.LastTaskResult), NextRun=$($supervisor.NextRunTime)."
    Disable-Watcher
    $watcher = Get-TaskSnapshot -TaskName $RestartWatcherTaskName
    if (-not $watcher.Exists -or $watcher.Enabled) { throw 'Could not verify the restart watcher is disabled during startup.' }
    Write-OperatorLog 'Restart watcher verified disabled during startup.' 'OK'
    # Elevated START must account for every worldserver.exe before allowing the
    # supervisor to start.  Unexpected-path, unreadable-path, or duplicate
    # processes are hard safety failures and are never silently ignored.
    $initialWorlds = @(Get-ExactWorldserverProcesses)
    Write-OperatorLog "Pre-start worldserver inventory is safe; expected-process count=$($initialWorlds.Count)." 'OK'
    Enable-Supervisor
    Start-SupervisorIfNeeded
    $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
    $health = $null
    $world = $null
    $worldLogged = $false
    do {
        $worlds = @(Get-ExactWorldserverProcesses)
        if ($worlds.Count -gt 1) { throw "Safety stop: $($worlds.Count) exact worldserver processes exist; no duplicate startup is allowed." }
        if ($worlds.Count -eq 0) {
            if ($DryRun) { throw 'Expected worldserver is not present yet; supervisor health cannot be validated.' }
            Start-Sleep -Seconds 5
            continue
        }
        $world = $worlds[0]
        if (-not $worldLogged) { Write-OperatorLog "Observed exact worldserver PID=$($world.Pid), StartTime=$($world.StartTime.ToString('o'))."; $worldLogged = $true }
        $health = Test-SupervisorHealth -World $world
        if ($health.Ok) { break }
        if ($DryRun) { break }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    if ($null -eq $health -or -not $health.Ok) { throw "Supervisor/worldserver health validation failed: $($health.Reason)" }
    Write-OperatorLog "Supervisor heartbeat and exact worldserver identity are healthy. Heartbeat age=$([math]::Round([double]$health.HeartbeatAgeSeconds,1)) seconds." 'OK'
    $preflightExit = Invoke-ExistingPreflight
    if ($preflightExit -ne 0) { throw "Restart-Watcher.ps1 -Preflight failed with exit code $preflightExit." }
    Write-OperatorLog 'Read-only watcher preflight succeeded.' 'OK'
    if ($DryRun -and $TestScenario -eq 'WatcherEnableFails') { throw 'test failure enabling restart watcher' }
    Write-OperatorLog "Enabling task '$RestartWatcherTaskName' only after healthy supervisor and preflight."
    if ($DryRun) { $script:TestWatcherEnabled = $true } else { Enable-ScheduledTask -TaskName $RestartWatcherTaskName -ErrorAction Stop | Out-Null }
    $watcher = Get-TaskSnapshot -TaskName $RestartWatcherTaskName
    if (-not $watcher.Exists -or -not $watcher.Enabled -or $watcher.State -eq 'Disabled') { throw 'Could not verify the restart watcher is enabled.' }
    $worlds = @(Get-ExactWorldserverProcesses)
    if ($worlds.Count -ne 1) { throw "Final worldserver validation failed: expected one exact process, found $($worlds.Count)." }
    $health = Test-SupervisorHealth -World $worlds[0]
    if (-not $health.Ok) { throw "Final supervisor heartbeat validation failed: $($health.Reason)" }
    Remove-MaintenanceMarker
    Write-OperatorLog 'START completed successfully; watcher is enabled last and automatic maintenance is active.' 'OK'
    Write-SuccessSummary -World $worlds[0] -Health $health
    exit 0
} catch {
    Disable-WatcherAfterFailure
    Write-OperatorLog "START failed safely: $($_.Exception.Message). Maintenance marker was retained and watcher was left disabled." 'ERROR'
    Write-Host "START failed safely: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Maintenance marker was retained. Restart watcher remains disabled; no forceful action was attempted.' -ForegroundColor Yellow
    exit 1
} finally {
    if ($haveLock) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
