<#!
.SYNOPSIS
    Safely place the AzerothCore worldserver into manual maintenance mode.

.DESCRIPTION
    This operator action disables the automatic watcher and supervisor before it
    sends the only manual SOAP command used here: server shutdown 1. It never
    owns or forcefully terminates a process. DryRun and TestScenario are strictly
    non-production test hooks; they do not change tasks, processes, or SOAP state.
#>
[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $FilesystemTest,
    [ValidateSet('Live','Healthy','AlreadyStopped','WatcherDisableFails','SupervisorDisableFails','SupervisorStopFails','VerificationFails','SoapFailure','ShutdownTimeout','DuplicateWorld','PathMismatch')]
    [string] $TestScenario = 'Live',
    [int] $ShutdownTimeoutSeconds = 300,
    [int] $HoldLockSeconds = 0,
    [string] $LogPath = '',
    [string] $FilesystemTestMarker = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OpsRoot = $PSScriptRoot
$BinDir = 'C:\azeroth\build\bin\RelWithDebInfo'
$WorldExe = Join-Path $BinDir 'worldserver.exe'
$RestartWatcherTaskName = 'AzerothCore Worldserver Restart Watcher'
$SupervisorTaskName = 'AzerothCore Worldserver Supervisor'
$MaintenanceMarker = Join-Path $OpsRoot 'state\maintenance-active.json'
$DefaultLogPath = Join-Path $OpsRoot ('logs\operator-maintenance-{0}.log' -f (Get-Date -Format 'yyyy-MM'))
$SoapCredentialFile = Join-Path $OpsRoot 'state\soap-credential.xml'
$SoapHost = '127.0.0.1'
$SoapPort = 7878
$MutexName = 'Global\AzerothCoreManualMaintenanceControl'
$script:TestWatcherEnabled = $true
$script:TestSupervisorEnabled = $true
$script:TestSupervisorRunning = $true

if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = $DefaultLogPath }
if ([string]::IsNullOrWhiteSpace($FilesystemTestMarker)) { $FilesystemTestMarker = Join-Path $OpsRoot 'state\operator-marker-filesystem-test\maintenance-active.json' }

function Write-OperatorLog {
    param([Parameter(Mandatory)][string] $Message, [ValidateSet('INFO','WARN','ERROR','OK')][string] $Level = 'INFO')
    $directory = Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    Add-Content -LiteralPath $LogPath -Value ('{0} [{1,-5}] STOP {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message) -Encoding UTF8
}

function Test-IsAdministrator {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ElevationArguments {
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(('"{0}"' -f $PSCommandPath)))
    foreach ($entry in $script:OriginalBoundParameters.GetEnumerator()) {
        if ($entry.Key -eq 'LogPath') { $arguments += @('-LogPath',(('"{0}"' -f $entry.Value))); continue }
        if ($entry.Value -is [switch]) { if ([bool]$entry.Value) { $arguments += ('-{0}' -f $entry.Key) }; continue }
        if ($null -ne $entry.Value -and [string]$entry.Value -ne '') { $arguments += @('-{0}' -f $entry.Key, [string]$entry.Value) }
    }
    return $arguments
}

function Ensure-Elevation {
    if ($DryRun -or $FilesystemTest) { return $true }
    if (Test-IsAdministrator) { return $true }
    Write-Host 'Administrator rights are required. Requesting elevation through Windows UAC...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList (Get-ElevationArguments) | Out-Null
        Write-Host 'The elevated maintenance operation was launched. This window will now close.' -ForegroundColor Yellow
        return $false
    } catch {
        Write-Host "Could not request elevation: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Get-TaskSnapshot {
    param([Parameter(Mandatory)][string] $TaskName)
    if ($DryRun) {
        if (($TestScenario -eq 'WatcherDisableFails' -and $TaskName -eq $RestartWatcherTaskName) -or ($TestScenario -eq 'SupervisorDisableFails' -and $TaskName -eq $SupervisorTaskName)) {
            return [pscustomobject]@{ Exists = $true; TaskName = $TaskName; Enabled = if ($TaskName -eq $RestartWatcherTaskName) { $script:TestWatcherEnabled } else { $script:TestSupervisorEnabled }; State = if ($TaskName -eq $SupervisorTaskName -and $script:TestSupervisorRunning) { 'Running' } else { 'Ready' }; LastRunTime = $null; LastTaskResult = 0; NextRunTime = $null }
        }
        if (($TestScenario -eq 'VerificationFails' -and $TaskName -eq $SupervisorTaskName) -or ($TestScenario -eq 'SupervisorStopFails' -and $TaskName -eq $SupervisorTaskName)) {
            return [pscustomobject]@{ Exists = $true; TaskName = $TaskName; Enabled = $true; State = 'Running'; LastRunTime = $null; LastTaskResult = 0; NextRunTime = $null }
        }
        if ($TestScenario -eq 'AlreadyStopped' -and $TaskName -eq $SupervisorTaskName) {
            return [pscustomobject]@{ Exists = $true; TaskName = $TaskName; Enabled = $false; State = 'Ready'; LastRunTime = $null; LastTaskResult = 0; NextRunTime = $null }
        }
        return [pscustomobject]@{ Exists = $true; TaskName = $TaskName; Enabled = if ($TaskName -eq $RestartWatcherTaskName) { $script:TestWatcherEnabled } else { $script:TestSupervisorEnabled }; State = if ($TaskName -eq $SupervisorTaskName -and $script:TestSupervisorRunning) { 'Running' } else { 'Ready' }; LastRunTime = $null; LastTaskResult = 0; NextRunTime = $null }
    }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) { return [pscustomobject]@{ Exists = $false; TaskName = $TaskName; Enabled = $false; State = 'Absent'; LastRunTime = $null; LastTaskResult = $null; NextRunTime = $null } }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    [pscustomobject]@{ Exists = $true; TaskName = $TaskName; Enabled = [bool]$task.Settings.Enabled; State = [string]$task.State; LastRunTime = if ($info) { $info.LastRunTime } else { $null }; LastTaskResult = if ($info) { $info.LastTaskResult } else { $null }; NextRunTime = if ($info) { $info.NextRunTime } else { $null } }
}

function Disable-OperatorTask {
    param([Parameter(Mandatory)][string] $TaskName)
    Write-OperatorLog "Disabling task '$TaskName'."
    if ($DryRun) {
        if ($TaskName -eq $RestartWatcherTaskName -and $TestScenario -eq 'WatcherDisableFails') { throw "test failure disabling '$TaskName'" }
        if ($TaskName -eq $SupervisorTaskName -and $TestScenario -eq 'SupervisorDisableFails') { throw "test failure disabling '$TaskName'" }
        if ($TaskName -eq $RestartWatcherTaskName) { $script:TestWatcherEnabled = $false } else { $script:TestSupervisorEnabled = $false }
        return
    }
    Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
}

function Stop-OperatorTask {
    param([Parameter(Mandatory)][string] $TaskName)
    Write-OperatorLog "Stopping running task '$TaskName' through Task Scheduler."
    if ($DryRun) {
        if ($TestScenario -eq 'SupervisorStopFails') { throw "test failure stopping '$TaskName'" }
        $script:TestSupervisorRunning = $false
        return
    }
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
}

function Wait-SupervisorTaskStopped {
    param([int] $TimeoutSeconds = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $snapshot = Get-TaskSnapshot -TaskName $SupervisorTaskName
        if (-not $snapshot.Exists) { return $false }
        if (-not $snapshot.Enabled -and $snapshot.State -ne 'Running') { return $true }
        if ($DryRun) { return $false }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Write-MaintenanceMarker {
    param([string] $MarkerPath = $MaintenanceMarker)
    # The marker is deliberately never overwritten. Existing valid active state
    # is authoritative for sequential STOP idempotency, including an isolated
    # test marker passed through -FilesystemTestMarker.
    if (Test-Path -LiteralPath $MarkerPath) {
        try {
            $existingRaw = Get-Content -LiteralPath $MarkerPath -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($existingRaw)) { throw 'maintenance marker is empty' }
            $existing = $existingRaw | ConvertFrom-Json
            if ($null -eq $existing -or $existing -isnot [pscustomobject]) { throw 'maintenance marker root is not an object' }
            if (-not ($existing.PSObject.Properties.Name -contains 'Active') -or $existing.Active -isnot [bool] -or -not [bool]$existing.Active) { throw 'maintenance marker is contradictory: Active is not true' }
            foreach ($property in @('StartedUtc','StartedBy','Reason')) {
                if (-not ($existing.PSObject.Properties.Name -contains $property) -or [string]::IsNullOrWhiteSpace([string]$existing.$property)) { throw "maintenance marker lacks usable $property" }
            }
            try { [datetime]::Parse([string]$existing.StartedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind) | Out-Null } catch { throw 'maintenance marker StartedUtc is invalid' }
            Write-OperatorLog 'Maintenance mode was already active; preserved the existing marker without overwriting it.' 'OK'
            return
        } catch {
            throw "Existing maintenance marker is malformed or contradictory: $($_.Exception.Message). Resolve it before any shutdown command is sent."
        }
    }
    $directory = Split-Path -Parent $MarkerPath
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $marker = [pscustomobject]@{
        Active = $true
        StartedUtc = ([datetime]::UtcNow).ToString('o')
        StartedBy = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        Reason = 'Manual maintenance'
    }
    if ($DryRun) { Write-OperatorLog 'DryRun: would atomically create maintenance-active.json.'; return }
    $tmp = '{0}.{1}.tmp' -f $MarkerPath, ([guid]::NewGuid().ToString('N'))
    try {
        $marker | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $tmp -Encoding UTF8
        # The destination was absent when checked. Do not use -Force: if another
        # operator wins a race and creates it first, fail safely rather than
        # replacing an existing maintenance decision.
        Move-Item -LiteralPath $tmp -Destination $MarkerPath -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    Write-OperatorLog 'Maintenance marker created atomically.' 'OK'
}

function Invoke-FilesystemMarkerTest {
    $testMarker = [IO.Path]::GetFullPath($FilesystemTestMarker)
    $liveMarker = [IO.Path]::GetFullPath($MaintenanceMarker)
    $opsRootFull = ([IO.Path]::GetFullPath($OpsRoot)).TrimEnd('\') + '\'
    if ($testMarker.ToLowerInvariant() -eq $liveMarker.ToLowerInvariant()) { throw 'FilesystemTestMarker must not be the live maintenance marker.' }
    if (-not $testMarker.ToLowerInvariant().StartsWith($opsRootFull.ToLowerInvariant())) { throw 'FilesystemTestMarker must remain under the ops-rework directory.' }
    $testRoot = Split-Path -Parent $testMarker
    if ([IO.Path]::GetFileName($testRoot) -ne 'operator-marker-filesystem-test') { throw 'FilesystemTestMarker must use the isolated operator-marker-filesystem-test directory.' }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop }
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    try {
        Write-MaintenanceMarker -MarkerPath $testMarker
        if (-not (Test-Path -LiteralPath $testMarker)) { throw 'first marker creation did not produce a file' }
        $first = Get-Content -LiteralPath $testMarker -Raw -Encoding UTF8 | ConvertFrom-Json
        $originalStartedUtc = [string]$first.StartedUtc
        $originalStartedBy = [string]$first.StartedBy
        $originalReason = [string]$first.Reason
        Write-MaintenanceMarker -MarkerPath $testMarker
        $secondRaw = Get-Content -LiteralPath $testMarker -Raw -Encoding UTF8
        $second = $secondRaw | ConvertFrom-Json
        if ([string]$second.StartedUtc -ne $originalStartedUtc -or [string]$second.StartedBy -ne $originalStartedBy -or [string]$second.Reason -ne $originalReason) { throw 'second active marker operation changed the original marker fields' }
        Set-Content -LiteralPath $testMarker -Value '{not-json' -Encoding UTF8
        $malformedBefore = Get-Content -LiteralPath $testMarker -Raw -Encoding UTF8
        $malformedRejected = $false
        try { Write-MaintenanceMarker -MarkerPath $testMarker } catch { $malformedRejected = $true }
        $malformedAfter = Get-Content -LiteralPath $testMarker -Raw -Encoding UTF8
        if (-not $malformedRejected) { throw 'malformed marker was not rejected' }
        if ($malformedAfter -ne $malformedBefore) { throw 'malformed marker was modified' }
        Write-Host 'PASS filesystem marker first-create, sequential-active-preserve, and malformed-preserve checks.' -ForegroundColor Green
        return 0
    } finally {
        if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Get-ExactWorldserverProcesses {
    if ($DryRun) {
        if ($TestScenario -in @('AlreadyStopped','PathMismatch')) { return @() }
        if ($TestScenario -eq 'DuplicateWorld') { return @([pscustomobject]@{ Pid = 4201; StartTime = (Get-Date).AddHours(-1); StartTimeUtc = ([datetime]::UtcNow).AddHours(-1); Process = $null; Path = $WorldExe },[pscustomobject]@{ Pid = 4202; StartTime = (Get-Date).AddHours(-2); StartTimeUtc = ([datetime]::UtcNow).AddHours(-2); Process = $null; Path = $WorldExe }) }
        return @([pscustomobject]@{ Pid = 4201; StartTime = (Get-Date).AddHours(-1); StartTimeUtc = ([datetime]::UtcNow).AddHours(-1); Process = $null; Path = $WorldExe })
    }
    $expected = [IO.Path]::GetFullPath($WorldExe).TrimEnd('\').ToLowerInvariant()
    try {
        $rows = @(Get-CimInstance Win32_Process -Filter "Name='worldserver.exe'" | Where-Object { $_.ExecutablePath -and ([IO.Path]::GetFullPath($_.ExecutablePath).TrimEnd('\').ToLowerInvariant() -eq $expected) })
    } catch { throw "Could not inspect worldserver executable paths: $($_.Exception.Message)" }
    $result = foreach ($row in $rows) {
        $process = Get-Process -Id ([int]$row.ProcessId) -ErrorAction Stop
        [pscustomobject]@{ Pid = [int]$row.ProcessId; StartTime = $process.StartTime; StartTimeUtc = $process.StartTime.ToUniversalTime(); Process = $process; Path = $row.ExecutablePath }
    }
    return @($result)
}

function Test-TcpPort {
    param([Parameter(Mandatory)][int] $Port, [int] $TimeoutMilliseconds = 1000)
    $client = New-Object System.Net.Sockets.TcpClient
    try { $async = $client.BeginConnect($SoapHost,$Port,$null,$null); if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds,$false)) { return $false }; $client.EndConnect($async); return $true } catch { return $false } finally { $client.Dispose() }
}

function Get-SoapCredential {
    try {
        if (-not (Test-Path -LiteralPath $SoapCredentialFile)) { return $null }
        $credential = Import-Clixml -LiteralPath $SoapCredentialFile
        if ($credential -isnot [Management.Automation.PSCredential]) { return $null }
        return $credential
    } catch { return $null }
}

function Invoke-SoapShutdown {
    $command = 'server shutdown 1'
    if ($DryRun) {
        if ($TestScenario -eq 'SoapFailure') { return [pscustomobject]@{ Ok = $false; Reason = 'test SOAP failure' } }
        Write-OperatorLog "DryRun: would send '$command'; no SOAP request was sent." 'INFO'
        return [pscustomobject]@{ Ok = $true; Reason = '' }
    }
    $credential = Get-SoapCredential
    if ($null -eq $credential) { return [pscustomobject]@{ Ok = $false; Reason = 'SOAP credential is unavailable or could not be decrypted' } }
    if (-not (Test-TcpPort -Port $SoapPort)) { return [pscustomobject]@{ Ok = $false; Reason = "SOAP port $SoapPort on $SoapHost is unreachable" } }
    $escaped = [Security.SecurityElement]::Escape($command)
    $body = @"
<?xml version="1.0" encoding="utf-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="urn:AC">
  <SOAP-ENV:Body><ns1:executeCommand><command>$escaped</command></ns1:executeCommand></SOAP-ENV:Body>
</SOAP-ENV:Envelope>
"@
    $plain = $null
    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($credential.Password)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $pair = '{0}:{1}' -f $credential.UserName,$plain
        $headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair)); 'Content-Type' = 'application/xml' }
        try {
            $response = Invoke-WebRequest -Uri "http://$SoapHost`:$SoapPort/" -Method Post -Headers $headers -Body $body -TimeoutSec 20 -UseBasicParsing
            if ([string]$response.Content -match '(?i)<(?:[^:>]+:)?Fault\b|faultstring') { return [pscustomobject]@{ Ok = $false; Reason = 'SOAP returned a fault' } }
            return [pscustomobject]@{ Ok = $true; Reason = '' }
        } catch {
            $status = $null
            if ($_.Exception.Response) { try { $status = [int]$_.Exception.Response.StatusCode } catch {} }
            if ($status -eq 401) { return [pscustomobject]@{ Ok = $false; Reason = 'HTTP 401 Unauthorized' } }
            return [pscustomobject]@{ Ok = $false; Reason = if ($null -ne $status) { "HTTP $status from SOAP" } else { $_.Exception.Message } }
        }
    } finally {
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        $plain = $null
    }
}

function Wait-WorldserverExit {
    param([Parameter(Mandatory)] $World, [int] $TimeoutSeconds)
    if ($DryRun) { return ($TestScenario -ne 'ShutdownTimeout') }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            if ($World.Process.HasExited) { return $true }
        } catch { return $false }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Write-SuccessSummary {
    Write-Host ''
    Write-Host '========================================' -ForegroundColor Green
    Write-Host 'AZEROTHCORE MAINTENANCE MODE' -ForegroundColor Green
    Write-Host '========================================' -ForegroundColor Green
    Write-Host 'Worldserver       : DOWN'
    Write-Host 'Supervisor task   : DISABLED'
    Write-Host 'Restart watcher   : DISABLED'
    Write-Host 'Authserver        : UNCHANGED'
    Write-Host 'MySQL             : UNCHANGED'
    Write-Host 'Maintenance mode  : ACTIVE'
    Write-Host ''
    Write-Host 'Safe to rebuild/update AzerothCore.' -ForegroundColor Green
    Write-Host '========================================' -ForegroundColor Green
}

$script:OriginalBoundParameters = $PSBoundParameters
if (-not $DryRun -and -not $FilesystemTest -and $TestScenario -ne 'Live') { throw 'TestScenario values other than Live require -DryRun.' }
$elevation = Ensure-Elevation
if ($null -eq $elevation) { exit 1 }
if (-not $elevation) { exit 0 }
if ($FilesystemTest) { try { exit (Invoke-FilesystemMarkerTest) } catch { Write-Host "Filesystem marker test failed: $($_.Exception.Message)" -ForegroundColor Red; exit 1 } }

$mutex = New-Object System.Threading.Mutex($false,$MutexName)
$haveLock = $false
try {
    try { $haveLock = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $haveLock = $true; Write-OperatorLog 'Recovered an abandoned maintenance mutex.' 'WARN' }
    if (-not $haveLock) { Write-Host 'Another START or STOP operation is already running. No action was taken.' -ForegroundColor Yellow; exit 0 }
    if ($HoldLockSeconds -gt 0) { if (-not $DryRun) { throw '-HoldLockSeconds requires -DryRun' }; Start-Sleep -Seconds $HoldLockSeconds }
    Write-OperatorLog ("Manual STOP requested by {0}; DryRun={1}; Scenario={2}" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name,$DryRun,$TestScenario)

    $watcher = Get-TaskSnapshot -TaskName $RestartWatcherTaskName
    if (-not $watcher.Exists) { throw "Required task '$RestartWatcherTaskName' is missing. Worldserver was not touched." }
    Write-OperatorLog "Initial watcher state: Enabled=$($watcher.Enabled), State=$($watcher.State)."
    Disable-OperatorTask -TaskName $RestartWatcherTaskName
    $watcher = Get-TaskSnapshot -TaskName $RestartWatcherTaskName
    if (-not $watcher.Exists -or $watcher.Enabled) { throw "Could not verify '$RestartWatcherTaskName' is disabled. Worldserver was not touched." }
    Write-OperatorLog 'Restart watcher verified disabled.' 'OK'

    $supervisor = Get-TaskSnapshot -TaskName $SupervisorTaskName
    if (-not $supervisor.Exists) { throw "Required task '$SupervisorTaskName' is missing. Worldserver was not touched." }
    Write-OperatorLog "Initial supervisor state: Enabled=$($supervisor.Enabled), State=$($supervisor.State)."
    Disable-OperatorTask -TaskName $SupervisorTaskName
    $supervisor = Get-TaskSnapshot -TaskName $SupervisorTaskName
    if ($supervisor.State -eq 'Running') { Stop-OperatorTask -TaskName $SupervisorTaskName }
    if (-not (Wait-SupervisorTaskStopped)) { throw "Could not verify '$SupervisorTaskName' is stopped. Worldserver was not touched." }
    $supervisor = Get-TaskSnapshot -TaskName $SupervisorTaskName
    if (-not $supervisor.Exists -or $supervisor.Enabled -or $supervisor.State -eq 'Running') { throw "Supervisor task safety verification failed: Enabled=$($supervisor.Enabled), State=$($supervisor.State). Worldserver was not touched." }
    Write-OperatorLog 'Supervisor task verified disabled and not running.' 'OK'

    Write-MaintenanceMarker
    $worlds = @(Get-ExactWorldserverProcesses)
    if ($worlds.Count -gt 1) { throw "Safety stop: $($worlds.Count) exact worldserver processes exist. No shutdown command was sent." }
    if ($worlds.Count -eq 0) {
        Write-OperatorLog 'Expected worldserver executable is already absent; no SOAP shutdown was sent.' 'OK'
        Write-SuccessSummary
        exit 0
    }
    $world = $worlds[0]
    Write-OperatorLog "Exact worldserver PID=$($world.Pid), StartTime=$($world.StartTime.ToString('o'))."
    Write-OperatorLog 'Sending the planned manual SOAP shutdown command: server shutdown 1.' 'INFO'
    $soap = Invoke-SoapShutdown
    if (-not $soap.Ok) { Write-OperatorLog "SOAP shutdown failed: $($soap.Reason). Worldserver remains running; manual investigation is required." 'ERROR'; Write-Host "ERROR: SOAP shutdown failed. Worldserver remains running. $($soap.Reason)" -ForegroundColor Red; exit 1 }
    Write-OperatorLog 'SOAP shutdown command accepted.' 'OK'
    if (-not (Wait-WorldserverExit -World $world -TimeoutSeconds $ShutdownTimeoutSeconds)) { Write-OperatorLog "Worldserver PID=$($world.Pid) did not exit within $ShutdownTimeoutSeconds seconds. It was not forcefully terminated; manual investigation is required." 'ERROR'; Write-Host 'ERROR: worldserver remains running. No forceful termination was attempted.' -ForegroundColor Red; exit 1 }
    Write-OperatorLog "Worldserver PID=$($world.Pid) exited cleanly." 'OK'
    Write-SuccessSummary
    exit 0
} catch {
    Write-OperatorLog "STOP aborted safely: $($_.Exception.Message)" 'ERROR'
    Write-Host "STOP aborted safely: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if ($haveLock) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
