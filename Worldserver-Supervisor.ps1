<#!
.SYNOPSIS
    Conservative owner for worldserver.exe after an administrator adopts it.

.DESCRIPTION
    This supervisor launches/adopts only worldserver.exe and uses the persistent
    automatic restart ticket as the sole relaunch authority. Process exit codes
    remain diagnostic only. A valid, durable Armed ticket for the exact exited
    PID plus StartTimeUtc is required; manual, malformed, blocked, ambiguous,
    consumed, or mismatched state never authorizes relaunch. It never terminates
    a process.
#>
[CmdletBinding()]
param(
    [switch] $DryRun,
    [int] $SimulatedExitCode = -1,
    [int] $StartupTimeoutSeconds = 900,
    [int] $RestartBackoffSeconds = 10,
    [int] $RestartTicketGraceSeconds = 1200,
    [ValidateSet('Live','ValidArmed','BeforeExpected','InsideGrace','Expired','Missing','Empty','JsonNull','EmptyObject','Malformed','MissingStatus','MissingPid','MissingStartTime','WrongTypes','UnknownStatus','Preparing','Blocked','Ambiguous','WrongPid','WrongStartTime','Consumed','Pending','MatchingProcess','FullLifecycle','AdoptedReadiness','ReadinessTimeout','ReplacementDies','CrashAfterConsumed','CrashAfterLaunchStarted','CrashAfterProcessStart','CrashAfterReadiness')][string] $TestRestartTicket = 'Live',
    [string] $TestStateFile = '',
    [string] $TestRoot = '',
    [datetime] $TestNowUtc = [datetime]::MinValue
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OpsRoot = $PSScriptRoot
$BinDir = 'C:\azeroth\build\bin\RelWithDebInfo'
$WorldExe = Join-Path $BinDir 'worldserver.exe'
$ServerLog = Join-Path $BinDir 'Server.log'
$LogDir = Join-Path $OpsRoot 'logs'
$LogPath = Join-Path $LogDir ('worldserver-restart-{0}.log' -f (Get-Date -Format 'yyyy-MM'))
$SupervisorStateFile = Join-Path $OpsRoot 'state\supervisor-state.json'
$RestartStateFile = Join-Path $OpsRoot 'state\restart-state.json'
$WorldPort = 8085
$HeartbeatIntervalSeconds = 10
$SupervisorStartedUtc = [datetime]::UtcNow
$SupervisorInstanceId = [guid]::NewGuid().ToString('N')
$script:CurrentWorld = $null
$SupervisorMutexName = if ($DryRun) { 'Global\AzerothCoreWorldserverSupervisorTest' } else { 'Global\AzerothCoreWorldserverSupervisor' }

if (-not [string]::IsNullOrWhiteSpace($TestStateFile)) {
    if (-not $DryRun) { throw '-TestStateFile requires -DryRun.' }
    $RestartStateFile = [IO.Path]::GetFullPath($TestStateFile)
}

if (-not [string]::IsNullOrWhiteSpace($TestRoot)) {
    if (-not $DryRun) { throw '-TestRoot requires -DryRun.' }
    $testRootFull = [IO.Path]::GetFullPath($TestRoot)
    $testStateDirectory = Join-Path $testRootFull 'state'
    $LogDir = Join-Path $testRootFull 'logs'
    $LogPath = Join-Path $LogDir 'worldserver-supervisor-test.log'
    $RestartStateFile = Join-Path $testStateDirectory 'restart-state.json'
    $SupervisorStateFile = Join-Path $testStateDirectory 'supervisor-state.json'
}

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log {
    param([Parameter(Mandatory)][string] $Message, [ValidateSet('INFO','WARN','ERROR','OK')][string] $Level = 'INFO')
    Add-Content -LiteralPath $LogPath -Value ('{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message) -Encoding UTF8
}

function Get-EffectiveUtcNow {
    if ($DryRun -and $TestNowUtc -ne [datetime]::MinValue) { return $TestNowUtc.ToUniversalTime() }
    return [datetime]::UtcNow
}

function Write-SupervisorState {
    param([Parameter(Mandatory)][string] $Status, [Parameter(Mandatory)] $World)
    $stateDir = Split-Path -Parent $SupervisorStateFile
    if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $state = [pscustomobject]@{
        SupervisorPid = $PID
        WorldserverPid = $World.Pid
        WorldserverStartTimeUtc = $World.StartTimeUtc.ToString('o')
        SupervisorStartedUtc = $SupervisorStartedUtc.ToString('o')
        LastHeartbeatUtc = ([datetime]::UtcNow).ToString('o')
        Status = $Status
        SupervisorScriptPath = [IO.Path]::GetFullPath($PSCommandPath)
        SupervisorInstanceId = $SupervisorInstanceId
    }
    $tmp = '{0}.{1}.tmp' -f $SupervisorStateFile, ([guid]::NewGuid().ToString('N'))
    $backup = '{0}.{1}.bak' -f $SupervisorStateFile, ([guid]::NewGuid().ToString('N'))
    try {
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
        if (Test-Path -LiteralPath $SupervisorStateFile) { [IO.File]::Replace($tmp,$SupervisorStateFile,$backup,$true) }
        else { [IO.File]::Move($tmp,$SupervisorStateFile) }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
    }
}

function Remove-SupervisorStateIfOwned {
    if (-not (Test-Path -LiteralPath $SupervisorStateFile)) { return }
    try {
        $state = Get-Content -LiteralPath $SupervisorStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$state.SupervisorPid -eq $PID) { Remove-Item -LiteralPath $SupervisorStateFile -Force; Write-Log 'Removed supervisor heartbeat state during supervisor exit.' 'INFO' }
    } catch { Write-Log "Could not clean supervisor state during exit; stale heartbeat remains protective: $($_.Exception.Message)" 'WARN' }
}

function Test-TcpPort {
    param([int] $Port, [int] $TimeoutMilliseconds = 1000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1',$Port,$null,$null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds,$false)) { return $false }
        $client.EndConnect($async); return $true
    } catch { return $false }
    finally { $client.Dispose() }
}

function Get-ProcessExecutablePath {
    param([Parameter(Mandatory)][Diagnostics.Process] $Process)
    try { if (-not [string]::IsNullOrWhiteSpace([string]$Process.Path)) { return [string]$Process.Path } } catch { }
    try { if (-not [string]::IsNullOrWhiteSpace([string]$Process.MainModule.FileName)) { return [string]$Process.MainModule.FileName } } catch { }
    try {
        $row = Get-CimInstance Win32_Process -Filter "ProcessId=$($Process.Id)" -ErrorAction Stop
        if ($row -and -not [string]::IsNullOrWhiteSpace([string]$row.ExecutablePath)) { return [string]$row.ExecutablePath }
    } catch { }
    return ''
}

function Get-WorldProcessInventory {
    $expectedPath = [IO.Path]::GetFullPath($WorldExe).TrimEnd('\').ToLowerInvariant()
    $expectedProcesses = @()
    $suspiciousProcesses = @()
    foreach ($process in @(Get-Process -Name 'worldserver' -ErrorAction SilentlyContinue)) {
        $path = Get-ProcessExecutablePath -Process $process
        $item = [pscustomobject]@{ ProcessId = [int]$process.Id; Process = $process; ExecutablePath = $path; StartTimeUtc = $process.StartTime.ToUniversalTime() }
        if ([string]::IsNullOrWhiteSpace($path)) {
            $suspiciousProcesses += [pscustomobject]@{ Item = $item; Reason = 'executable path is unavailable' }
            continue
        }
        try { $actualPath = [IO.Path]::GetFullPath($path).TrimEnd('\').ToLowerInvariant() } catch { $actualPath = '' }
        if ($actualPath -eq $expectedPath) { $expectedProcesses += $item }
        else { $suspiciousProcesses += [pscustomobject]@{ Item = $item; Reason = "unexpected executable path '$path'" } }
    }
    [pscustomobject]@{ Expected = @($expectedProcesses); Suspicious = @($suspiciousProcesses); Total = $expectedProcesses.Count + $suspiciousProcesses.Count }
}

function Get-WorldProcesses {
    $inventory = Get-WorldProcessInventory
    if ($inventory.Suspicious.Count -gt 0) {
        $details = ($inventory.Suspicious | ForEach-Object { "PID=$($_.Item.ProcessId): $($_.Reason)" }) -join '; '
        throw "Safety stop: suspicious worldserver process identity detected ($details)."
    }
    if ($inventory.Total -gt 1) { throw "Safety stop: $($inventory.Total) worldserver processes exist; duplicate launch/adoption is refused." }
    return @($inventory.Expected)
}

function ConvertTo-WorldIdentity {
    param([Parameter(Mandatory)] $Process)
    [pscustomobject]@{ Pid = $Process.Id; StartTimeUtc = $Process.StartTime.ToUniversalTime(); Process = $Process }
}

function Get-ServerLogCheckpoint {
    if (-not (Test-Path -LiteralPath $ServerLog)) { return 0L }
    return [int64](Get-Item -LiteralPath $ServerLog).Length
}

function Wait-WorldReady {
    param(
        [object] $Process,
        [int] $TimeoutSeconds,
        [long] $InitialLogOffset = 0
    )
    if ($DryRun -and $null -eq $Process) {
        Write-Log 'DryRun readiness validation completed for adopted replacement; no process or port was touched.' 'OK'
        return $true
    }
    $identity = ConvertTo-WorldIdentity -Process $Process
    try { Write-SupervisorState -Status 'Starting' -World $identity } catch { Write-Log "Supervisor heartbeat write failed during startup; watcher will remain blocked: $($_.Exception.Message)" 'ERROR' }
    $offset = [math]::Max(0L,$InitialLogOffset)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try { Write-SupervisorState -Status 'Starting' -World $identity } catch { }
        if ($Process.HasExited) { Write-Log "worldserver exited during startup with code $($Process.ExitCode)." 'ERROR'; return $false }
        try {
            $actualPath = Get-ProcessExecutablePath -Process $Process
            if ([string]::IsNullOrWhiteSpace($actualPath) -or [IO.Path]::GetFullPath($actualPath).TrimEnd('\').ToLowerInvariant() -ne [IO.Path]::GetFullPath($WorldExe).TrimEnd('\').ToLowerInvariant()) {
                Write-Log "Replacement PID=$($Process.Id) executable identity could not be positively verified during readiness." 'ERROR'
                return $false
            }
        } catch { Write-Log "Replacement PID=$($Process.Id) identity validation failed during readiness: $($_.Exception.Message)" 'ERROR'; return $false }
        if (Test-TcpPort -Port $WorldPort) {
            if (Test-Path -LiteralPath $ServerLog) {
                try {
                    $stream = [IO.File]::Open($ServerLog,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
                    try {
                        $safeOffset = if ($stream.Length -lt $offset) { 0L } else { $offset }
                        $stream.Seek($safeOffset,[IO.SeekOrigin]::Begin) | Out-Null
                        $reader = New-Object IO.StreamReader($stream)
                        try { $newText = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    } finally { $stream.Dispose() }
                    if ($newText -match 'worldserver-daemon\) ready') {
                        try { Write-SupervisorState -Status 'Supervising' -World $identity } catch { Write-Log "Supervisor heartbeat write failed at readiness; watcher will remain blocked: $($_.Exception.Message)" 'ERROR'; return $false }
                        Write-Log 'worldserver readiness marker observed.' 'OK'; return $true
                    }
                } catch { Write-Log "Could not inspect Server.log during readiness check: $($_.Exception.Message)" 'WARN' }
            }
            Write-Log 'worldserver port 8085 is listening; readiness marker not yet observed.' 'INFO'
        }
        Start-Sleep -Seconds 5
    }
    Write-Log "worldserver did not become ready within $TimeoutSeconds seconds; supervisor is stopping without terminating it." 'ERROR'
    return $false
}

function Start-Worldserver {
    $existing = @(Get-WorldProcesses)
    if ($existing.Count -gt 0) { throw "Safety stop: matching worldserver.exe already exists (PID $($existing[0].ProcessId)); no second process will be launched." }
    if (-not (Test-Path -LiteralPath $WorldExe)) { throw "Missing executable: $WorldExe" }
    Write-Log "Launching worldserver.exe with working directory $BinDir." 'INFO'
    $startedProcess = Start-Process -FilePath $WorldExe -WorkingDirectory $BinDir -PassThru
    Start-Sleep -Milliseconds 250
    $afterLaunch = @(Get-WorldProcesses)
    if ($afterLaunch.Count -ne 1 -or [int]$afterLaunch[0].ProcessId -ne [int]$startedProcess.Id) {
        throw "Safety stop: launch race detected after creating PID=$($startedProcess.Id); exactly one matching process with that PID was not observed. No process was terminated."
    }
    return $startedProcess
}

function Classify-ExitCode {
    param([int] $Code)
    switch ($Code) {
        0 { return 'NORMAL_SHUTDOWN' }
        2 { return 'INTENTIONAL_RESTART' }
        default { return 'ABNORMAL_EXIT' }
    }
}

function Read-RestartState {
    if (-not (Test-Path -LiteralPath $RestartStateFile)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $RestartStateFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'restart state is empty' }
        $parsed = $raw | ConvertFrom-Json
        if ($null -eq $parsed -or $parsed -isnot [pscustomobject]) { throw 'restart state root is not an object' }
        return $parsed
    } catch {
        return [pscustomobject]@{ Invalid = $true; Reason = $_.Exception.Message }
    }
}

function Write-RestartStateAtomic {
    param([Parameter(Mandatory)] $State)
    $directory = Split-Path -Parent $RestartStateFile
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $tmp = '{0}.{1}.tmp' -f $RestartStateFile, ([guid]::NewGuid().ToString('N'))
    $backup = '{0}.{1}.bak' -f $RestartStateFile, ([guid]::NewGuid().ToString('N'))
    try {
        $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
        if (Test-Path -LiteralPath $RestartStateFile) { [IO.File]::Replace($tmp,$RestartStateFile,$backup,$true) }
        else { [IO.File]::Move($tmp,$RestartStateFile) }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
    }
}

function Test-AutomaticRestartTicket {
    param(
        [Parameter(Mandatory)][AllowNull()] $State,
        [Parameter(Mandatory)][int] $ExitedPid,
        [Parameter(Mandatory)][datetime] $ExitedStartTimeUtc
    )
    try {
        if ($null -eq $State) { return [pscustomobject]@{ Ok = $false; Reason = 'restart-state.json is missing' } }
        if ($State -isnot [pscustomobject]) { return [pscustomobject]@{ Ok = $false; Reason = 'restart state root is not an object' } }
        if ($State.PSObject.Properties.Name -contains 'Invalid' -and [bool]$State.Invalid) { return [pscustomobject]@{ Ok = $false; Reason = "restart-state.json is malformed: $($State.Reason)" } }
        foreach ($property in @('Status','Intent','Pid','StartTimeUtc','PreparingStartedUtc','ArmedAtUtc','ExpectedShutdownUtc','ShutdownCommand','ShutdownCommandStatus','CommandAcceptedUtc')) {
            if (-not ($State.PSObject.Properties.Name -contains $property)) { return [pscustomobject]@{ Ok = $false; Reason = "restart ticket lacks $property" } }
        }
        if ([string]$State.Status -ne 'Armed') { return [pscustomobject]@{ Ok = $false; Reason = "restart ticket status is '$($State.Status)', not Armed" } }
        if ([string]$State.Intent -ne 'AutomaticSixHourRestart') { return [pscustomobject]@{ Ok = $false; Reason = 'restart ticket is not an automatic six-hour ticket' } }
        if ([string]$State.ShutdownCommand -ne 'server shutdown 300') { return [pscustomobject]@{ Ok = $false; Reason = 'restart ticket command is not server shutdown 300' } }
        if ([string]$State.ShutdownCommandStatus -ne 'Accepted') { return [pscustomobject]@{ Ok = $false; Reason = "shutdown command status is '$($State.ShutdownCommandStatus)', not Accepted" } }
        $ticketProcessId = 0
        if (-not [int]::TryParse([string]$State.Pid,[ref]$ticketProcessId) -or $ticketProcessId -le 0) { return [pscustomobject]@{ Ok = $false; Reason = 'restart ticket PID is invalid' } }
        if ($ticketProcessId -ne $ExitedPid) { return [pscustomobject]@{ Ok = $false; Reason = "restart ticket PID $ticketProcessId does not match exited PID $ExitedPid" } }
        $stateStart = ([datetime]::Parse([string]$State.StartTimeUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
        $preparingUtc = ([datetime]::Parse([string]$State.PreparingStartedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
        $armedUtc = ([datetime]::Parse([string]$State.ArmedAtUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
        $expectedUtc = ([datetime]::Parse([string]$State.ExpectedShutdownUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
        $acceptedUtc = ([datetime]::Parse([string]$State.CommandAcceptedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
        if ($stateStart.Ticks -ne $ExitedStartTimeUtc.ToUniversalTime().Ticks) { return [pscustomobject]@{ Ok = $false; Reason = 'restart ticket StartTimeUtc does not match exited worldserver' } }
        if ($preparingUtc -gt $armedUtc -or $armedUtc -gt $expectedUtc -or $acceptedUtc -lt $armedUtc.AddMinutes(-1) -or $acceptedUtc -gt $expectedUtc.AddMinutes(1)) {
            return [pscustomobject]@{ Ok = $false; Reason = 'restart ticket timestamp ordering is invalid' }
        }
        $deadlineUtc = $expectedUtc.AddSeconds($RestartTicketGraceSeconds)
        $nowUtc = Get-EffectiveUtcNow
        if ($nowUtc -gt $deadlineUtc) {
            return [pscustomobject]@{ Ok = $false; Reason = "accepted automatic restart ticket expired at $($deadlineUtc.ToString('o')); it cannot authorize this later exit" }
        }
        return [pscustomobject]@{ Ok = $true; Reason = ''; DeadlineUtc = $deadlineUtc }
    } catch {
        return [pscustomobject]@{ Ok = $false; Reason = "restart ticket is invalid: $($_.Exception.Message)" }
    }
}

function ConvertTo-ConsumedRestartState {
    param([Parameter(Mandatory)] $State)
    $values = [ordered]@{}
    foreach ($property in $State.PSObject.Properties) { $values[$property.Name] = $property.Value }
    $values['Status'] = 'Consumed'
    $values['LifecyclePhase'] = 'ConsumedAwaitingLaunch'
    $values['ConsumedAtUtc'] = (Get-EffectiveUtcNow).ToString('o')
    $values['ConsumedBySupervisorPid'] = $PID
    $values['ConsumedBySupervisorInstanceId'] = $SupervisorInstanceId
    return [pscustomobject]$values
}

function Update-ConsumedRestartState {
    param(
        [Parameter(Mandatory)][int] $ExitedWorldserverPid,
        [Parameter(Mandatory)][datetime] $ExitedWorldserverStartTimeUtc,
        [Parameter(Mandatory)][string] $LifecyclePhase,
        [AllowNull()] $ReplacementWorld,
        [long] $ReplacementLogOffset = -1
    )
    $state = Read-RestartState
    if ($null -eq $state -or $state -isnot [pscustomobject] -or ($state.PSObject.Properties.Name -contains 'Invalid' -and [bool]$state.Invalid)) { throw 'consumed restart state is missing or invalid' }
    $stateStart = ([datetime]::Parse([string]$state.StartTimeUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
    if ([string]$state.Status -ne 'Consumed' -or [int]$state.Pid -ne $ExitedWorldserverPid -or $stateStart.Ticks -ne $ExitedWorldserverStartTimeUtc.ToUniversalTime().Ticks) { throw 'consumed restart state no longer matches the exited worldserver identity' }
    if ([string]$state.ConsumedBySupervisorInstanceId -ne $SupervisorInstanceId) { throw 'consumed restart state is owned by a different supervisor instance' }
    $values = [ordered]@{}
    foreach ($property in $state.PSObject.Properties) { $values[$property.Name] = $property.Value }
    $values['LifecyclePhase'] = $LifecyclePhase
    $values[($LifecyclePhase + 'Utc')] = (Get-EffectiveUtcNow).ToString('o')
    if ($null -ne $ReplacementWorld) {
        $values['ReplacementPid'] = [int]$ReplacementWorld.Pid
        $values['ReplacementStartTimeUtc'] = $ReplacementWorld.StartTimeUtc.ToUniversalTime().ToString('o')
    }
    if ($ReplacementLogOffset -ge 0) { $values['ReplacementLogOffset'] = $ReplacementLogOffset }
    Write-RestartStateAtomic -State ([pscustomobject]$values)
}

function Recover-ConsumedStateForAdoptedWorld {
    param([Parameter(Mandatory)][Diagnostics.Process] $Process)
    $state = Read-RestartState
    if ($null -eq $state -or $state -isnot [pscustomobject] -or -not ($state.PSObject.Properties.Name -contains 'Status') -or [string]$state.Status -ne 'Consumed') { return }
    $identity = ConvertTo-WorldIdentity -Process $Process
    foreach ($property in @('LifecyclePhase','Pid','StartTimeUtc','ReplacementPid','ReplacementStartTimeUtc')) {
        if (-not ($state.PSObject.Properties.Name -contains $property)) { Write-Log "Consumed restart recovery is ambiguous because $property is missing. Existing worldserver will be supervised, but the ticket remains blocked for administrator review." 'ERROR'; return }
    }
    try {
        $replacementStart = ([datetime]::Parse([string]$state.ReplacementStartTimeUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
        if ([int]$state.ReplacementPid -ne $identity.Pid -or $replacementStart.Ticks -ne $identity.StartTimeUtc.Ticks) { throw 'recorded replacement identity does not match the adopted worldserver' }
        $values = [ordered]@{}
        foreach ($property in $state.PSObject.Properties) { $values[$property.Name] = $property.Value }
        $values['ConsumedBySupervisorPid'] = $PID
        $values['ConsumedBySupervisorInstanceId'] = $SupervisorInstanceId
        Write-RestartStateAtomic -State ([pscustomobject]$values)
        $oldProcessId = [int]$state.Pid
        $oldStartUtc = ([datetime]::Parse([string]$state.StartTimeUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
        if ([string]$state.LifecyclePhase -ne 'ReplacementReady') {
            if (-not ($state.PSObject.Properties.Name -contains 'ReplacementLogOffset')) { throw 'replacement readiness is unfinished and no launch log checkpoint is recorded' }
            if (-not (Wait-WorldReady -Process $Process -TimeoutSeconds $StartupTimeoutSeconds -InitialLogOffset ([long]$state.ReplacementLogOffset))) { throw 'adopted replacement did not reach attributable readiness' }
            Update-ConsumedRestartState -ExitedWorldserverPid $oldProcessId -ExitedWorldserverStartTimeUtc $oldStartUtc -LifecyclePhase 'ReplacementReady' -ReplacementWorld $identity
        } else {
            Write-SupervisorState -Status 'Supervising' -World $identity
        }
        [void](Clear-ConsumedRestartState -ExitedWorldserverPid $oldProcessId -ExitedWorldserverStartTimeUtc $oldStartUtc -ReplacementWorld $identity)
        Write-Log "Recovered supervision of replacement PID=$($identity.Pid) from a consumed ticket without launching another process." 'OK'
    } catch {
        Write-Log "Consumed replacement recovery remains blocked and no second process was launched: $($_.Exception.Message)" 'ERROR'
    }
}

function Clear-ConsumedRestartState {
    param(
        [Parameter(Mandatory)][int] $ExitedWorldserverPid,
        [Parameter(Mandatory)][datetime] $ExitedWorldserverStartTimeUtc,
        [Parameter(Mandatory)] $ReplacementWorld
    )
    try {
        $state = Read-RestartState
        if ($null -eq $state -or $state -isnot [pscustomobject] -or ($state.PSObject.Properties.Name -contains 'Invalid' -and [bool]$state.Invalid)) { throw 'consumed restart state is missing or invalid' }
        $stateStart = ([datetime]::Parse([string]$state.StartTimeUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
        $replacementStart = ([datetime]::Parse([string]$state.ReplacementStartTimeUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
        if ([string]$state.Status -ne 'Consumed' -or [string]$state.LifecyclePhase -ne 'ReplacementReady') { throw 'ticket is not in ReplacementReady phase' }
        if ([int]$state.Pid -ne $ExitedWorldserverPid -or $stateStart.Ticks -ne $ExitedWorldserverStartTimeUtc.ToUniversalTime().Ticks) { throw 'ticket no longer matches the exited identity' }
        if ([string]$state.ConsumedBySupervisorInstanceId -ne $SupervisorInstanceId) { throw 'ticket is owned by a different supervisor instance' }
        if ([int]$state.ReplacementPid -ne [int]$ReplacementWorld.Pid -or $replacementStart.Ticks -ne $ReplacementWorld.StartTimeUtc.ToUniversalTime().Ticks) { throw 'replacement identity does not match the ready worldserver' }
        Remove-Item -LiteralPath $RestartStateFile -Force -ErrorAction Stop
        Write-Log "Cleared finalized automatic restart ticket for old PID=$ExitedWorldserverPid after replacement PID=$($ReplacementWorld.Pid) became ready and its heartbeat was published." 'INFO'
        return $true
    } catch { Write-Log "Consumed automatic restart ticket was retained conservatively: $($_.Exception.Message)" 'WARN'; return $false }
}

function Initialize-TestRestartTicket {
    if ($TestRestartTicket -eq 'Live') { return }
    if ([string]::IsNullOrWhiteSpace($TestStateFile) -and [string]::IsNullOrWhiteSpace($TestRoot)) { throw 'Supervisor ticket tests require -TestStateFile or -TestRoot.' }
    if (Test-Path -LiteralPath $RestartStateFile) { return }
    $testPid = 4201
    $start = [datetime]::Parse('2026-01-01T00:00:00.0000000Z',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime().ToString('o')
    $testNow = Get-EffectiveUtcNow
    $base = [ordered]@{
        Status = 'Armed'
        Intent = 'AutomaticSixHourRestart'
        Pid = $testPid
        StartTimeUtc = $start
        PreparingStartedUtc = $testNow.AddMinutes(-6).ToString('o')
        ArmedAtUtc = $testNow.AddMinutes(-5).ToString('o')
        ExpectedShutdownUtc = $testNow.AddMinutes(1).ToString('o')
        ShutdownCommand = 'server shutdown 300'
        ShutdownCommandStatus = 'Accepted'
        CommandAcceptedUtc = $testNow.AddMinutes(-5).ToString('o')
    }
    switch ($TestRestartTicket) {
        'Missing' { return }
        'Empty' { Set-Content -LiteralPath $RestartStateFile -Value '' -Encoding UTF8; return }
        'JsonNull' { Set-Content -LiteralPath $RestartStateFile -Value 'null' -Encoding UTF8; return }
        'EmptyObject' { Write-RestartStateAtomic -State ([pscustomobject]@{}); return }
        'Malformed' { Set-Content -LiteralPath $RestartStateFile -Value '{not-json' -Encoding UTF8; return }
        'MissingStatus' { $base.Remove('Status') }
        'MissingPid' { $base.Remove('Pid') }
        'MissingStartTime' { $base.Remove('StartTimeUtc') }
        'WrongTypes' { $base['Pid'] = 'not-an-integer'; $base['ExpectedShutdownUtc'] = @('not','a','timestamp') }
        'UnknownStatus' { $base['Status'] = 'UnknownFutureState' }
        'Preparing' { $base['Status'] = 'Preparing' }
        'Blocked' { $base['Status'] = 'Blocked'; $base['ShutdownCommandStatus'] = 'Blocked' }
        'Ambiguous' { $base['Status'] = 'Ambiguous'; $base['ShutdownCommandStatus'] = 'Ambiguous' }
        'Consumed' { $base['Status'] = 'Consumed'; $base['LifecyclePhase'] = 'ReplacementReady'; $base['ConsumedBySupervisorPid'] = $PID; $base['ConsumedBySupervisorInstanceId'] = $SupervisorInstanceId; $base['ConsumedAtUtc'] = $testNow.ToString('o') }
        'Pending' { $base['ShutdownCommandStatus'] = 'Pending' }
        'WrongPid' { $base['Pid'] = 4202 }
        'WrongStartTime' { $base['StartTimeUtc'] = ([datetime]::UtcNow).AddHours(-2).ToString('o') }
        'BeforeExpected' { $base['ExpectedShutdownUtc'] = $testNow.AddMinutes(5).ToString('o') }
        'InsideGrace' { $base['ExpectedShutdownUtc'] = $testNow.AddMinutes(-10).ToString('o'); $base['ArmedAtUtc'] = $testNow.AddMinutes(-15).ToString('o'); $base['PreparingStartedUtc'] = $testNow.AddMinutes(-16).ToString('o'); $base['CommandAcceptedUtc'] = $testNow.AddMinutes(-15).ToString('o') }
        'Expired' { $base['ExpectedShutdownUtc'] = $testNow.AddMinutes(-21).ToString('o'); $base['ArmedAtUtc'] = $testNow.AddMinutes(-26).ToString('o'); $base['PreparingStartedUtc'] = $testNow.AddMinutes(-27).ToString('o'); $base['CommandAcceptedUtc'] = $testNow.AddMinutes(-26).ToString('o') }
        'ValidArmed' { }
        'MatchingProcess' { }
        'FullLifecycle' { }
        'ReadinessTimeout' { }
        'ReplacementDies' { }
        'CrashAfterConsumed' { }
        'CrashAfterLaunchStarted' { }
        'CrashAfterProcessStart' { }
        'CrashAfterReadiness' { }
    }
    Write-RestartStateAtomic -State ([pscustomobject]$base)
}

function Get-TestExitCodeText {
    if ($SimulatedExitCode -lt 0) { return 'unavailable' }
    return [string]$SimulatedExitCode
}

$mutex = New-Object System.Threading.Mutex($false,$SupervisorMutexName)
$haveLock = $false
try {
    try { $haveLock = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $haveLock = $true; Write-Log 'Recovered an abandoned supervisor mutex.' 'WARN' }
    if (-not $haveLock) { Write-Log 'Duplicate supervisor invocation ignored.' 'WARN'; exit 0 }
    if ($DryRun) {
        Initialize-TestRestartTicket
        $testStart = [datetime]::Parse('2026-01-01T00:00:00.0000000Z',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        $testState = Read-RestartState
        $testDecision = Test-AutomaticRestartTicket -State $testState -ExitedPid 4201 -ExitedStartTimeUtc $testStart
        $exitText = Get-TestExitCodeText
        $diagnosticKind = if ($SimulatedExitCode -lt 0) { 'EXIT_CODE_UNAVAILABLE' } else { Classify-ExitCode -Code $SimulatedExitCode }
        Write-Log "DryRun observed exit code $exitText ($diagnosticKind); exit code is diagnostic only." 'INFO'
        Write-Host "DryRun observed exit code $exitText ($diagnosticKind); exit code is diagnostic only."
        if (-not $testDecision.Ok) {
            Write-Log "DryRun: no automatic relaunch permitted: $($testDecision.Reason)" 'INFO'
            Write-Host "DryRun: no automatic relaunch permitted: $($testDecision.Reason)"
            exit 0
        }
        $consumed = ConvertTo-ConsumedRestartState -State $testState
        Write-RestartStateAtomic -State $consumed
        if ($TestRestartTicket -eq 'MatchingProcess') {
            Write-Log 'DryRun: valid ticket consumed, but a matching worldserver already exists; no duplicate launch attempted.' 'OK'
            Write-Host 'DryRun: valid ticket consumed, but a matching worldserver already exists; no duplicate launch attempted.'
        } elseif ($TestRestartTicket -eq 'AdoptedReadiness') {
            $oldStartUtc = $testStart
            $replacementIdentity = [pscustomobject]@{ Pid = 4301; StartTimeUtc = (Get-EffectiveUtcNow).AddSeconds(1); Process = $null }
            Update-ConsumedRestartState -ExitedWorldserverPid 4201 -ExitedWorldserverStartTimeUtc $oldStartUtc -LifecyclePhase 'ReplacementLaunchStarted' -ReplacementWorld $null -ReplacementLogOffset 123
            Update-ConsumedRestartState -ExitedWorldserverPid 4201 -ExitedWorldserverStartTimeUtc $oldStartUtc -LifecyclePhase 'ReplacementLaunching' -ReplacementWorld $replacementIdentity -ReplacementLogOffset 123
            if (-not (Wait-WorldReady -Process $null -TimeoutSeconds $StartupTimeoutSeconds -InitialLogOffset 123)) { throw 'adopted replacement readiness test failed' }
            Update-ConsumedRestartState -ExitedWorldserverPid 4201 -ExitedWorldserverStartTimeUtc $oldStartUtc -LifecyclePhase 'ReplacementReady' -ReplacementWorld $replacementIdentity
            Write-SupervisorState -Status 'Supervising' -World $replacementIdentity
            if (-not (Clear-ConsumedRestartState -ExitedWorldserverPid 4201 -ExitedWorldserverStartTimeUtc $oldStartUtc -ReplacementWorld $replacementIdentity)) { throw 'adopted replacement readiness test could not finalize the consumed ticket' }
            Write-Log 'DryRun adopted replacement passed shared readiness validation before heartbeat publication and ticket cleanup; no duplicate launch attempted.' 'OK'
            Write-Host 'DryRun adopted replacement passed readiness before heartbeat and ticket cleanup; no duplicate launch attempted.'
        } elseif ($TestRestartTicket -eq 'CrashAfterConsumed') {
            Write-Host 'DryRun crash point: ticket is ConsumedAwaitingLaunch; a new supervisor may not consume or launch from it.'
        } elseif ($TestRestartTicket -eq 'CrashAfterLaunchStarted') {
            Update-ConsumedRestartState -ExitedWorldserverPid 4201 -ExitedWorldserverStartTimeUtc $testStart -LifecyclePhase 'ReplacementLaunchStarted' -ReplacementWorld $null -ReplacementLogOffset 123
            Write-Host 'DryRun crash point: ReplacementLaunchStarted with no replacement identity; administrator review is required.'
        } elseif ($TestRestartTicket -in @('CrashAfterProcessStart','ReadinessTimeout','ReplacementDies','CrashAfterReadiness','FullLifecycle')) {
            $oldStartUtc = $testStart
            Update-ConsumedRestartState -ExitedWorldserverPid 4201 -ExitedWorldserverStartTimeUtc $oldStartUtc -LifecyclePhase 'ReplacementLaunchStarted' -ReplacementWorld $null
            $replacementIdentity = [pscustomobject]@{ Pid = 4301; StartTimeUtc = (Get-EffectiveUtcNow).AddSeconds(1); Process = $null }
            Update-ConsumedRestartState -ExitedWorldserverPid 4201 -ExitedWorldserverStartTimeUtc $oldStartUtc -LifecyclePhase 'ReplacementLaunching' -ReplacementWorld $replacementIdentity -ReplacementLogOffset 123
            if ($TestRestartTicket -eq 'CrashAfterProcessStart') { Write-Host 'DryRun crash point: replacement identity is durably recorded; no second launch is authorized.'; exit 0 }
            if ($TestRestartTicket -eq 'ReadinessTimeout') { Write-Host 'DryRun readiness timeout: consumed ReplacementLaunching state remains protective; no duplicate launch is authorized.'; exit 0 }
            if ($TestRestartTicket -eq 'ReplacementDies') { Write-Host 'DryRun replacement died before readiness: consumed ReplacementLaunching state remains protective; no crash loop is entered.'; exit 0 }
            Write-SupervisorState -Status 'Starting' -World $replacementIdentity
            Write-SupervisorState -Status 'Supervising' -World $replacementIdentity
            Update-ConsumedRestartState -ExitedWorldserverPid 4201 -ExitedWorldserverStartTimeUtc $oldStartUtc -LifecyclePhase 'ReplacementReady' -ReplacementWorld $replacementIdentity
            if ($TestRestartTicket -eq 'CrashAfterReadiness') { Write-Host 'DryRun crash point: replacement is ready and identified; restart ticket remains one-shot Consumed.'; exit 0 }
            if (-not (Clear-ConsumedRestartState -ExitedWorldserverPid 4201 -ExitedWorldserverStartTimeUtc $oldStartUtc -ReplacementWorld $replacementIdentity)) { throw 'full lifecycle test could not finalize the consumed ticket' }
            Write-SupervisorState -Status 'Supervising' -World $replacementIdentity
            $publishedState = Get-Content -LiteralPath $SupervisorStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([int]$publishedState.WorldserverPid -ne 4301 -or [string]$publishedState.Status -ne 'Supervising' -or (Test-Path -LiteralPath $RestartStateFile)) { throw 'full lifecycle test did not publish the replacement identity or finalize the consumed ticket' }
            Write-Log 'DryRun full lifecycle completed: replacement ready, old ticket finalized, new heartbeat published, and supervision continued.' 'OK'
            Write-Host 'DryRun full lifecycle completed: replacement ready, old ticket finalized, new heartbeat published, and supervision continued.'
        } else {
            Write-Log 'DryRun: valid exact Armed ticket consumed; exactly one replacement launch would be permitted.' 'OK'
            Write-Host 'DryRun: valid exact Armed ticket consumed; exactly one replacement launch would be permitted.'
        }
        exit 0
    }
    $worldRows = @(Get-WorldProcesses)
    if ($worldRows.Count -gt 1) { Write-Log "Safety stop: $($worldRows.Count) matching worldserver processes exist; no launch attempted." 'ERROR'; exit 1 }
    if ($worldRows.Count -eq 1) {
        $world = Get-Process -Id ([int]$worldRows[0].ProcessId) -ErrorAction Stop
        Write-Log "Adopting existing worldserver PID=$($world.Id), StartTime=$($world.StartTime.ToString('o')); no restart is being performed." 'INFO'
        $script:CurrentWorld = $world
        try { Write-SupervisorState -Status 'Supervising' -World (ConvertTo-WorldIdentity -Process $world) } catch { Write-Log "Could not publish supervisor heartbeat; watcher will remain blocked: $($_.Exception.Message)" 'ERROR' }
        Recover-ConsumedStateForAdoptedWorld -Process $world
    } else {
        $unresolvedState = Read-RestartState
        if ($null -ne $unresolvedState) {
            $unresolvedDescription = if ($unresolvedState -is [pscustomobject] -and $unresolvedState.PSObject.Properties.Name -contains 'Status') { "status '$($unresolvedState.Status)'" } else { 'malformed or unreadable state' }
            Write-Log "Worldserver is absent but restart-state.json contains $unresolvedDescription. Supervisor will not launch from ambiguous persistent state. Administrator must inspect/back up and deliberately resolve the state before using the supported START workflow." 'ERROR'
            exit 1
        }
        $startupLogCheckpoint = Get-ServerLogCheckpoint
        $world = Start-Worldserver
        $script:CurrentWorld = $world
        if (-not (Wait-WorldReady -Process $world -TimeoutSeconds $StartupTimeoutSeconds -InitialLogOffset $startupLogCheckpoint)) { exit 1 }
    }
    while ($true) {
        $startedAt = $world.StartTime
        if (-not $world.WaitForExit($HeartbeatIntervalSeconds * 1000)) {
            try { Write-SupervisorState -Status 'Supervising' -World (ConvertTo-WorldIdentity -Process $world) } catch { Write-Log "Supervisor heartbeat write failed; watcher will remain blocked: $($_.Exception.Message)" 'ERROR' }
            continue
        }
        $exitCode = $null
        try { $exitCode = [int]$world.ExitCode } catch { }
        $exitedPid = [int]$world.Id
        $exitText = if ($null -eq $exitCode) { 'unavailable' } else { [string]$exitCode }
        $kind = if ($null -eq $exitCode) { 'EXIT_CODE_UNAVAILABLE' } else { Classify-ExitCode -Code $exitCode }
        Write-Log "worldserver PID=$($world.Id) exited with code $exitText ($kind); process exit code is diagnostic only." $(if($kind -eq 'ABNORMAL_EXIT'){'ERROR'}else{'INFO'})
        $ticket = Read-RestartState
        $ticketDecision = Test-AutomaticRestartTicket -State $ticket -ExitedPid $exitedPid -ExitedStartTimeUtc $startedAt.ToUniversalTime()
        if (-not $ticketDecision.Ok) {
            if ($kind -eq 'ABNORMAL_EXIT') {
                Write-Log "Unexpected worldserver exit without a valid exact Armed automatic ticket: $($ticketDecision.Reason). Supervisor will not enter a crash restart loop." 'ERROR'
                exit 1
            }
            Write-Log "worldserver PID=$($world.Id) exited without a valid exact Armed automatic ticket: $($ticketDecision.Reason). No relaunch will occur." 'INFO'
            exit 0
        }
        Write-Log "worldserver PID=$($world.Id) exited; valid Armed automatic restart ticket matched exact PID/StartTimeUtc. ExitCode=$exitText. Relaunch permitted." 'OK'
        try {
            Write-RestartStateAtomic -State (ConvertTo-ConsumedRestartState -State $ticket)
            Write-Log "Automatic restart ticket consumed for PID=$($world.Id); duplicate relaunch is now blocked." 'INFO'
        } catch {
            Write-Log "Could not consume the automatic restart ticket safely: $($_.Exception.Message). No relaunch will occur." 'ERROR'
            exit 1
        }
        try {
            Update-ConsumedRestartState -ExitedWorldserverPid $exitedPid -ExitedWorldserverStartTimeUtc $startedAt.ToUniversalTime() -LifecyclePhase 'ReplacementLaunchStarted' -ReplacementWorld $null
            Write-Log "Consumed ticket lifecycle advanced to ReplacementLaunchStarted for old PID=$exitedPid. A crash before replacement identity is recorded requires administrator review and cannot authorize a second launch." 'INFO'
        } catch {
            Write-Log "Could not durably record replacement launch phase: $($_.Exception.Message). No relaunch will occur." 'ERROR'
            exit 1
        }
        $replacementLogCheckpoint = Get-ServerLogCheckpoint
        try { Update-ConsumedRestartState -ExitedWorldserverPid $exitedPid -ExitedWorldserverStartTimeUtc $startedAt.ToUniversalTime() -LifecyclePhase 'ReplacementLaunchStarted' -ReplacementWorld $null -ReplacementLogOffset $replacementLogCheckpoint }
        catch { Write-Log "Could not persist the pre-launch Server.log checkpoint: $($_.Exception.Message). No replacement was launched." 'ERROR'; exit 1 }
        Start-Sleep -Seconds $RestartBackoffSeconds
        $existing = @(Get-WorldProcesses)
        if ($existing.Count -gt 1) { Write-Log "Safety stop: $($existing.Count) matching worldserver processes exist after ticket consumption; no launch attempted." 'ERROR'; exit 1 }
        if ($existing.Count -eq 1) {
            $world = Get-Process -Id ([int]$existing[0].ProcessId) -ErrorAction Stop
            $script:CurrentWorld = $world
            Write-Log "A matching worldserver already exists at PID=$($world.Id); adopting it and not launching a duplicate." 'WARN'
            $adoptedIdentity = ConvertTo-WorldIdentity -Process $world
            try {
                Update-ConsumedRestartState -ExitedWorldserverPid $exitedPid -ExitedWorldserverStartTimeUtc $startedAt.ToUniversalTime() -LifecyclePhase 'ReplacementLaunching' -ReplacementWorld $adoptedIdentity -ReplacementLogOffset $replacementLogCheckpoint
                if (-not (Wait-WorldReady -Process $world -TimeoutSeconds $StartupTimeoutSeconds -InitialLogOffset $replacementLogCheckpoint)) {
                    Write-Log "Adopted replacement PID=$($world.Id) failed readiness validation; consumed state remains protective and no duplicate launch will be attempted." 'ERROR'
                    exit 1
                }
                Update-ConsumedRestartState -ExitedWorldserverPid $exitedPid -ExitedWorldserverStartTimeUtc $startedAt.ToUniversalTime() -LifecyclePhase 'ReplacementReady' -ReplacementWorld $adoptedIdentity
                Write-SupervisorState -Status 'Supervising' -World $adoptedIdentity
                [void](Clear-ConsumedRestartState -ExitedWorldserverPid $exitedPid -ExitedWorldserverStartTimeUtc $startedAt.ToUniversalTime() -ReplacementWorld $adoptedIdentity)
            } catch { Write-Log "Could not safely finalize adopted replacement lifecycle: $($_.Exception.Message). The process remains untouched and the consumed state remains protective." 'ERROR' }
            continue
        }
        $world = Start-Worldserver
        $script:CurrentWorld = $world
        $replacementIdentity = ConvertTo-WorldIdentity -Process $world
        try { Update-ConsumedRestartState -ExitedWorldserverPid $exitedPid -ExitedWorldserverStartTimeUtc $startedAt.ToUniversalTime() -LifecyclePhase 'ReplacementLaunching' -ReplacementWorld $replacementIdentity }
        catch { Write-Log "Replacement PID=$($world.Id) started but its identity could not be persisted: $($_.Exception.Message). No process was terminated; administrator review is required." 'ERROR'; exit 1 }
        if (-not (Wait-WorldReady -Process $world -TimeoutSeconds $StartupTimeoutSeconds -InitialLogOffset $replacementLogCheckpoint)) { exit 1 }
        try { Update-ConsumedRestartState -ExitedWorldserverPid $exitedPid -ExitedWorldserverStartTimeUtc $startedAt.ToUniversalTime() -LifecyclePhase 'ReplacementReady' -ReplacementWorld $replacementIdentity }
        catch { Write-Log "Replacement is ready but lifecycle finalization failed: $($_.Exception.Message). Supervision will continue and the consumed state remains protective." 'ERROR' }
        [void](Clear-ConsumedRestartState -ExitedWorldserverPid $exitedPid -ExitedWorldserverStartTimeUtc $startedAt.ToUniversalTime() -ReplacementWorld $replacementIdentity)
        Write-Log "Supervisor relaunched worldserver with PID $($world.Id); new PID/start time and fresh heartbeat are published." 'OK'
    }
} catch {
    Write-Log "Supervisor stopped safely: $($_.Exception.Message)" 'ERROR'
    exit 1
} finally {
    Remove-SupervisorStateIfOwned
    if ($haveLock) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
