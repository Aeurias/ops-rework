[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$watcher = Join-Path $root 'Restart-Watcher.ps1'
$supervisor = Join-Path $root 'Worldserver-Supervisor.ps1'
$watcherRegistration = Join-Path $root 'Register-RestartWatcher.ps1'
$supervisorRegistration = Join-Path $root 'Register-Supervisor.ps1'
$testRoot = Join-Path $root 'test-artifacts\restart-automation'
$state = Join-Path $root 'state\restart-state.json'
$supervisorState = Join-Path $root 'state\supervisor-state.json'
$productionLog = Join-Path $root ('logs\worldserver-restart-{0}.log' -f (Get-Date -Format 'yyyy-MM'))
$testState = Join-Path $testRoot 'state\restart-state.json'
$supervisorTestState = Join-Path $testRoot 'state\restart-state.json'
$invalidStateWarning = Join-Path $testRoot 'state\restart-state-invalid-warning.json'
$log = Join-Path $testRoot 'logs\test-results.log'
$watcherLog = Join-Path $testRoot 'logs\restart-watcher-test.log'

function Assert-True { param([bool]$Condition,[string]$Name)
    if ($Condition) { Add-Content -LiteralPath $log -Value "PASS $Name"; Write-Host "PASS $Name" -ForegroundColor Green }
    else { Add-Content -LiteralPath $log -Value "FAIL $Name"; Write-Host "FAIL $Name" -ForegroundColor Red; $script:failures++ }
}
function Invoke-WatcherTest { param([string[]]$Arguments)
    $isDryRun = @($Arguments) -contains '-DryRun'
    $hasWorldState = @($Arguments) -contains '-TestWorldState'
    if ($isDryRun) {
        $worldArguments = if ($hasWorldState) { @() } else { @('-TestWorldState','Simulated') }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watcher @Arguments -TestRoot $testRoot @worldArguments | Out-Null
    }
    else { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watcher @Arguments | Out-Null }
    return $LASTEXITCODE
}
function Invoke-SupervisorTest { param([int]$Code,[string]$Ticket)
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $supervisor -DryRun -SimulatedExitCode $Code -TestRestartTicket $Ticket -TestRoot $testRoot 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = [int]$LASTEXITCODE; Output = $output }
}
function Get-CommandParameterText { param([string]$Path)
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors) | Out-Null
    return @($tokens | Where-Object Kind -eq 'CommandParameter' | ForEach-Object Content)
}

$script:failures = 0
if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop }
New-Item -ItemType Directory -Path (Split-Path -Parent $log) -Force | Out-Null
$productionArtifactsBefore = @($state,$productionLog | ForEach-Object { if (Test-Path -LiteralPath $_) { [pscustomobject]@{ Path=$_; Hash=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash } } else { [pscustomobject]@{ Path=$_; Hash=$null } } })
$productionSupervisorBefore = if (Test-Path -LiteralPath $supervisorState) { Get-Content -LiteralPath $supervisorState -Raw | ConvertFrom-Json } else { $null }
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
Assert-True ($source -notmatch '(?im)^\s*(?:\[[^\r\n]+\]\s*)?\$(?:pid|host|home|error|args|input|psitem|psscriptroot|myinvocation|executioncontext|nestedpromptlevel|psversiontable|pwd|shellid|stacktrace|this|profile|null)\s*(?:=|,|\))') 'no automatic-variable name is declared as a parameter or local assignment'
$atTimeOutput = ''
$atTimeExit = 0
try { $atTimeOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watcher -AtTime '2026-01-01T00:00:00Z' 2>&1 | Out-String; $atTimeExit = $LASTEXITCODE }
catch { $atTimeOutput = [string]$_; $atTimeExit = 1 }
Assert-True ($atTimeExit -ne 0 -and $atTimeOutput -match '-AtTime may only be used with -DryRun') '-AtTime is rejected outside DryRun'

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
$expired = [pscustomobject]@{Status='Armed';Intent='AutomaticSixHourRestart';Pid=$simulatedPid;StartTimeUtc=$simulatedStartUtc.ToString('o');PreparingStartedUtc=(Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o');ArmedAtUtc=(Get-Date).ToUniversalTime().AddMinutes(-29).ToString('o');ExpectedShutdownUtc=(Get-Date).ToUniversalTime().AddMinutes(-25).ToString('o');ShutdownCommand='server shutdown 300';ShutdownCommandStatus='Accepted';CommandAcceptedUtc=(Get-Date).ToUniversalTime().AddMinutes(-29).ToString('o')}
    $expired | ConvertTo-Json | Set-Content -LiteralPath $testState -Encoding UTF8
    $beforeExpired = @(Get-Content -LiteralPath $watcherLog -ErrorAction SilentlyContinue)
    $firstExpiredExit = Invoke-WatcherTest @('-DryRun','-SimulatedUptime','01:00:00')
    $afterFirstExpired = @(Get-Content -LiteralPath $watcherLog)
    $firstExpiredDelta = @($afterFirstExpired | Select-Object -Skip $beforeExpired.Count) -join "`n"
    $beforeSecondExpired = @(Get-Content -LiteralPath $watcherLog)
    $secondExpiredExit = Invoke-WatcherTest @('-DryRun','-SimulatedUptime','01:00:00')
    $afterSecondExpired = @(Get-Content -LiteralPath $watcherLog)
    $secondExpiredDelta = @($afterSecondExpired | Select-Object -Skip $beforeSecondExpired.Count) -join "`n"
    Assert-True ($firstExpiredExit -eq 0 -and $firstExpiredDelta -match 'Accepted restart ticket is overdue' -and (Test-Path -LiteralPath $testState)) 'expired Accepted ticket is visibly blocked without cleanup'
    Assert-True ($secondExpiredExit -eq 0 -and $secondExpiredDelta -notmatch 'Accepted restart ticket is overdue') 'expired Accepted ticket warning is throttled'
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

# The automated suite remains fully isolated; live SOAP preflight belongs to the
# explicit commissioning phase and is never triggered as a test side effect.
Assert-True ((Invoke-WatcherTest -Arguments @('-Preflight','-DryRun','-TestWorldState','Simulated','-TestSoapResult','Success')) -eq 0) 'simulated SOAP server info preflight succeeds safely'
Assert-True ((Invoke-WatcherTest -Arguments @('-Preflight','-DryRun','-TestSoapResult','PortUnavailable')) -ne 0) 'SOAP port unavailable aborts safely'
Assert-True ((Invoke-WatcherTest -Arguments @('-Preflight','-DryRun','-TestSoapResult','AuthFailure')) -ne 0) 'SOAP HTTP authentication failure aborts safely'
Assert-True ((Invoke-WatcherTest -Arguments @('-Preflight','-DryRun','-TestSoapResult','Success')) -eq 0) 'server info succeeds through the mockable SOAP path'

# Duplicate watcher invocation: first DryRun process holds the application mutex.
$first = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$watcher,'-DryRun','-TestRoot',$testRoot,'-TestWorldState','Simulated','-HoldLockSeconds','3') -PassThru
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
foreach ($ticket in @('Empty','JsonNull','EmptyObject','MissingStatus','MissingPid','MissingStartTime','WrongTypes','UnknownStatus','Expired')) {
    $result = Invoke-SupervisorScenario -Code 0 -Ticket $ticket
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match 'no automatic relaunch permitted') "supervisor null, malformed, or expired ticket $ticket does not relaunch"
}
foreach ($ticket in @('BeforeExpected','InsideGrace')) {
    $result = Invoke-SupervisorScenario -Code 0 -Ticket $ticket
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match 'exactly one replacement launch would be permitted') "supervisor ticket $ticket remains within bounded automatic restart window"
}
$fullLifecycle = Invoke-SupervisorScenario -Code 0 -Ticket 'FullLifecycle'
Assert-True ($fullLifecycle.ExitCode -eq 0 -and $fullLifecycle.Output -match 'full lifecycle completed' -and -not (Test-Path -LiteralPath $supervisorTestState)) 'supervisor full replacement lifecycle finalizes ticket and keeps supervision active'
foreach ($ticket in @('CrashAfterConsumed','CrashAfterLaunchStarted','CrashAfterProcessStart','CrashAfterReadiness','ReadinessTimeout','ReplacementDies')) {
    $result = Invoke-SupervisorScenario -Code 0 -Ticket $ticket
    $preserved = if (Test-Path -LiteralPath $supervisorTestState) { [string]((Get-Content -LiteralPath $supervisorTestState -Raw | ConvertFrom-Json).Status) -eq 'Consumed' } else { $false }
    Assert-True ($result.ExitCode -eq 0 -and $preserved) "supervisor crash/recovery phase $ticket preserves one-shot consumed state"
}
$duplicateResult = Invoke-SupervisorScenario -Code 2 -Ticket 'MatchingProcess'
Assert-True ($duplicateResult.ExitCode -eq 0 -and $duplicateResult.Output -match 'no duplicate launch attempted' -and [string]((Get-Content -LiteralPath $supervisorTestState -Raw | ConvertFrom-Json).Status) -eq 'Consumed') 'matching worldserver prevents duplicate launch and ticket is consumed'
$adoptedReadiness = Invoke-SupervisorScenario -Code 0 -Ticket 'AdoptedReadiness'
Assert-True ($adoptedReadiness.ExitCode -eq 0 -and $adoptedReadiness.Output -match 'passed readiness before heartbeat and ticket cleanup' -and -not (Test-Path -LiteralPath $supervisorTestState)) 'adopted replacement passes readiness before heartbeat and ticket cleanup'
$oncePath = $supervisorTestState
Remove-Item -LiteralPath $oncePath -Force -ErrorAction SilentlyContinue
$firstTicket = Invoke-SupervisorTest -Code 2 -Ticket 'ValidArmed'
$secondTicket = Invoke-SupervisorTest -Code 2 -Ticket 'ValidArmed'
Assert-True ($firstTicket.Output -match 'exactly one replacement launch would be permitted' -and $secondTicket.Output -match 'no automatic relaunch permitted' -and [string]((Get-Content -LiteralPath $oncePath -Raw | ConvertFrom-Json).Status) -eq 'Consumed') 'same automatic ticket cannot be consumed twice'
$productionArtifactsAfter = @($state,$productionLog | ForEach-Object { if (Test-Path -LiteralPath $_) { [pscustomobject]@{ Path=$_; Hash=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash } } else { [pscustomobject]@{ Path=$_; Hash=$null } } })
$productionSupervisorAfter = if (Test-Path -LiteralPath $supervisorState) { Get-Content -LiteralPath $supervisorState -Raw | ConvertFrom-Json } else { $null }
$productionSupervisorIdentityUnchanged = if ($null -eq $productionSupervisorBefore -or $null -eq $productionSupervisorAfter) {
    $null -eq $productionSupervisorBefore -and $null -eq $productionSupervisorAfter
} else {
    [string]$productionSupervisorBefore.SupervisorPid -eq [string]$productionSupervisorAfter.SupervisorPid -and
    [string]$productionSupervisorBefore.WorldserverPid -eq [string]$productionSupervisorAfter.WorldserverPid -and
    [string]$productionSupervisorBefore.WorldserverStartTimeUtc -eq [string]$productionSupervisorAfter.WorldserverStartTimeUtc -and
    [string]$productionSupervisorBefore.Status -eq [string]$productionSupervisorAfter.Status
}
Assert-True (@(Compare-Object -ReferenceObject $productionArtifactsBefore -DifferenceObject $productionArtifactsAfter -Property Path,Hash).Count -eq 0 -and $productionSupervisorIdentityUnchanged) 'automation tests leave production state and production log unchanged'
Remove-Item -LiteralPath $testState -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $invalidStateWarning -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $supervisorTestState -Force -ErrorAction SilentlyContinue
Write-Host "`nFailures: $script:failures"
exit ([int]($script:failures -gt 0))
