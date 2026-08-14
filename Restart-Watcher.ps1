<#!
.SYNOPSIS
    Safely arms an AzerothCore worldserver maintenance shutdown from actual process uptime.

.DESCRIPTION
    This script is intentionally a watcher, not a process manager.  Its only
    worldserver control path is authenticated localhost SOAP.  SOAP failure is
    logged and leaves worldserver untouched.

    Production invocation is once per minute from Task Scheduler.  The watcher
    uses PID plus process StartTime as the instance identity and protects both
    the scheduled invocation and state transition with a named mutex.
#>
[CmdletBinding()]
param(
    [switch] $Preflight,
    [switch] $DryRun,
    [switch] $TestAnnouncement,
    [string] $SimulatedUptime,
    [ValidateSet('Actual','Absent','Simulated')][string] $TestWorldState = 'Actual',
    [ValidateSet('Live','PortUnavailable','AuthFailure','Success','SuccessThenDefinitiveFailure','SuccessThenAmbiguous')][string] $TestSoapResult = 'Live',
    [ValidateSet('Live','Missing','StaleHeartbeat','DeadSupervisor','PidMismatch','StartTimeMismatch','Valid','DisappearBeforeRestart')][string] $TestSupervisorState = 'Live',
    [datetime] $AtTime = [datetime]::MinValue,
    [int] $HoldLockSeconds = 0,
    [string] $TestStateFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OpsRoot = $PSScriptRoot
$BinDir = 'C:\azeroth\build\bin\RelWithDebInfo'
$WorldExe = Join-Path $BinDir 'worldserver.exe'
$WorldConfig = Join-Path $BinDir 'configs\worldserver.conf'
$SoapCredentialFile = Join-Path $OpsRoot 'state\soap-credential.xml'
$StateFile = Join-Path $OpsRoot 'state\restart-state.json'
$InvalidStateWarningFile = Join-Path $OpsRoot 'state\restart-state-invalid-warning.json'
$SupervisorStateFile = Join-Path $OpsRoot 'state\supervisor-state.json'
$LogDir = Join-Path $OpsRoot 'logs'
$SoapHost = '127.0.0.1'
$SoapPort = 7878
$WorldPort = 8085
$Threshold = [TimeSpan]::FromHours(5.9166666667)
$CountdownSeconds = 300
$HeartbeatMaxAgeSeconds = 30
$AutomaticIntent = 'AutomaticSixHourRestart'
$AutomaticShutdownCommand = 'server shutdown 300'
$PreparingBlockAfter = [TimeSpan]::FromMinutes(20)
$PreparingWarningRepeatAfter = [TimeSpan]::FromHours(1)
$InvalidStateWarningRepeatAfter = [TimeSpan]::FromHours(1)
$script:SupervisorValidationCalls = 0
$WatcherMutexName = if ($DryRun) { 'Global\AzerothCoreWorldserverRestartWatcherTest' } else { 'Global\AzerothCoreWorldserverRestartWatcher' }

if (-not [string]::IsNullOrWhiteSpace($TestStateFile)) {
    if (-not $DryRun) { throw '-TestStateFile requires -DryRun.' }
    $StateFile = [IO.Path]::GetFullPath($TestStateFile)
    $InvalidStateWarningFile = '{0}.invalid-warning.json' -f $StateFile
}

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
if (-not (Test-Path -LiteralPath (Split-Path -Parent $StateFile))) { New-Item -ItemType Directory -Path (Split-Path -Parent $StateFile) -Force | Out-Null }

function Get-EffectiveNow {
    if ($AtTime -ne [datetime]::MinValue) { return $AtTime }
    return Get-Date
}

function Write-Log {
    param([Parameter(Mandatory)][string] $Message, [ValidateSet('INFO','WARN','ERROR','OK')][string] $Level = 'INFO')
    $now = Get-EffectiveNow
    $file = Join-Path $LogDir ('worldserver-restart-{0}.log' -f $now.ToString('yyyy-MM'))
    $line = '{0} [{1,-5}] {2}' -f $now.ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $file -Value $line -Encoding UTF8
}

function Test-TcpPort {
    param([Parameter(Mandatory)][string] $HostName, [Parameter(Mandatory)][int] $Port, [int] $TimeoutMilliseconds = 1000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch { return $false }
    finally { $client.Dispose() }
}

function Get-WorldProcess {
    if ($TestWorldState -eq 'Absent') {
        if (-not $DryRun) { throw '-TestWorldState Absent requires -DryRun.' }
        return $null
    }
    if ($TestWorldState -eq 'Simulated') {
        if (-not $DryRun) { throw '-TestWorldState Simulated requires -DryRun.' }
        $simulatedStart = [datetime]::Parse('2026-01-01T00:00:00.0000000Z',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        return [pscustomobject]@{
            Process = $null
            Pid = 4201
            ParentPid = 0
            StartTime = $simulatedStart.ToLocalTime()
            StartTimeUtc = $simulatedStart
            Path = $WorldExe
        }
    }
    $expected = [IO.Path]::GetFullPath($WorldExe).TrimEnd('\').ToLowerInvariant()
    try {
        $rows = @(Get-CimInstance Win32_Process -Filter "Name='worldserver.exe'" | Where-Object {
            $_.ExecutablePath -and ([IO.Path]::GetFullPath($_.ExecutablePath).TrimEnd('\').ToLowerInvariant() -eq $expected)
        })
    } catch {
        throw "Cannot inspect worldserver executable paths: $($_.Exception.Message)"
    }
    if ($rows.Count -gt 1) { throw "Safety stop: more than one matching worldserver.exe exists ($($rows.Count))." }
    if ($rows.Count -eq 0) { return $null }
    $proc = Get-Process -Id ([int]$rows[0].ProcessId) -ErrorAction Stop
    [pscustomobject]@{
        Process = $proc
        Pid = [int]$rows[0].ProcessId
        ParentPid = [int]$rows[0].ParentProcessId
        StartTime = $proc.StartTime
        StartTimeUtc = $proc.StartTime.ToUniversalTime()
        Path = $rows[0].ExecutablePath
    }
}

function Get-SimulatedUptimeValue {
    if ([string]::IsNullOrWhiteSpace($SimulatedUptime)) { return $null }
    if (-not $DryRun) { throw '-SimulatedUptime requires -DryRun.' }
    try { return [TimeSpan]::Parse($SimulatedUptime, [Globalization.CultureInfo]::InvariantCulture) }
    catch { throw "Invalid -SimulatedUptime '$SimulatedUptime'. Use HH:mm:ss." }
}

function Get-WorldUptime {
    param([Parameter(Mandatory)] $World)
    $simulated = Get-SimulatedUptimeValue
    if ($null -ne $simulated) { return $simulated }
    return ((Get-EffectiveNow) - $World.StartTime)
}

function ConvertTo-UtcDateTime {
    param([Parameter(Mandatory)] [object] $Value)
    $parsed = [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    return $parsed.ToUniversalTime()
}

function Read-SupervisorState {
    if (-not (Test-Path -LiteralPath $SupervisorStateFile)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $SupervisorStateFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'empty supervisor state file' }
        return ($raw | ConvertFrom-Json)
    } catch {
        return [pscustomobject]@{ Invalid = $true; Reason = $_.Exception.Message }
    }
}

function Test-SupervisorProcessIdentity {
    param([Parameter(Mandatory)] [int] $SupervisorPid)
    try {
        $rows = @(Get-CimInstance Win32_Process -Filter "ProcessId=$SupervisorPid")
        if ($rows.Count -ne 1) { return [pscustomobject]@{ Ok = $false; Reason = 'supervisor PID is not alive' } }
        $row = $rows[0]
        $name = [IO.Path]::GetFileName([string]$row.ExecutablePath)
        if ($name -notmatch '(?i)^(powershell\.exe|pwsh\.exe)$') { return [pscustomobject]@{ Ok = $false; Reason = "supervisor PID is $name, not PowerShell" } }
        $scriptPath = [IO.Path]::GetFullPath((Join-Path $OpsRoot 'Worldserver-Supervisor.ps1')).ToLowerInvariant()
        $commandLine = ([string]$row.CommandLine).ToLowerInvariant().Replace('/','\')
        if ($commandLine -notmatch [regex]::Escape($scriptPath)) { return [pscustomobject]@{ Ok = $false; Reason = 'supervisor PID command line does not identify Worldserver-Supervisor.ps1' } }
        return [pscustomobject]@{ Ok = $true; Reason = '' }
    } catch {
        return [pscustomobject]@{ Ok = $false; Reason = "could not verify supervisor process identity: $($_.Exception.Message)" }
    }
}

function Test-SupervisorForWorld {
    param([Parameter(Mandatory)] $World)
    $script:SupervisorValidationCalls++
    if ($DryRun -and $TestSupervisorState -ne 'Live') {
        switch ($TestSupervisorState) {
            'Missing' { return [pscustomobject]@{ Ok = $false; Reason = 'supervisor state is missing (test)' } }
            'StaleHeartbeat' { return [pscustomobject]@{ Ok = $false; Reason = 'supervisor heartbeat is stale (test)' } }
            'DeadSupervisor' { return [pscustomobject]@{ Ok = $false; Reason = 'supervisor PID is dead (test)' } }
            'PidMismatch' { return [pscustomobject]@{ Ok = $false; Reason = 'supervisor state worldserver PID does not match (test)' } }
            'StartTimeMismatch' { return [pscustomobject]@{ Ok = $false; Reason = 'supervisor state worldserver StartTimeUtc does not match (test)' } }
            'Valid' { return [pscustomobject]@{ Ok = $true; Reason = '' } }
            'DisappearBeforeRestart' {
                if ($script:SupervisorValidationCalls -eq 1) { return [pscustomobject]@{ Ok = $true; Reason = '' } }
                return [pscustomobject]@{ Ok = $false; Reason = 'supervisor disappeared before restart command (test)' }
            }
        }
    }
    $state = Read-SupervisorState
    if ($null -eq $state) { return [pscustomobject]@{ Ok = $false; Reason = 'supervisor-state.json is missing' } }
    if ($state.PSObject.Properties.Name -contains 'Invalid' -and [bool]$state.Invalid) { return [pscustomobject]@{ Ok = $false; Reason = "supervisor-state.json is malformed: $($state.Reason)" } }
    foreach ($property in @('SupervisorPid','WorldserverPid','WorldserverStartTimeUtc','SupervisorStartedUtc','LastHeartbeatUtc','Status','SupervisorScriptPath')) {
        if (-not ($state.PSObject.Properties.Name -contains $property)) { return [pscustomobject]@{ Ok = $false; Reason = "supervisor state lacks $property" } }
    }
    if ([string]$state.Status -ne 'Supervising') { return [pscustomobject]@{ Ok = $false; Reason = "supervisor status is '$($state.Status)', not Supervising" } }
    try {
        $heartbeat = ConvertTo-UtcDateTime $state.LastHeartbeatUtc
        $age = ([datetime]::UtcNow - $heartbeat).TotalSeconds
        if ($age -lt -5 -or $age -gt $HeartbeatMaxAgeSeconds) { return [pscustomobject]@{ Ok = $false; Reason = "supervisor heartbeat is $([math]::Round($age,1)) seconds old" } }
        $stateStart = ConvertTo-UtcDateTime $state.WorldserverStartTimeUtc
    } catch { return [pscustomobject]@{ Ok = $false; Reason = "supervisor state contains invalid timestamps: $($_.Exception.Message)" } }
    if ([int]$state.WorldserverPid -ne $World.Pid) { return [pscustomobject]@{ Ok = $false; Reason = "supervisor state PID $($state.WorldserverPid) does not match current PID $($World.Pid)" } }
    if ($stateStart.Ticks -ne $World.StartTimeUtc.Ticks) { return [pscustomobject]@{ Ok = $false; Reason = 'supervisor state StartTimeUtc does not match current worldserver' } }
    try {
        $expectedScript = [IO.Path]::GetFullPath((Join-Path $OpsRoot 'Worldserver-Supervisor.ps1')).ToLowerInvariant()
        $reportedScript = [IO.Path]::GetFullPath([string]$state.SupervisorScriptPath).ToLowerInvariant()
    } catch { return [pscustomobject]@{ Ok = $false; Reason = "supervisor state has an invalid script path: $($_.Exception.Message)" } }
    if ($reportedScript -ne $expectedScript) { return [pscustomobject]@{ Ok = $false; Reason = 'supervisor state identifies a different supervisor script' } }
    $processCheck = Test-SupervisorProcessIdentity -SupervisorPid ([int]$state.SupervisorPid)
    if (-not $processCheck.Ok) { return $processCheck }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'empty state file' }
        $parsed = $raw | ConvertFrom-Json
        if ($null -eq $parsed) { throw 'state JSON root is null' }
        if ($parsed -isnot [pscustomobject]) { throw 'state JSON root is not an object' }
        return $parsed
    } catch {
        return [pscustomobject]@{ Invalid = $true; Reason = $_.Exception.Message }
    }
}

function Write-AtomicJsonFile {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Value)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $tmp = '{0}.{1}.tmp' -f $Path, ([guid]::NewGuid().ToString('N'))
    try {
        $Value | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Write-State {
    param([Parameter(Mandatory)] $State)
    Write-AtomicJsonFile -Path $StateFile -Value $State
}

function Clear-State {
    if (Test-Path -LiteralPath $StateFile) {
        Remove-Item -LiteralPath $StateFile -Force
        Write-Log 'Cleared stale restart state.' 'INFO'
    }
}

function Write-InvalidStateBlockedWarning {
    param([Parameter(Mandatory)][string] $Reason)
    $nowUtc = (Get-EffectiveNow).ToUniversalTime()
    $shouldLog = $true
    if (Test-Path -LiteralPath $InvalidStateWarningFile) {
        try {
            $marker = Get-Content -LiteralPath $InvalidStateWarningFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $lastWarningUtc = ConvertTo-UtcDateTime $marker.LastWarningUtc
            $shouldLog = (($nowUtc - $lastWarningUtc) -ge $InvalidStateWarningRepeatAfter)
        } catch {
            $shouldLog = $true
        }
    }
    if (-not $shouldLog) { return }
    Write-Log "Automatic maintenance BLOCKED: restart-state.json is malformed or unreadable ($Reason). The file was not modified or deleted; administrator recovery is required. No uptime decision, announcement, or restart command will be attempted." 'ERROR'
    try {
        Write-AtomicJsonFile -Path $InvalidStateWarningFile -Value ([pscustomobject]@{
            LastWarningUtc = $nowUtc.ToString('o')
            Reason = $Reason
        })
    } catch {
        Write-Log "Could not update malformed-state warning marker: $($_.Exception.Message)" 'WARN'
    }
}

function Handle-PreparingState {
    param([Parameter(Mandatory)] $State, [Parameter(Mandatory)] $World)
    $startedValue = if ($State.PSObject.Properties.Name -contains 'PreparingStartedUtc') { $State.PreparingStartedUtc } else { $State.ArmedAtUtc }
    try { $started = ConvertTo-UtcDateTime $startedValue } catch { Write-Log "Preparing state timestamp is invalid for PID $($World.Pid); automatic maintenance remains blocked." 'ERROR'; return }
    $age = [datetime]::UtcNow - $started
    if ($age -lt $PreparingBlockAfter) { return }
    $shouldLog = $true
    if ($State.PSObject.Properties.Name -contains 'PreparingWarningLoggedUtc') {
        try { $shouldLog = (([datetime]::UtcNow - (ConvertTo-UtcDateTime $State.PreparingWarningLoggedUtc)) -ge $PreparingWarningRepeatAfter) } catch { $shouldLog = $true }
    }
    if ($shouldLog) {
        Write-Log ("Automatic maintenance is blocked: Preparing state for PID {0} has persisted for {1}. Administrator must resolve it; it will not be cleared or retried automatically." -f $World.Pid,$age) 'ERROR'
        $State | Add-Member -NotePropertyName PreparingWarningLoggedUtc -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force
        Write-State $State
    }
}

function Get-SoapCredential {
    if (-not (Test-Path -LiteralPath $SoapCredentialFile)) { return $null }
    try {
        $credential = Import-Clixml -LiteralPath $SoapCredentialFile
        if ($credential -isnot [Management.Automation.PSCredential]) { throw 'credential file is not a PSCredential' }
        return $credential
    } catch {
        Write-Log "SOAP credential could not be decrypted by this identity: $($_.Exception.Message)" 'ERROR'
        return $null
    }
}

function Invoke-SoapCommand {
    param([Parameter(Mandatory)][string] $Command, [int] $TimeoutSec = 20)
    if ($DryRun) {
        switch ($TestSoapResult) {
            'Live' { return [pscustomobject]@{ Ok = $true; Reason = ''; Output = '<result>dry-run SOAP success</result>'; Outcome = 'Success' } }
            'PortUnavailable' { return [pscustomobject]@{ Ok = $false; Reason = "SOAP port $SoapPort on $SoapHost is not reachable (test injection)"; Output = ''; Outcome = 'DefinitiveFailure' } }
            'AuthFailure' { return [pscustomobject]@{ Ok = $false; Reason = 'HTTP 401 Unauthorized (test injection)'; Output = ''; Outcome = 'DefinitiveFailure' } }
            'Success' { return [pscustomobject]@{ Ok = $true; Reason = ''; Output = '<result>server info test success</result>' } }
            'SuccessThenDefinitiveFailure' {
                if ($Command -eq $AutomaticShutdownCommand) { return [pscustomobject]@{ Ok = $false; Reason = 'HTTP 401 Unauthorized (test injection)'; Output = ''; Outcome = 'DefinitiveFailure' } }
                return [pscustomobject]@{ Ok = $true; Reason = ''; Output = '<result>test success</result>'; Outcome = 'Success' }
            }
            'SuccessThenAmbiguous' {
                if ($Command -eq $AutomaticShutdownCommand) { return [pscustomobject]@{ Ok = $false; Reason = 'connection closed after submission (test injection)'; Output = ''; Outcome = 'Ambiguous' } }
                return [pscustomobject]@{ Ok = $true; Reason = ''; Output = '<result>test success</result>'; Outcome = 'Success' }
            }
        }
    }
    $credential = Get-SoapCredential
    if ($null -eq $credential) { return [pscustomobject]@{ Ok = $false; Reason = 'SOAP credential is not provisioned or cannot be decrypted'; Output = ''; Outcome = 'DefinitiveFailure' } }
    if (-not (Test-TcpPort -HostName $SoapHost -Port $SoapPort)) { return [pscustomobject]@{ Ok = $false; Reason = "SOAP port $SoapPort on $SoapHost is not reachable"; Output = ''; Outcome = 'DefinitiveFailure' } }

    $escaped = [Security.SecurityElement]::Escape($Command)
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
        $pair = '{0}:{1}' -f $credential.UserName, $plain
        $headers = @{
            Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
            'Content-Type' = 'application/xml'
        }
        try {
            $response = Invoke-WebRequest -Uri "http://$SoapHost`:$SoapPort/" -Method Post -Headers $headers -Body $body -TimeoutSec $TimeoutSec -UseBasicParsing
            $content = [string]$response.Content
            if ($content -match '(?i)<(?:[^:>]+:)?Fault\b|faultstring') { return [pscustomobject]@{ Ok = $false; Reason = 'SOAP returned a fault'; Output = ''; Outcome = 'DefinitiveFailure' } }
            return [pscustomobject]@{ Ok = $true; Reason = ''; Output = $content; Outcome = 'Success' }
        } catch {
            $status = $null
            if ($_.Exception.Response) { try { $status = [int]$_.Exception.Response.StatusCode } catch {} }
            if ($status -eq 401) { $reason = 'HTTP 401 Unauthorized (bad SOAP credentials or insufficient command permission)'; $outcome = 'DefinitiveFailure' }
            elseif ($null -ne $status) { $reason = "HTTP $status from SOAP"; $outcome = 'Ambiguous' }
            else { $reason = $_.Exception.Message; $outcome = 'Ambiguous' }
            return [pscustomobject]@{ Ok = $false; Reason = $reason; Output = ''; Outcome = $outcome }
        }
    } finally {
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        $plain = $null
    }
}

function Get-ReadableSoapOutput { param([string] $Xml)
    if ([string]::IsNullOrWhiteSpace($Xml)) { return '' }
    return (($Xml -replace '<[^>]+>', ' ') -replace '\s+', ' ').Trim()
}

function Assert-Preflight {
    $ok = $true
    Write-Log 'Starting non-destructive watcher preflight.' 'INFO'
    foreach ($path in @($WorldExe, $WorldConfig)) {
        if (Test-Path -LiteralPath $path) { Write-Log "Found $path" 'OK' }
        else { Write-Log "Missing required path: $path" 'ERROR'; $ok = $false }
    }
    if (Test-Path -LiteralPath $WorldConfig) {
        $lines = Get-Content -LiteralPath $WorldConfig
        $settings = @{}
        foreach ($line in $lines) {
            if ($line -match '^\s*SOAP\.(Enabled|IP|Port)\s*=\s*(.+?)\s*$') { $settings[$matches[1]] = $matches[2].Trim() }
        }
        Write-Log ("Configured SOAP.Enabled={0}, SOAP.IP={1}, SOAP.Port={2}" -f $settings['Enabled'],$settings['IP'],$settings['Port']) 'INFO'
        if ($settings['Enabled'] -ne '1' -or $settings['IP'] -notmatch '127\.0\.0\.1' -or $settings['Port'] -notmatch '7878') { $ok = $false; Write-Log 'SOAP configuration is not the required localhost-only 7878 configuration.' 'ERROR' }
    }
    $world = Get-WorldProcess
    if ($null -eq $world) { Write-Log 'worldserver is not running; preflight cannot execute server info.' 'WARN'; return 1 }
    $session = if ($null -ne $world.Process) { $world.Process.SessionId } else { 'simulated' }
    Write-Log ("worldserver PID={0}, ParentPID={1}, StartTime={2}, Session={3}" -f $world.Pid,$world.ParentPid,$world.StartTime.ToString('o'),$session) 'INFO'
    foreach ($port in @(8085,7878)) { if (Test-TcpPort -HostName '127.0.0.1' -Port $port) { Write-Log "TCP 127.0.0.1:$port is reachable." 'OK' } else { Write-Log "TCP 127.0.0.1:$port is not reachable." 'WARN'; if ($port -eq 7878) { $ok = $false } } }
    $soap = Invoke-SoapCommand -Command 'server info'
    if ($soap.Ok) { Write-Log ("SOAP server info succeeded: {0}" -f (Get-ReadableSoapOutput $soap.Output)) 'OK' }
    else { Write-Log "SOAP server info failed: $($soap.Reason)" 'ERROR'; $ok = $false }
    if ($ok) { Write-Log 'Preflight completed successfully; no restart command was sent.' 'OK'; return 0 }
    Write-Log 'Preflight failed; no restart command was sent.' 'ERROR'; return 1
}

function Invoke-TestAnnouncement {
    if ($DryRun) { Write-Log 'DryRun: would send one harmless test announcement; sent nothing.' 'INFO'; return 0 }
    $health = Invoke-SoapCommand -Command 'server info'
    if (-not $health.Ok) { Write-Log "Test announcement aborted because SOAP preflight failed: $($health.Reason)" 'ERROR'; return 1 }
    $result = Invoke-SoapCommand -Command 'announce [TEST] Restart automation SOAP test - no restart has been scheduled.'
    if ($result.Ok) { Write-Log 'Harmless SOAP test announcement sent once by explicit request.' 'OK'; return 0 }
    Write-Log "Harmless test announcement failed: $($result.Reason)" 'ERROR'; return 1
}

function Invoke-Watch {
    $state = Read-State
    if ($null -ne $state -and $state.PSObject.Properties.Name -contains 'Invalid' -and [bool]$state.Invalid) {
        Write-InvalidStateBlockedWarning -Reason ([string]$state.Reason)
        return 0
    }
    $world = Get-WorldProcess
    if ($null -eq $world) {
        if ($null -ne $state -and $state.PSObject.Properties.Name -contains 'Status' -and [string]$state.Status -eq 'Preparing') {
            $statePid = if ($state.PSObject.Properties.Name -contains 'WorldserverPid') { $state.WorldserverPid } else { $state.Pid }
            $stateWorld = [pscustomobject]@{ Pid = $statePid }
            Handle-PreparingState -State $state -World $stateWorld
        } else { Write-Log 'worldserver is absent; watcher will not start it.' 'WARN' }
        return 0
    }
    $uptime = Get-WorldUptime -World $world
    if ($uptime -lt [TimeSpan]::Zero) { Write-Log 'Computed negative uptime; aborting safely.' 'ERROR'; return 1 }
    if ($null -ne $state) {
        $stateStatus = if ($state.PSObject.Properties.Name -contains 'Status') { [string]$state.Status } else { '' }
        if ($stateStatus -notin @('Preparing','Armed','Blocked','Ambiguous','Consumed')) {
            Write-Log "Automatic maintenance BLOCKED: restart state has no recognized explicit status ('$stateStatus'). Administrator resolution is required; no automatic retry will occur." 'ERROR'
            return 0
        }
        try {
            $statePidProperty = if ($state.PSObject.Properties.Name -contains 'Pid') { 'Pid' } else { 'WorldserverPid' }
            if (-not ($state.PSObject.Properties.Name -contains $statePidProperty) -or -not ($state.PSObject.Properties.Name -contains 'StartTimeUtc')) { throw 'state lacks PID or StartTimeUtc' }
            $sameIdentity = ([int]$state.$statePidProperty -eq $world.Pid -and (ConvertTo-UtcDateTime $state.StartTimeUtc).Ticks -eq $world.StartTimeUtc.Ticks)
        } catch {
            Write-Log "Automatic maintenance BLOCKED: restart state identity is invalid ($($_.Exception.Message)). Administrator resolution is required; no automatic retry will occur." 'ERROR'
            return 0
        }
        if ($stateStatus -eq 'Preparing') {
            if (-not $sameIdentity) { Write-Log 'Preparing state belongs to a different worldserver identity; automatic maintenance remains blocked until an administrator resolves the state.' 'ERROR' }
            else { Handle-PreparingState -State $state -World $world }
            return 0
        }
        if (-not $sameIdentity) {
            Write-Log ("Restart state status '$stateStatus' belongs to old PID/start time; current PID={0}, StartTime={1}." -f $world.Pid,$world.StartTime.ToString('o')) 'INFO'
            Clear-State
            $state = $null
        } else {
            # Armed, Blocked, Ambiguous, and Consumed are all terminal for this
            # exact process. Never infer a new cycle from an existing ticket.
            return 0
        }
    }
    if ($uptime -lt $Threshold) { return 0 }
    Write-Log ("Restart threshold reached for PID={0}, StartTime={1}, uptime={2}." -f $world.Pid,$world.StartTime.ToString('o'),$uptime) 'INFO'

    $supervisor = Test-SupervisorForWorld -World $world
    if (-not $supervisor.Ok) { Write-Log "Restart skipped because a live supervisor was not positively verified: $($supervisor.Reason). No announcement or restart command was sent." 'ERROR'; return 0 }
    Write-Log 'Live supervisor positively verified for the exact worldserver PID and StartTimeUtc.' 'OK'
    $health = Invoke-SoapCommand -Command 'server info'
    if (-not $health.Ok) { Write-Log "Restart aborted due to SOAP preflight failure: $($health.Reason). worldserver was not touched." 'ERROR'; return 1 }
    Write-Log 'SOAP server info preflight succeeded after supervisor validation.' 'OK'
    $nowUtc = (Get-EffectiveNow).ToUniversalTime()
    $preState = [pscustomobject]@{
        Status = 'Preparing'
        Intent = $AutomaticIntent
        Pid = $world.Pid
        StartTimeUtc = $world.StartTimeUtc.ToString('o')
        PreparingStartedUtc = $nowUtc.ToString('o')
        ArmedAtUtc = $null
        ExpectedShutdownUtc = $nowUtc.AddSeconds($CountdownSeconds).ToString('o')
        ExpectedRestartUtc = $nowUtc.AddSeconds($CountdownSeconds).ToString('o')
        ShutdownCommand = $AutomaticShutdownCommand
        ShutdownCommandStatus = 'NotSubmitted'
    }
    Write-State $preState
    Write-Log $(if ($DryRun) { 'DryRun: wrote Preparing state before the announcement/command sequence.' } else { 'Wrote provisional Preparing state before the announcement/command sequence.' }) 'INFO'
    $announcement = Invoke-SoapCommand -Command 'announce Server maintenance restart in 5 minutes.'
    if (-not $announcement.Ok) { Write-Log "Restart blocked because the initial announcement failed: $($announcement.Reason). Preparing state was retained; administrator resolution is required." 'ERROR'; return 1 }
    Write-Log 'Initial maintenance announcement sent; AzerothCore will own the subsequent countdown.' 'OK'
    $supervisorAgain = Test-SupervisorForWorld -World $world
    if (-not $supervisorAgain.Ok) { Write-Log "Restart blocked because supervisor validation failed immediately before automatic shutdown: $($supervisorAgain.Reason). Preparing state was retained; no shutdown command was sent." 'ERROR'; return 0 }
    $armedAtUtc = (Get-EffectiveNow).ToUniversalTime()
    $armedState = [pscustomobject]@{
        Status = 'Armed'
        Intent = $AutomaticIntent
        Pid = $world.Pid
        StartTimeUtc = $world.StartTimeUtc.ToString('o')
        PreparingStartedUtc = $nowUtc.ToString('o')
        ArmedAtUtc = $armedAtUtc.ToString('o')
        ExpectedShutdownUtc = $armedAtUtc.AddSeconds($CountdownSeconds).ToString('o')
        ExpectedRestartUtc = $armedAtUtc.AddSeconds($CountdownSeconds).ToString('o')
        ShutdownCommand = $AutomaticShutdownCommand
        ShutdownCommandStatus = 'Pending'
    }
    Write-State $armedState
    Write-Log $(if ($DryRun) { "DryRun: persisted Armed automatic shutdown ticket for PID=$($world.Pid) StartTimeUtc=$($world.StartTimeUtc.ToString('o')); command status is Pending." } else { "Automatic shutdown ticket Armed for PID=$($world.Pid) StartTimeUtc=$($world.StartTimeUtc.ToString('o')); command status is Pending." }) 'OK'
    $shutdown = Invoke-SoapCommand -Command $AutomaticShutdownCommand
    if (-not $shutdown.Ok) {
        $failureStatus = if ([string]$shutdown.Outcome -eq 'DefinitiveFailure') { 'Blocked' } else { 'Ambiguous' }
        $blockedState = [pscustomobject]@{
            Status = $failureStatus
            Intent = $AutomaticIntent
            Pid = $armedState.Pid
            StartTimeUtc = $armedState.StartTimeUtc
            PreparingStartedUtc = $armedState.PreparingStartedUtc
            ArmedAtUtc = $armedState.ArmedAtUtc
            ExpectedShutdownUtc = $armedState.ExpectedShutdownUtc
            ExpectedRestartUtc = $armedState.ExpectedRestartUtc
            ShutdownCommand = $armedState.ShutdownCommand
            ShutdownCommandStatus = $failureStatus
            FailureReason = [string]$shutdown.Reason
            BlockedAtUtc = (Get-EffectiveNow).ToUniversalTime().ToString('o')
        }
        Write-State $blockedState
        Write-Log "Automatic shutdown command was not accepted ($($shutdown.Reason)); ticket transitioned to $failureStatus. Automatic retry and relaunch permission are blocked." 'ERROR'
        return 1
    }
    $acceptedState = [pscustomobject]@{
        Status = 'Armed'
        Intent = $AutomaticIntent
        Pid = $armedState.Pid
        StartTimeUtc = $armedState.StartTimeUtc
        PreparingStartedUtc = $armedState.PreparingStartedUtc
        ArmedAtUtc = $armedState.ArmedAtUtc
        ExpectedShutdownUtc = $armedState.ExpectedShutdownUtc
        ExpectedRestartUtc = $armedState.ExpectedRestartUtc
        ShutdownCommand = $armedState.ShutdownCommand
        ShutdownCommandStatus = 'Accepted'
        CommandAcceptedUtc = (Get-EffectiveNow).ToUniversalTime().ToString('o')
    }
    Write-State $acceptedState
    Write-Log $(if ($DryRun) { "DryRun: would send '$AutomaticShutdownCommand'; accepted ticket persisted for PID=$($world.Pid)." } else { "Automatic shutdown accepted for PID=$($world.Pid); expected shutdown at $($acceptedState.ExpectedShutdownUtc) UTC. Native AzerothCore countdown is authoritative." }) 'OK'
    return 0
}

$mutex = New-Object System.Threading.Mutex($false, $WatcherMutexName)
$haveLock = $false
try {
    try { $haveLock = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $haveLock = $true; Write-Log 'Recovered an abandoned watcher mutex.' 'WARN' }
    if (-not $haveLock) { Write-Log 'Duplicate watcher invocation ignored by application mutex.' 'WARN'; exit 0 }
if ($HoldLockSeconds -gt 0) { if (-not $DryRun) { throw '-HoldLockSeconds requires -DryRun.' }; Start-Sleep -Seconds $HoldLockSeconds }
    if ($Preflight) { exit (Assert-Preflight) }
    if ($TestAnnouncement) { exit (Invoke-TestAnnouncement) }
    exit (Invoke-Watch)
} catch {
    Write-Log "Unhandled watcher error; no destructive fallback exists: $($_.Exception.Message)" 'ERROR'
    exit 1
} finally {
    if ($haveLock) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
