[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$stop = Join-Path $root 'Stop-AzerothCoreMaintenance.ps1'
$start = Join-Path $root 'Start-AzerothCore.ps1'
$status = Join-Path $root 'Status-AzerothCore.ps1'
$archiveScript = Join-Path $root 'New-OpsReworkArchive.ps1'
$registerSupervisor = Join-Path $root 'Register-Supervisor.ps1'
$testRoot = Join-Path $root 'test-artifacts\operator-maintenance'
$operatorLog = Join-Path $testRoot 'operator-maintenance-test.log'
$marker = Join-Path $root 'state\maintenance-active.json'
$failures = 0

function Assert-True {
    param([bool] $Condition, [string] $Name)
    if ($Condition) { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name" -ForegroundColor Red; $script:failures++ }
}

function Invoke-OperatorScript {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string[]] $Arguments)
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = [int]$LASTEXITCODE; Output = $output }
}

function Invoke-LoggedDryRun {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Scenario)
    return Invoke-OperatorScript -Path $Path -Arguments @('-DryRun','-TestScenario',$Scenario,'-LogPath',$operatorLog)
}

if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop }
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
Set-Content -LiteralPath $operatorLog -Value ('Operator test run ' + (Get-Date -Format o)) -Encoding UTF8

$stopSource = Get-Content -LiteralPath $stop -Raw
$startSource = Get-Content -LiteralPath $start -Raw
$statusSource = Get-Content -LiteralPath $status -Raw
$archiveSource = Get-Content -LiteralPath $archiveScript -Raw
$registerSource = Get-Content -LiteralPath $registerSupervisor -Raw
$watcherRegisterSource = Get-Content -LiteralPath (Join-Path $root 'Register-RestartWatcher.ps1') -Raw

Assert-True ($stopSource -match '(?m)^\s*\$command\s*=\s*''server shutdown 1''\s*$') 'STOP contains exactly the required shutdown command'
Assert-True ($stopSource -notmatch 'server shutdown 0|server restart\s+\d') 'STOP contains no restart or zero-second shutdown command'
Assert-True ($stopSource -notmatch 'Stop-Process|taskkill|CTRL_BREAK|TerminateProcess|\.Kill\(') 'STOP has no forceful termination mechanism'
Assert-True ($startSource -notmatch 'Start-Process\s+-FilePath\s+\$WorldExe|Start-Process.*worldserver\.exe') 'START does not directly launch worldserver'
Assert-True ($startSource -match 'Restart-Watcher\.ps1' -and $startSource -match '-Preflight') 'START invokes the existing preflight'
Assert-True ($statusSource -notmatch 'Enable-ScheduledTask|Disable-ScheduledTask|Start-ScheduledTask|Stop-ScheduledTask|Remove-Item|Set-Content|Move-Item|Invoke-WebRequest|Start-Process') 'STATUS source has no mutating cmdlets or SOAP request'
Assert-True ($statusSource -match 'Get-Process -Name ''worldserver''' -and $statusSource -match 'PathVerification' -and $statusSource -notmatch 'Get-ExactWorldserverProcesses') 'STATUS separates worldserver existence from path verification'
Assert-True (($registerSource -match '-WindowStyle Hidden') -and ($registerSource -notmatch '-WindowStyle Normal')) 'Register-Supervisor retains hidden PowerShell window'
Assert-True (($registerSource -match 'InspectionTaskName' -and $watcherRegisterSource -match 'InspectionTaskName') -and ($registerSource -match 'ReplaceExisting' -and $watcherRegisterSource -match 'ReplaceExisting')) 'registration uses distinct inspection names and requires explicit production replacement'
Assert-True (($registerSource -notmatch 'Unregister-ScheduledTask.*Register-ScheduledTask') -and ($watcherRegisterSource -notmatch 'Unregister-ScheduledTask.*Register-ScheduledTask')) 'registration never unregisters a production task before replacement'
Assert-True (($archiveSource -match 'restart bot account') -and ($archiveSource -match 'soap-credential') -and ($archiveSource -match 'state\\.*\\.json') -and ($archiveSource -match 'logs')) 'distribution archive excludes secrets and runtime material'

$stopHealthy = Invoke-LoggedDryRun -Path $stop -Scenario 'Healthy'
Assert-True ($stopHealthy.ExitCode -eq 0) 'STOP healthy dry-run succeeds'
$stopLog = Get-Content -LiteralPath $operatorLog -Raw
Assert-True ($stopLog.IndexOf("Disabling task 'AzerothCore Worldserver Restart Watcher'") -ge 0 -and $stopLog.IndexOf("Disabling task 'AzerothCore Worldserver Supervisor'") -gt $stopLog.IndexOf("Disabling task 'AzerothCore Worldserver Restart Watcher'") -and $stopLog.IndexOf('Sending the planned manual SOAP shutdown command') -gt $stopLog.IndexOf("Disabling task 'AzerothCore Worldserver Supervisor'")) 'STOP disables watcher and supervisor before shutdown attempt'
Assert-True ($stopLog -match "would send 'server shutdown 1'") 'STOP dry-run reaches only server shutdown 1'

$filesystemMarker = Join-Path $root 'state\operator-marker-filesystem-test\maintenance-active.json'
$liveMarkerBeforeFilesystemTest = Test-Path -LiteralPath $marker
$filesystemResult = Invoke-OperatorScript -Path $stop -Arguments @('-FilesystemTest','-FilesystemTestMarker',$filesystemMarker,'-LogPath',$operatorLog)
Assert-True ($filesystemResult.ExitCode -eq 0 -and $filesystemResult.Output -match 'PASS filesystem marker') 'real filesystem marker test passes'
Assert-True (-not (Test-Path -LiteralPath $filesystemMarker)) 'filesystem marker test cleans only its isolated test marker'
Assert-True ((Test-Path -LiteralPath $marker) -eq $liveMarkerBeforeFilesystemTest) 'filesystem marker test leaves live marker unchanged'

foreach ($scenario in @('AlreadyStopped')) {
    $result = Invoke-LoggedDryRun -Path $stop -Scenario $scenario
    Assert-True ($result.ExitCode -eq 0) "STOP $scenario is idempotent/non-actionable"
}
foreach ($scenario in @('WatcherDisableFails','SupervisorDisableFails','SupervisorStopFails','VerificationFails','SoapFailure','ShutdownTimeout','DuplicateWorld','PathMismatch')) {
    $result = Invoke-LoggedDryRun -Path $stop -Scenario $scenario
    Assert-True ($result.ExitCode -ne 0) "STOP $scenario fails safely"
    Assert-True ($result.Output -notmatch 'would send.*server shutdown 1') "STOP $scenario does not complete shutdown path"
}

$firstStop = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$stop,'-DryRun','-TestScenario','Healthy','-HoldLockSeconds','3','-LogPath',$operatorLog) -PassThru
Start-Sleep -Milliseconds 500
$secondStop = Invoke-OperatorScript -Path $stop -Arguments @('-DryRun','-TestScenario','Healthy','-LogPath',$operatorLog)
$firstStop.WaitForExit()
Assert-True ($secondStop.ExitCode -eq 0 -and $secondStop.Output -match 'Another START or STOP operation') 'duplicate STOP is suppressed by shared mutex'

$startHealthy = Invoke-LoggedDryRun -Path $start -Scenario 'Healthy'
Assert-True ($startHealthy.ExitCode -eq 0) 'START healthy dry-run succeeds'
$startLog = Get-Content -LiteralPath $operatorLog -Raw
Assert-True ($startLog.LastIndexOf("Disabling task 'AzerothCore Worldserver Restart Watcher'") -lt $startLog.LastIndexOf("Enabling task 'AzerothCore Worldserver Supervisor'") -and $startLog.LastIndexOf('Read-only watcher preflight succeeded') -lt $startLog.LastIndexOf("Enabling task 'AzerothCore Worldserver Restart Watcher'")) 'START keeps watcher disabled until supervisor and preflight succeed'
$startAlreadyHealthy = Invoke-LoggedDryRun -Path $start -Scenario 'AlreadyHealthy'
Assert-True ($startAlreadyHealthy.ExitCode -eq 0) 'START already-healthy state is idempotent'
foreach ($scenario in @('MissingTask','SupervisorEnableFails','SupervisorStartFails','SupervisorStateTimeout','StaleHeartbeat','PidMismatch','StartTimeMismatch','MissingWorld','DuplicateWorld','PathMismatch','PreflightFails','WatcherEnableFails')) {
    $result = Invoke-LoggedDryRun -Path $start -Scenario $scenario
    Assert-True ($result.ExitCode -ne 0) "START $scenario fails safely"
    Assert-True ($result.Output -match 'watcher remains disabled|Restart watcher remains disabled') "START $scenario reports watcher disabled"
}

$firstStart = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$start,'-DryRun','-TestScenario','Healthy','-HoldLockSeconds','3','-LogPath',$operatorLog) -PassThru
Start-Sleep -Milliseconds 500
$secondStart = Invoke-OperatorScript -Path $start -Arguments @('-DryRun','-TestScenario','Healthy','-LogPath',$operatorLog)
$firstStart.WaitForExit()
Assert-True ($secondStart.ExitCode -eq 0 -and $secondStart.Output -match 'Another START or STOP operation') 'duplicate START is suppressed by shared mutex'

$statusExpected = @{
    Healthy = 0
    Maintenance = 0
    MaintenanceTaskUnknown = 1
    StaleSupervisor = 1
    PidMismatch = 1
    Offline = 1
    WatcherError = 1
    WatcherDisabled = 1
    DuplicateWorld = 1
    PathUnavailable = 1
    PathMismatch = 1
    MissingSupervisor = 1
    MalformedSupervisor = 1
}
foreach ($entry in $statusExpected.GetEnumerator()) {
    $beforeMarker = if (Test-Path -LiteralPath $marker) { (Get-Item -LiteralPath $marker).LastWriteTimeUtc } else { $null }
    $result = Invoke-OperatorScript -Path $status -Arguments @('-DryRun','-TestScenario',$entry.Key)
    $afterMarker = if (Test-Path -LiteralPath $marker) { (Get-Item -LiteralPath $marker).LastWriteTimeUtc } else { $null }
    Assert-True ($result.ExitCode -eq $entry.Value -and $result.Output -match "OVERALL STATE: (HEALTHY|MAINTENANCE|DEGRADED|OFFLINE|ERROR)") "STATUS $($entry.Key) reports expected class"
    Assert-True ($beforeMarker -eq $afterMarker) "STATUS $($entry.Key) does not modify the maintenance marker"
    if ($entry.Key -eq 'Healthy') { Assert-True ($result.Output -match 'Running\s+: Yes' -and $result.Output -match 'Path verification: Verified' -and $result.Output -match 'OVERALL STATE: HEALTHY') 'STATUS healthy process is path verified' }
    if ($entry.Key -eq 'PathUnavailable') { Assert-True ($result.Output -match 'Running\s+: Yes' -and $result.Output -match 'Executable path\s+: Unavailable in current context' -and $result.Output -match 'Path verification: Unavailable' -and $result.Output -match 'PID alive\s+: Yes' -and $result.Output -match 'Heartbeat age\s+: (?!N/A)' -and $result.Output -match 'PID matches\s+: Yes' -and $result.Output -match 'StartTime matches: Yes' -and $result.Output -match 'OVERALL STATE: DEGRADED') 'STATUS path-unavailable process remains running with independent supervisor fields' }
    if ($entry.Key -eq 'PathMismatch') { Assert-True ($result.Output -match 'Running\s+: Yes' -and $result.Output -match 'Path verification: Mismatch' -and $result.Output -match 'OVERALL STATE: ERROR') 'STATUS readable path mismatch is explicit error' }
    if ($entry.Key -eq 'DuplicateWorld') { Assert-True ($result.Output -match 'World processes\s+: 2 \(ERROR' -and $result.Output -match 'OVERALL STATE: ERROR') 'STATUS duplicate worldserver processes are explicit error' }
    if ($entry.Key -eq 'MissingSupervisor') { Assert-True ($result.Output -match 'Running\s+: Yes' -and $result.Output -match 'PID alive\s+: No' -and $result.Output -match 'OVERALL STATE: DEGRADED') 'STATUS reports missing supervisor independently of worldserver presence' }
    if ($entry.Key -eq 'MalformedSupervisor') { Assert-True ($result.Output -match 'State file\s+: INVALID' -and $result.Output -match 'OVERALL STATE: ERROR') 'STATUS malformed supervisor state is error' }
    if ($entry.Key -eq 'WatcherDisabled') { Assert-True ($result.Output -match 'Task enabled\s+: Disabled' -and $result.Output -match 'OVERALL STATE: DEGRADED') 'STATUS disabled watcher is degraded' }
    if ($entry.Key -eq 'Maintenance') { Assert-True ($result.Output -match 'OVERALL STATE: MAINTENANCE') 'STATUS maintenance with worldserver absent is not offline' }
    if ($entry.Key -eq 'MaintenanceTaskUnknown') { Assert-True ($result.Output -match 'ACCESS UNAVAILABLE' -and $result.Output -match 'OVERALL STATE: ERROR') 'STATUS never infers maintenance when task access is unavailable' }
}

Assert-True ($stopSource -match 'maintenance-active\.json' -and $startSource -match 'maintenance-active\.json') 'maintenance marker is handled only by operator scripts'
Assert-True ((Get-Content -LiteralPath (Join-Path $root 'Restart-Watcher.ps1') -Raw) -notmatch 'maintenance-active\.json' -and (Get-Content -LiteralPath (Join-Path $root 'Worldserver-Supervisor.ps1') -Raw) -notmatch 'maintenance-active\.json') 'watcher and supervisor do not depend on maintenance marker'

$archivePath = Join-Path ([IO.Path]::GetTempPath()) ('ops-rework-test-' + [guid]::NewGuid().ToString('N') + '.zip')
try {
    $archiveResult = Invoke-OperatorScript -Path $archiveScript -Arguments @('-OutputPath',$archivePath)
    Assert-True ($archiveResult.ExitCode -eq 0 -and (Test-Path -LiteralPath $archivePath)) 'distribution archive is created successfully'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try { $entryNames = @($zip.Entries | ForEach-Object FullName) } finally { $zip.Dispose() }
    $forbiddenEntry = @($entryNames | Where-Object { $_ -match '(?i)(?:^|/)restart bot account\.txt$|(?:^|/)soap-credential\.xml(?:\.|$)|(?:^|/)(?:logs|state|\.git|_corrective-audit|test-artifacts|backups)(?:/|$)|(?:^|/)(?:watcher-task|supervisor-task)\.xml$|\.tmp$|\.zip$' })
    $hasOnlyCurrentRootFiles = @($entryNames | Where-Object { $_ -match '/' }).Count -eq 0
    Assert-True ($forbiddenEntry.Count -eq 0 -and $hasOnlyCurrentRootFiles -and @($entryNames | Where-Object { $_ -eq 'README.md' }).Count -eq 1 -and @($entryNames | Where-Object { $_ -eq '_corrective-audit' -or $_ -match '(?i)^_corrective-audit/' }).Count -eq 0 -and @($entryNames | Where-Object { $_ -eq '.git' -or $_ -match '(?i)^\.git/' }).Count -eq 0) 'distribution archive excludes credentials/runtime/logs/.git/_corrective-audit'
} finally {
    if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue }
}

$psErrors = @()
Get-ChildItem -LiteralPath $root -Filter *.ps1 | ForEach-Object {
    $tokens = $null; $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) { $psErrors += $_.Name }
}
Assert-True ($psErrors.Count -eq 0) 'all staged PowerShell files parse successfully'

Write-Host "`nFailures: $failures"
exit ([int]($failures -gt 0))
