[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$watcher = Join-Path $root 'Restart-Watcher.ps1'
$supervisor = Join-Path $root 'Worldserver-Supervisor.ps1'
$watcherRegistration = Join-Path $root 'Register-RestartWatcher.ps1'
$supervisorRegistration = Join-Path $root 'Register-Supervisor.ps1'
$state = Join-Path $root 'state\restart-state.json'
$testState = Join-Path $root 'state\restart-state-automation-test.json'
$supervisorTestState = Join-Path $root 'state\supervisor-restart-ticket-test.json'
$invalidStateWarning = '{0}.invalid-warning.json' -f $testState
$log = Join-Path $root 'logs\test-results.log'
$watcherLog = Join-Path $root ('logs\worldserver-restart-{0}.log' -f (Get-Date -Format 'yyyy-MM'))

function Assert-True { param([bool]$Condition,[string]$Name)
    if ($Condition) { Add-Content -LiteralPath $log -Value "PASS $Name"; Write-Host "PASS $Name" -ForegroundColor Green }
    else { Add-Content -LiteralPath $log -Value "FAIL $Name"; Write-Host "FAIL $Name" -ForegroundColor Red; $script:failures++ }
}
function Invoke-WatcherTest { param([string[]]$Arguments)
    $isDryRun = @($Arguments) -contains '-DryRun'
    $hasWorldState = @($Arguments) -contains '-TestWorldState'
    if ($isDryRun) {
        $worldArguments = if ($hasWorldState) { @() } else { @('-TestWorldState','Simulated') }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watcher @Arguments -TestStateFile $testState @worldArguments | Out-Null
    }
    else { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watcher @Arguments | Out-Null }
    return $LASTEXITCODE
}
function Invoke-SupervisorTest { param([int]$Code,[string]$Ticket)
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $supervisor -DryRun -SimulatedExitCode $Code -TestRestartTicket $Ticket -TestStateFile $supervisorTestState 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = [int]$LASTEXITCODE; Output = $output }
}
function Get-CommandParameterText { param([string]$Path)
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors) | Out-Null
    return @($tokens | Where-Object Kind -eq 'CommandParameter' | ForEach-Object Content)
}

$script:failures = 0
if (-not (Test-Path -LiteralPath (Split-Path -Parent $log))) { New-Item -ItemType Directory -Path (Split-Path -Parent $log) -Force | Out-Null }
Set-Content -LiteralPath $log -Value ('Test run ' + (Get-Date -Format o))

# Static safety assertions cover every control/registration script. The
# StartWhenAvailable check is parsed as command parameters, so comments and
# diagnostic property names do not create a false result.
$source = ($watcher,$supervisor,$watcherRegistration,$supervisorRegistration | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"
Assert-True ($source -notmatch 'Stop-Process\s+-Force|taskkill\s+/F|CTRL_BREAK|server restart cancel') 'no destructive fallback or shutdown/cancel command in staged scripts'
Assert-True (@($watcherRegistration,$supervisorRegistration | ForEach-Object { Get-CommandParameterText $_ } | Where-Object { $_ -match '(?i)StartWhenAvailable' }).Count -eq 0) 'registration scripts do not set StartWhenAvailable'
Assert-True ($source -match 'New-ScheduledTaskSettingsSet' -and $source -match 'MultipleInstances IgnoreNew') 'registration scripts explicitly request IgnoreNew settings'
Assert-True ($source -match "server shutdown 300" -and $source -notmatch "server restart 300") 'automatic path uses only graceful server shutdown 300'
Assert-True ($source -match 'StartTimeUtc' -and $source -match 'Pid') 'state identity includes PID and StartTimeUtc'
Assert-True ($source -match 'supervisor-state.json' -and $source -match 'LastHeartbeatUtc' -and $source -match 'Supervising') 'heartbeat state and active-supervision status are implemented'
Assert-True ($source -match 'ShutdownCommandStatus' -and $source -match 'Accepted' -and $source -match 'Consumed') 'automatic ticket requires accepted state and has one-shot consumption'
Assert-True ($source -notmatch 'OneMinuteAnnouncementAttempted|server restart in 1 minute') 'duplicate custom one-minute countdown is removed'

# Uptime decision cases; all are explicit DryRun and can never send SOAP.
foreach ($case in @(@('uptime 1 hour','01:00:00'),@('uptime 5h54m','05:54:00'),@('uptime 5h55m','05:55:00'),@('uptime 6h01m','06:01:00'))) {
    Remove-Item -LiteralPath $testState -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $invalidStateWarning -Force -ErrorAction SilentlyContinue
    Assert-True ((Invoke-WatcherTest @('-DryRun','-SimulatedUptime',$case[1])) -eq 0) $case[0]
}
Remove-Item -LiteralPath $testState -Force -ErrorAction SilentlyContinue
Assert-True ((Invoke-WatcherTest @('-DryRun','-TestWorldState','Absent')) -eq 0) 'worldserver absent'

# Supervisor precondition cases. Every case is DryRun; no SOAP control command
# can be sent. The valid case reaches the mocked native restart sequence.
foreach ($case in @('Missing','StaleHeartbeat','DeadSupervisor','PidMismatch','StartTimeMismatch','Valid','DisappearBeforeRestart')) {
    Remove-Item -LiteralPath $testState -Force -ErrorAction SilentlyContinue
    Assert-True ((Invoke-WatcherTest -Arguments @('-DryRun','-SimulatedUptime','06:01:00','-TestSupervisorState',$case,'-TestSoapResult','Success')) -eq 0) ("supervisor state $case")
}

# A fixed simulated identity exercises PID/start-time matching without depending
# on the live production process or writing production restart state.
$simulatedPid = 4201
$simulatedStartUtc = [datetime]::Parse('2026-01-01T00:00:00.0000000Z',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    $identity = [pscustomobject]@{Status='Armed';Intent='AutomaticSixHourRestart';Pid=$simulatedPid;StartTimeUtc=$simulatedStartUtc.ToString('o');PreparingStartedUtc=(Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o');ArmedAtUtc=(Get-Date).ToUniversalTime().ToString('o');ExpectedShutdownUtc=(Get-Date).ToUniversalTime().AddMinutes(1).ToString('o');ExpectedRestartUtc=(Get-Date).ToUniversalTime().AddMinutes(1).ToString('o');ShutdownCommand='server shutdown 300';ShutdownCommandStatus='Accepted'}
    $identity | ConvertTo-Json | Set-Content -LiteralPath $testState -Encoding UTF8
    Assert-True ((Invoke-WatcherTest @('-DryRun','-SimulatedUptime','01:00:00')) -eq 0) 'state belongs to current PID/start time and restart is armed'
    $old = [pscustomobject]@{Status='Armed';Intent='AutomaticSixHourRestart';Pid=1;StartTimeUtc=(Get-Date).ToUniversalTime().AddDays(-1).ToString('o');PreparingStartedUtc=(Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o');ArmedAtUtc=(Get-Date).ToUniversalTime().ToString('o');ExpectedShutdownUtc=(Get-Date).ToUniversalTime().AddMinutes(1).ToString('o');ExpectedRestartUtc=(Get-Date).ToUniversalTime().AddMinutes(1).ToString('o');ShutdownCommand='server shutdown 300';ShutdownCommandStatus='Accepted'}
    $old | ConvertTo-Json | Set-Content -LiteralPath $testState -Encoding UTF8
    Assert-True ((Invoke-WatcherTest @('-DryRun','-SimulatedUptime','01:00:00')) -eq 0 -and -not (Test-Path -LiteralPath $testState)) 'stale state belongs to old PID and is cleared'
    $preparing = [pscustomobject]@{Status='Preparing';Pid=$simulatedPid;StartTimeUtc=$simulatedStartUtc.ToString('o');PreparingStartedUtc=(Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o');ArmedAtUtc=(Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o');ExpectedRestartUtc=(Get-Date).ToUniversalTime().AddMinutes(-25).ToString('o')}
    $preparing | ConvertTo-Json | Set-Content -LiteralPath $testState -Encoding UTF8
    Assert-True ((Invoke-WatcherTest @('-DryRun','-SimulatedUptime','01:00:00')) -eq 0 -and (Test-Path -LiteralPath $testState) -and ([string]((Get-Content -LiteralPath $testState -Raw | ConvertFrom-Json).Status) -eq 'Preparing')) 'old Preparing state remains blocked and is not auto-cleared'
Remove-Item -LiteralPath $invalidStateWarning -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $testState -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath $testState -Value '{not-json' -Encoding UTF8
$beforeMalformed = @(Get-Content -LiteralPath $watcherLog -ErrorAction SilentlyContinue)
$firstMalformedExit = Invoke-WatcherTest @('-DryRun','-SimulatedUptime','06:01:00','-TestSupervisorState','Valid','-TestSoapResult','Success')
$afterFirstMalformed = @(Get-Content -LiteralPath $watcherLog)
$firstMalformedDelta = @($afterFirstMalformed | Select-Object -Skip $beforeMalformed.Count) -join "`n"
Assert-True ($firstMalformedExit -eq 0) 'malformed state watcher exits safely'
Assert-True (Test-Path -LiteralPath $testState) 'malformed restart state remains on disk'
Assert-True (Test-Path -LiteralPath $invalidStateWarning) 'malformed-state warning marker is written separately'
Assert-True ($firstMalformedDelta -match 'BLOCKED') 'malformed state logs automatic maintenance blocked'
Assert-True ($firstMalformedDelta -notmatch 'SOAP server info|would send .*announce|server restart 300') 'malformed state does not reach SOAP/announcement/restart'
$beforeSecondMalformed = @(Get-Content -LiteralPath $watcherLog)
$secondMalformedExit = Invoke-WatcherTest @('-DryRun','-SimulatedUptime','06:01:00','-TestSupervisorState','Valid','-TestSoapResult','Success')
$afterSecondMalformed = @(Get-Content -LiteralPath $watcherLog)
$secondMalformedDelta = @($afterSecondMalformed | Select-Object -Skip $beforeSecondMalformed.Count) -join "`n"
Assert-True ($secondMalformedExit -eq 0 -and (Test-Path -LiteralPath $testState) -and $secondMalformedDelta -notmatch 'BLOCKED|SOAP server info|would send .*announce|server restart 300') 'repeated malformed state remains blocked with rate-limited warning'

# The automatic ticket is tested in an isolated DryRun state file. This proves
# ordering and exact identity without allowing the production watcher task to
# observe test state or sending any control SOAP command.
Remove-Item -LiteralPath $testState -Force -ErrorAction SilentlyContinue
$beforeAutomatic = @(Get-Content -LiteralPath $watcherLog -ErrorAction SilentlyContinue)
$automaticExit = Invoke-WatcherTest @('-DryRun','-SimulatedUptime','06:01:00','-TestSupervisorState','Valid','-TestSoapResult','Success')
$automaticState = Get-Content -LiteralPath $testState -Raw | ConvertFrom-Json
$afterAutomatic = @(Get-Content -LiteralPath $watcherLog)
$automaticDelta = @($afterAutomatic | Select-Object -Skip $beforeAutomatic.Count) -join "`n"
$preparingIndex = $automaticDelta.IndexOf('Preparing state')
$announcementIndex = $automaticDelta.IndexOf('Initial maintenance announcement sent')
$armedIndex = $automaticDelta.IndexOf('Armed automatic shutdown ticket')
$acceptedIndex = $automaticDelta.IndexOf('accepted ticket persisted')
Assert-True ($automaticExit -eq 0 -and [string]$automaticState.Status -eq 'Armed' -and [string]$automaticState.ShutdownCommand -eq 'server shutdown 300' -and [string]$automaticState.ShutdownCommandStatus -eq 'Accepted') 'automatic ticket is Armed only after accepted shutdown command'
Assert-True ($automaticState.Pid -eq $simulatedPid -and ([datetime]$automaticState.StartTimeUtc).ToUniversalTime().Ticks -eq $simulatedStartUtc.Ticks) 'Armed ticket contains exact simulated PID and StartTimeUtc'
Assert-True ($preparingIndex -ge 0 -and $announcementIndex -gt $preparingIndex -and $armedIndex -gt $announcementIndex -and $acceptedIndex -gt $armedIndex) 'Preparing, announcement, Armed, and accepted-command ordering is preserved'

Remove-Item -LiteralPath $testState -Force -ErrorAction SilentlyContinue
Assert-True ((Invoke-WatcherTest @('-DryRun','-SimulatedUptime','06:01:00','-TestSupervisorState','Valid','-TestSoapResult','SuccessThenDefinitiveFailure')) -ne 0 -and [string]((Get-Content -LiteralPath $testState -Raw | ConvertFrom-Json).Status) -eq 'Blocked') 'definitive SOAP failure leaves no reusable Armed ticket'
Remove-Item -LiteralPath $testState -Force -ErrorAction SilentlyContinue
Assert-True ((Invoke-WatcherTest @('-DryRun','-SimulatedUptime','06:01:00','-TestSupervisorState','Valid','-TestSoapResult','SuccessThenAmbiguous')) -ne 0 -and [string]((Get-Content -LiteralPath $testState -Raw | ConvertFrom-Json).Status) -eq 'Ambiguous') 'ambiguous SOAP result blocks automatic retry and relaunch permission'

# The provisioned DPAPI credential is tested only through the read-only server info
# preflight. A separate raw request with blank credentials proves the live endpoint
# still returns 401; no control command is sent by this harness.
 $liveWorldPresent = @(Get-CimInstance Win32_Process -Filter "Name='worldserver.exe'" | Where-Object { $_.ExecutablePath -and ([IO.Path]::GetFullPath($_.ExecutablePath).TrimEnd('\').ToLowerInvariant() -eq 'c:\azeroth\build\bin\relwithdebinfo\worldserver.exe') }).Count -eq 1
if ($liveWorldPresent) {
    Assert-True ((Invoke-WatcherTest -Arguments @('-Preflight')) -eq 0) 'live SOAP server info preflight succeeds safely'
} else {
    Write-Host 'SKIP live SOAP preflight: exact worldserver.exe is currently absent; using simulated non-destructive preflight.' -ForegroundColor Yellow
    Assert-True ((Invoke-WatcherTest -Arguments @('-Preflight','-DryRun','-TestWorldState','Simulated','-TestSoapResult','Success')) -eq 0) 'simulated SOAP server info preflight succeeds safely'
}
Assert-True ((Invoke-WatcherTest -Arguments @('-Preflight','-DryRun','-TestSoapResult','PortUnavailable')) -ne 0) 'SOAP port unavailable aborts safely'
Assert-True ((Invoke-WatcherTest -Arguments @('-Preflight','-DryRun','-TestSoapResult','AuthFailure')) -ne 0) 'SOAP HTTP authentication failure aborts safely'
Assert-True ((Invoke-WatcherTest -Arguments @('-Preflight','-DryRun','-TestSoapResult','Success')) -eq 0) 'server info succeeds through the mockable SOAP path'
$body='<?xml version="1.0"?><SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="urn:AC"><SOAP-ENV:Body><ns1:executeCommand><command>server info</command></ns1:executeCommand></SOAP-ENV:Body></SOAP-ENV:Envelope>'
$authFailed = $false
try { Invoke-WebRequest -Uri 'http://127.0.0.1:7878/' -Method Post -Headers @{Authorization=('Basic '+[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':')))} -Body $body -TimeoutSec 5 -UseBasicParsing | Out-Null }
catch { $authFailed = ($_.Exception.Message -match '401') }
Assert-True $authFailed 'SOAP endpoint rejects blank credentials with HTTP 401'

# Duplicate watcher invocation: first DryRun process holds the application mutex.
$first = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$watcher,'-DryRun','-HoldLockSeconds','3') -PassThru
Start-Sleep -Milliseconds 500
$secondExit = Invoke-WatcherTest @('-DryRun','-SimulatedUptime','01:00:00')
$first.WaitForExit()
Assert-True ($secondExit -eq 0) 'duplicate watcher invocation is ignored'

function Invoke-SupervisorScenario {
    param([int]$Code,[string]$Ticket)
    Remove-Item -LiteralPath $supervisorTestState -Force -ErrorAction SilentlyContinue
    return Invoke-SupervisorTest -Code $Code -Ticket $Ticket
}

foreach ($code in @(2,0,1)) {
    $result = Invoke-SupervisorScenario -Code $code -Ticket 'Missing'
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match 'no automatic relaunch permitted') ("supervisor exit code $code without ticket does not relaunch")
}
foreach ($code in @(2,0)) {
    $result = Invoke-SupervisorScenario -Code $code -Ticket 'ValidArmed'
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match 'exactly one replacement launch would be permitted') ("supervisor exit code $code with exact Armed ticket permits one relaunch")
}
$blankResult = Invoke-SupervisorScenario -Code -1 -Ticket 'ValidArmed'
Assert-True ($blankResult.ExitCode -eq 0 -and $blankResult.Output -match 'EXIT_CODE_UNAVAILABLE' -and $blankResult.Output -match 'exactly one replacement launch would be permitted') 'unavailable exit code with exact Armed ticket permits one relaunch'
foreach ($ticket in @('WrongPid','WrongStartTime','Preparing','Malformed','Blocked','Ambiguous','Consumed','Pending')) {
    $result = Invoke-SupervisorScenario -Code 2 -Ticket $ticket
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match 'no automatic relaunch permitted') "supervisor ticket $ticket does not relaunch"
}
$duplicateResult = Invoke-SupervisorScenario -Code 2 -Ticket 'MatchingProcess'
Assert-True ($duplicateResult.ExitCode -eq 0 -and $duplicateResult.Output -match 'no duplicate launch attempted' -and [string]((Get-Content -LiteralPath $supervisorTestState -Raw | ConvertFrom-Json).Status) -eq 'Consumed') 'matching worldserver prevents duplicate launch and ticket is consumed'
$oncePath = $supervisorTestState
Remove-Item -LiteralPath $oncePath -Force -ErrorAction SilentlyContinue
$firstTicket = Invoke-SupervisorTest -Code 2 -Ticket 'ValidArmed'
$secondTicket = Invoke-SupervisorTest -Code 2 -Ticket 'ValidArmed'
Assert-True ($firstTicket.Output -match 'exactly one replacement launch would be permitted' -and $secondTicket.Output -match 'no automatic relaunch permitted' -and [string]((Get-Content -LiteralPath $oncePath -Raw | ConvertFrom-Json).Status) -eq 'Consumed') 'same automatic ticket cannot be consumed twice'
Remove-Item -LiteralPath $testState -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $invalidStateWarning -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $supervisorTestState -Force -ErrorAction SilentlyContinue
Write-Host "`nFailures: $script:failures"
exit ([int]($script:failures -gt 0))
