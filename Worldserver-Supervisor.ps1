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
    [int] $RapidRestartFloorSeconds = 60,
    [ValidateSet('Live','ValidArmed','Missing','Malformed','Preparing','Blocked','Ambiguous','WrongPid','WrongStartTime','Consumed','Pending','MatchingProcess')][string] $TestRestartTicket = 'Live',
    [string] $TestStateFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OpsRoot = $PSScriptRoot
$BinDir = 'C:\azeroth\build\bin\RelWithDebInfo'
$WorldExe = Join-Path $BinDir 'worldserver.exe'
$ServerLog = Join-Path $BinDir 'Server.log'
$LogDir = Join-Path $OpsRoot 'logs'
$SupervisorStateFile = Join-Path $OpsRoot 'state\supervisor-state.json'
$RestartStateFile = Join-Path $OpsRoot 'state\restart-state.json'
$WorldPort = 8085
$HeartbeatIntervalSeconds = 10
$SupervisorStartedUtc = [datetime]::UtcNow
$script:CurrentWorld = $null
$SupervisorMutexName = if ($DryRun) { 'Global\AzerothCoreWorldserverSupervisorTest' } else { 'Global\AzerothCoreWorldserverSupervisor' }

if (-not [string]::IsNullOrWhiteSpace($TestStateFile)) {
    if (-not $DryRun) { throw '-TestStateFile requires -DryRun.' }
    $RestartStateFile = [IO.Path]::GetFullPath($TestStateFile)
}

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log {
    param([Parameter(Mandatory)][string] $Message, [ValidateSet('INFO','WARN','ERROR','OK')][string] $Level = 'INFO')
    $file = Join-Path $LogDir ('worldserver-restart-{0}.log' -f (Get-Date -Format 'yyyy-MM'))
    Add-Content -LiteralPath $file -Value ('{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message) -Encoding UTF8
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
    }
    $tmp = '{0}.{1}.tmp' -f $SupervisorStateFile, ([guid]::NewGuid().ToString('N'))
    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $SupervisorStateFile -Force
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

function Get-WorldProcesses {
    $expected = [IO.Path]::GetFullPath($WorldExe).TrimEnd('\').ToLowerInvariant()
    try {
        $rows = @(Get-CimInstance Win32_Process -Filter "Name='worldserver.exe'" | Where-Object {
            $_.ExecutablePath -and ([IO.Path]::GetFullPath($_.ExecutablePath).TrimEnd('\').ToLowerInvariant() -eq $expected)
        })
        return $rows
    } catch { throw "Cannot inspect worldserver executable path: $($_.Exception.Message)" }
}

function ConvertTo-WorldIdentity {
    param([Parameter(Mandatory)] $Process)
    [pscustomobject]@{ Pid = $Process.Id; StartTimeUtc = $Process.StartTime.ToUniversalTime(); Process = $Process }
}

function Wait-WorldReady {
    param([Parameter(Mandatory)] [Diagnostics.Process] $Process, [int] $TimeoutSeconds)
    $identity = ConvertTo-WorldIdentity -Process $Process
    try { Write-SupervisorState -Status 'Starting' -World $identity } catch { Write-Log "Supervisor heartbeat write failed during startup; watcher will remain blocked: $($_.Exception.Message)" 'ERROR' }
    $offset = 0L
    if (Test-Path -LiteralPath $ServerLog) { $offset = (Get-Item -LiteralPath $ServerLog).Length }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try { Write-SupervisorState -Status 'Starting' -World $identity } catch { }
        if ($Process.HasExited) { Write-Log "worldserver exited during startup with code $($Process.ExitCode)." 'ERROR'; return $false }
        if (Test-TcpPort -Port $WorldPort) {
            if (Test-Path -LiteralPath $ServerLog) {
                try {
                    $stream = [IO.File]::Open($ServerLog,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
                    try {
                        $stream.Seek($offset,[IO.SeekOrigin]::Begin) | Out-Null
                        $reader = New-Object IO.StreamReader($stream)
                        try { $newText = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    } finally { $stream.Dispose() }
                    if ($newText -match 'worldserver-daemon\) ready') {
                        try { Write-SupervisorState -Status 'Supervising' -World $identity } catch { Write-Log "Supervisor heartbeat write failed at readiness; watcher will remain blocked: $($_.Exception.Message)" 'ERROR' }
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
    return Start-Process -FilePath $WorldExe -WorkingDirectory $BinDir -PassThru
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
    try {
        $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $RestartStateFile -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Test-AutomaticRestartTicket {
    param(
        [Parameter(Mandatory)][AllowNull()] $State,
        [Parameter(Mandatory)][int] $ExitedPid,
        [Parameter(Mandatory)][datetime] $ExitedStartTimeUtc
    )
    if ($null -eq $State) { return [pscustomobject]@{ Ok = $false; Reason = 'restart-state.json is missing' } }
    if ($State.PSObject.Properties.Name -contains 'Invalid' -and [bool]$State.Invalid) { return [pscustomobject]@{ Ok = $false; Reason = "restart-state.json is malformed: $($State.Reason)" } }
    foreach ($property in @('Status','Intent','Pid','StartTimeUtc','PreparingStartedUtc','ArmedAtUtc','ExpectedShutdownUtc','ShutdownCommand','ShutdownCommandStatus')) {
        if (-not ($State.PSObject.Properties.Name -contains $property)) { return [pscustomobject]@{ Ok = $false; Reason = "restart ticket lacks $property" } }
    }
    if ([string]$State.Status -ne 'Armed') { return [pscustomobject]@{ Ok = $false; Reason = "restart ticket status is '$($State.Status)', not Armed" } }
    if ([string]$State.Intent -ne 'AutomaticSixHourRestart') { return [pscustomobject]@{ Ok = $false; Reason = 'restart ticket is not an automatic six-hour ticket' } }
    if ([string]$State.ShutdownCommand -ne 'server shutdown 300') { return [pscustomobject]@{ Ok = $false; Reason = 'restart ticket command is not server shutdown 300' } }
    if ([string]$State.ShutdownCommandStatus -ne 'Accepted') { return [pscustomobject]@{ Ok = $false; Reason = "shutdown command status is '$($State.ShutdownCommandStatus)', not Accepted" } }
    if ([int]$State.Pid -ne $ExitedPid) { return [pscustomobject]@{ Ok = $false; Reason = "restart ticket PID $($State.Pid) does not match exited PID $ExitedPid" } }
    try {
        $stateStart = ([datetime]::Parse([string]$State.StartTimeUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
        foreach ($property in @('PreparingStartedUtc','ArmedAtUtc','ExpectedShutdownUtc')) { [datetime]::Parse([string]$State.$property,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind) | Out-Null }
    } catch { return [pscustomobject]@{ Ok = $false; Reason = "restart ticket contains invalid timestamps: $($_.Exception.Message)" } }
    if ($stateStart.Ticks -ne $ExitedStartTimeUtc.ToUniversalTime().Ticks) { return [pscustomobject]@{ Ok = $false; Reason = 'restart ticket StartTimeUtc does not match exited worldserver' } }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

function ConvertTo-ConsumedRestartState {
    param([Parameter(Mandatory)] $State)
    $values = [ordered]@{}
    foreach ($property in $State.PSObject.Properties) { $values[$property.Name] = $property.Value }
    $values['Status'] = 'Consumed'
    $values['ConsumedAtUtc'] = [datetime]::UtcNow.ToString('o')
    $values['ConsumedBySupervisorPid'] = $PID
    return [pscustomobject]$values
}

function Clear-ConsumedRestartState {
    param([Parameter(Mandatory)][int] $Pid, [Parameter(Mandatory)][datetime] $StartTimeUtc)
    $state = Read-RestartState
    if ($null -eq $state -or ($state.PSObject.Properties.Name -contains 'Invalid' -and [bool]$state.Invalid)) { return }
    if ([string]$state.Status -eq 'Consumed' -and [int]$state.Pid -eq $Pid) {
        try {
            $stateStart = ([datetime]::Parse([string]$state.StartTimeUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
            if ($stateStart.Ticks -eq $StartTimeUtc.ToUniversalTime().Ticks -and [int]$state.ConsumedBySupervisorPid -eq $PID) {
                Remove-Item -LiteralPath $RestartStateFile -Force -ErrorAction Stop
                Write-Log "Cleared consumed automatic restart ticket for old PID=$Pid after the replacement became ready." 'INFO'
            }
        } catch { Write-Log "Consumed automatic restart ticket was retained conservatively: $($_.Exception.Message)" 'WARN' }
    }
}

function Initialize-TestRestartTicket {
    if ($TestRestartTicket -eq 'Live') { return }
    if ([string]::IsNullOrWhiteSpace($TestStateFile)) { throw 'Supervisor ticket tests require -TestStateFile.' }
    if (Test-Path -LiteralPath $RestartStateFile) { return }
    $testPid = 4201
    $start = [datetime]::Parse('2026-01-01T00:00:00.0000000Z',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime().ToString('o')
    $base = [ordered]@{
        Status = 'Armed'
        Intent = 'AutomaticSixHourRestart'
        Pid = $testPid
        StartTimeUtc = $start
        PreparingStartedUtc = ([datetime]::UtcNow).AddMinutes(-10).ToString('o')
        ArmedAtUtc = ([datetime]::UtcNow).AddMinutes(-5).ToString('o')
        ExpectedShutdownUtc = ([datetime]::UtcNow).AddMinutes(0).ToString('o')
        ShutdownCommand = 'server shutdown 300'
        ShutdownCommandStatus = 'Accepted'
    }
    switch ($TestRestartTicket) {
        'Missing' { return }
        'Malformed' { Set-Content -LiteralPath $RestartStateFile -Value '{not-json' -Encoding UTF8; return }
        'Preparing' { $base['Status'] = 'Preparing' }
        'Blocked' { $base['Status'] = 'Blocked'; $base['ShutdownCommandStatus'] = 'Blocked' }
        'Ambiguous' { $base['Status'] = 'Ambiguous'; $base['ShutdownCommandStatus'] = 'Ambiguous' }
        'Consumed' { $base['Status'] = 'Consumed'; $base['ConsumedBySupervisorPid'] = $PID; $base['ConsumedAtUtc'] = [datetime]::UtcNow.ToString('o') }
        'Pending' { $base['ShutdownCommandStatus'] = 'Pending' }
        'WrongPid' { $base['Pid'] = 4202 }
        'WrongStartTime' { $base['StartTimeUtc'] = ([datetime]::UtcNow).AddHours(-2).ToString('o') }
        'ValidArmed' { }
        'MatchingProcess' { }
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
    } else {
        $world = Start-Worldserver
        $script:CurrentWorld = $world
        if (-not (Wait-WorldReady -Process $world -TimeoutSeconds $StartupTimeoutSeconds)) { exit 1 }
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
        Start-Sleep -Seconds $RestartBackoffSeconds
        $existing = @(Get-WorldProcesses)
        if ($existing.Count -gt 1) { Write-Log "Safety stop: $($existing.Count) matching worldserver processes exist after ticket consumption; no launch attempted." 'ERROR'; exit 1 }
        if ($existing.Count -eq 1) {
            $world = Get-Process -Id ([int]$existing[0].ProcessId) -ErrorAction Stop
            $script:CurrentWorld = $world
            Write-Log "A matching worldserver already exists at PID=$($world.Id); adopting it and not launching a duplicate." 'WARN'
            try { Write-SupervisorState -Status 'Supervising' -World (ConvertTo-WorldIdentity -Process $world) } catch { Write-Log "Could not publish adopted worldserver heartbeat: $($_.Exception.Message)" 'ERROR'; exit 1 }
            Clear-ConsumedRestartState -Pid $exitedPid -StartTimeUtc $startedAt.ToUniversalTime()
            continue
        }
        $world = Start-Worldserver
        $script:CurrentWorld = $world
        if (-not (Wait-WorldReady -Process $world -TimeoutSeconds $StartupTimeoutSeconds)) { exit 1 }
        Clear-ConsumedRestartState -Pid $exitedPid -StartTimeUtc $startedAt.ToUniversalTime()
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
