# Safe AzerothCore worldserver restart watcher

This is the current small-server maintenance implementation for
`C:\azeroth\build\bin\RelWithDebInfo`. It keeps authserver, MySQL, and the chatter
bridge independent. The live configuration has been validated with controlled
STOP/START and automatic restart tests.

## Current design

- `Restart-Watcher.ps1` runs once per minute, checks uptime, and uses authenticated
  localhost SOAP. Automatic maintenance uses `server shutdown 300` after roughly
  5h55; AzerothCore owns the countdown.
- `Worldserver-Supervisor.ps1` is the single worldserver owner. It adopts an existing
  process, validates readiness, and relaunches only when an exact PID/start-time
  `Armed` + `Accepted` ticket authorizes one replacement.
- Manual STOP uses only `server shutdown 1`, disables both tasks first, and never
  force-kills a process. START re-enables the supervisor, waits for fresh heartbeat
  and readiness, runs preflight, then enables the watcher.
- STATUS is read-only. A process whose executable path is unavailable in the current
  Windows token is reported as running but `DEGRADED`, never silently treated as offline.
- SOAP credentials are DPAPI-protected for the task identity and are never logged.

## Files

- `Restart-Watcher.ps1`: one-minute uptime watcher. It sends only `server info`,
  `announce`, and automatic `server shutdown 300` over authenticated localhost SOAP.
- `Worldserver-Supervisor.ps1`: conservative owner required by the automated watcher.
  It refuses to launch beside an existing matching executable, adopts the current
  process, and relaunches only after consuming a valid exact persistent Armed ticket.
  Exit codes are diagnostic only.
- `Set-SoapCredential.ps1`: DPAPI-protected credential provisioning.
- `Register-RestartWatcher.ps1`: creates one disabled-by-default repeating task;
  `-Enable` is explicit.
- `Register-Supervisor.ps1`: creates the disabled-by-default persistent supervisor
  task for the interactive server account.
- `Test-RestartAutomation.ps1`: dry-run, mockable SOAP, mutex, state, and exit-code
  tests.
- `Stop-AzerothCoreMaintenance.ps1`, `Start-AzerothCore.ps1`, and
  `Status-AzerothCore.ps1`: administrator-controlled manual maintenance operations;
  STATUS is read-only.
- `Test-OperatorMaintenance.ps1`: non-destructive STOP/START/STATUS test harness.
- `New-OpsReworkArchive.ps1`: distribution ZIP builder with credential/runtime exclusions.
- `logs\`: operational logs; `state\`: DPAPI credential and atomic restart state.

## Manual operator controls

The desktop wrappers call only the three scripts under `C:\azeroth\ops-rework`.
They do not contain server-control logic. STOP and START request UAC elevation when
needed; STATUS remains read-only.

### STOP FOR MAINTENANCE

`Stop-AzerothCoreMaintenance.ps1` acquires the shared
`Global\AzerothCoreManualMaintenanceControl` mutex, disables the restart watcher
first, disables and stops the supervisor task, and positively verifies both tasks
are disabled with the supervisor no longer Running. It then atomically creates
`state\maintenance-active.json`.

Only after those checks does it inspect the exact worldserver executable and, when
present, send the single manual SOAP command:

```text
server shutdown 1
```

The 1-second value is required by this Playerbot build. SOAP failure or timeout leaves
both tasks disabled and the maintenance marker present. No forceful termination or
fallback control path exists. If worldserver is already absent, STOP succeeds
idempotently without sending SOAP.

### START

`Start-AzerothCore.ps1` uses the same mutex and keeps the watcher disabled throughout
startup. It verifies the required files/tasks, enables and starts the existing hidden
supervisor task when needed, waits for a fresh supervisor heartbeat and exact
worldserver PID/start-time match, runs the existing read-only
`Restart-Watcher.ps1 -Preflight`, and enables the watcher last. The maintenance marker
is removed only after all checks succeed. It never launches `worldserver.exe`
directly, creates a duplicate supervisor, or issues a restart command.

If START fails, the watcher is re-disabled where possible and the maintenance marker
is retained for operator investigation.

### STATUS

`Status-AzerothCore.ps1` is completely read-only. It reports exact worldserver
identity and uptime, supervisor task/heartbeat/process validation, watcher task run
metadata, maintenance marker contents, SOAP configuration and localhost port
reachability, and an overall `HEALTHY`, `MAINTENANCE`, `DEGRADED`, `OFFLINE`, or
`ERROR` state. It does not repair anything or invoke SOAP commands.

Worldserver process existence is intentionally separate from executable-path
verification so STATUS remains useful without elevation. `Get-Process worldserver`
establishes existence, PID, and start time. The path is then independently reported
as `Verified`, `Unavailable`, or `Mismatch`:

- `Unavailable` means Windows did not expose the executable path in the current
  context. STATUS still reports the process as running and can compare its PID and
  start time to supervisor state; the overall state is `DEGRADED`, never `OFFLINE`.
- `Mismatch` means Windows supplied a readable path that is not the configured binary.
  STATUS reports the process but treats the result as `ERROR`.
- Multiple `worldserver.exe` processes are reported individually and are `ERROR`;
  STATUS never silently chooses one.

Supervisor PID liveness and heartbeat age are evaluated from supervisor state even
when worldserver is absent or its executable path is unavailable. STATUS writes no
log, state, task, process, marker, or SOAP data.

The current user's wrappers are:

```text
C:\Users\homelab\Desktop\AzerothCore - STOP FOR MAINTENANCE.cmd
C:\Users\homelab\Desktop\AzerothCore - START.cmd
C:\Users\homelab\Desktop\AzerothCore - STATUS.cmd
```

Manual operation log:

```text
C:\azeroth\ops-rework\logs\operator-maintenance-YYYY-MM.log
```

## AzerothCore source evidence

Checked-out Playerbot source is authoritative here.

- `src/server/game/World/World.h:51-56` defines shutdown `0`, error `1`, restart `2`.
- `src/server/apps/worldserver/Main.cpp:422-426` says exit code 2 is the code a
  restarter can use for an AzerothCore restart.
- `src/server/scripts/Commands/cs_server.cpp:314-364` accepts `server shutdown
  <delay>`, parses a positive numeric delay such as `300`, and calls
  `ShutdownServ(delay, 0, SHUTDOWN_EXIT_CODE)`.
- `src/server/scripts/Commands/cs_server.cpp:367-415` maps `server restart` to
  `ShutdownServ(..., SHUTDOWN_MASK_RESTART, RESTART_EXIT_CODE, ...)`.
- `src/server/game/World/World.cpp:1547-1577` sets the timer and uses the internal
  graceful shutdown path for either command; `server shutdown 300` is therefore the
  verified automatic command on this build.
- `src/server/game/World/World.cpp:1579-1618` makes AzerothCore's own countdown
  authoritative and emits regular five-minute/one-minute/30-second/10-second
  messages.
- `src/server/scripts/Commands/cs_message.cpp:40-46,79-86` defines `announce`.
- `data/sql/base/db_world/command.sql:642-650` records `server shutdown #delay`
  syntax and command security.
- `src/server/apps/worldserver/ACSoap/ACSoap.cpp:81-107` requires HTTP credentials,
  validates the password, and requires `SEC_ADMINISTRATOR` (gmlevel 3) before
  queuing a command. This local source means SOAP cannot be reduced below level 3
  merely by the PowerShell script; do not grant broader access to this account than
  the local server's security model permits, and do not alter databases here.
- `src/server/apps/worldserver/ACSoap/ACSoap.cpp:114-135` shows SOAP commands are
  queued to the world thread and the response is awaited.

## Credential setup

Create or provision the dedicated AzerothCore account using the administrator's
normal server-console process. The local SOAP implementation requires gmlevel 3;
the exact account action is intentionally not automated here.

Run `Set-SoapCredential.ps1` as the same Windows identity that will run the task:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\azeroth\ops-rework\Set-SoapCredential.ps1 -SoapUsername restartbot
```

The password is entered interactively, encrypted by Windows DPAPI, ACL-restricted to
that identity plus SYSTEM and Administrators, and never logged. Do not run the task
as SYSTEM when this file was provisioned under a user: SYSTEM cannot decrypt a
CurrentUser DPAPI file. Rotate by running the same command again; the staged file is
replaced atomically.

## Safe tests

The development preflight is read-only. With no credential provisioned, it should
fail safely; with a valid credential it may execute only `server info`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\azeroth\ops-rework\Restart-Watcher.ps1 -Preflight
```

One explicitly requested harmless announcement test is:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\azeroth\ops-rework\Restart-Watcher.ps1 -TestAnnouncement
```

The full harness is non-destructive and uses DryRun/mock SOAP for timing and failure
cases:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\azeroth\ops-rework\Test-RestartAutomation.ps1
```

Never use a destructive `server restart`, `server shutdown`, `server exit`, or
`server restart cancel` command for development testing. The watcher has no fallback
termination path.

## Timing, state, and duplication

The watcher polls every minute but does not own the uptime clock. It reads the actual
worldserver executable's `StartTime`, uses a five-hours-55-minutes threshold, verifies
the live supervisor heartbeat, runs `server info`, sends one maintenance announcement,
then writes `Preparing`, revalidates the supervisor, persists an `Armed` ticket with
`ShutdownCommandStatus=Pending`, and sends `server shutdown 300`. Only a successful
SOAP response changes that field to `Accepted`. AzerothCore's internal timer is
authoritative; the watcher sends no later one-minute announcement. A manual
worldserver restart or reboot naturally creates a new PID/start time and resets the
six-hour window.

The scheduled task uses `MultipleInstances=IgnoreNew`. The script also holds a global
mutex and writes `state\restart-state.json` atomically. State contains an explicit
status, `Intent=AutomaticSixHourRestart`, PID, StartTimeUtc, preparation/armed times,
expected shutdown time, command, and command acceptance status. `Armed` plus
`ShutdownCommandStatus=Accepted` is the only state that can authorize the supervisor.
PID alone is never treated as identity. A provisional `Preparing` state is written
before the announcement/command sequence, so a process crash cannot cause the next
minute tick to duplicate a request; a missed restart is preferred. Preparing state
records `PreparingStartedUtc`; after 20 minutes it is logged as permanently blocked
for automatic maintenance, without automatic clearing or retry. An administrator
must investigate whether the restart was accepted, then clear it deliberately if
appropriate:

```powershell
Remove-Item -LiteralPath C:\azeroth\ops-rework\state\restart-state.json -Force
```

If `restart-state.json` is malformed or unreadable, it is an ambiguous state. The
watcher returns an explicit invalid result, logs an `ERROR` that automatic maintenance
is blocked, and performs no uptime decision, SOAP preflight, announcement, or restart.
It never modifies or deletes the malformed file. A separate
`state\restart-state-invalid-warning.json` marker limits the blocked-state warning to
once per hour.

Manual malformed-state recovery is deliberate and ordered:

1. Disable the watcher task first.
2. Inspect and back up `restart-state.json`.
3. Determine whether a restart could already be pending.
4. Only when safe, deliberately rename or remove the malformed file.
5. Run `Restart-Watcher.ps1 -Preflight`.
6. Re-enable the watcher only after review.

For valid stale non-Preparing state, the watcher may clear state belonging to an old
PID/start time. If SOAP preflight or the initial announcement fails, no shutdown
command is sent. A definitive shutdown submission failure becomes `Blocked`; an
uncertain result becomes `Ambiguous`. Neither status is retried or treated as
automatic relaunch permission.

## Supervisor and live transition

The supervisor publishes `state\supervisor-state.json` atomically with its PID, the exact
worldserver PID and StartTimeUtc, supervisor start time, a heartbeat no older than
30 seconds, script path, and `Status=Supervising`. It refreshes that heartbeat while
waiting for readiness and while supervising.

Before even sending the maintenance announcement, the watcher requires a present
state file, a live PowerShell supervisor process running this exact script, a fresh
heartbeat, matching worldserver PID and StartTimeUtc, and `Status=Supervising`. It
rechecks all of this immediately before arming the automatic shutdown ticket. Any failure skips the
restart. If the supervisor disappears after the initial announcement but before this
final validation, players may already have seen the maintenance announcement, but the
restart is still aborted. That cosmetic result is intentional fail-safe behavior; the
second validation must not be weakened. The supervisor removes its own state in
`finally`; if it crashes, the stale heartbeat remains protective.

The supervisor reads the persistent ticket after every worldserver exit. It
requires `Status=Armed`, `Intent=AutomaticSixHourRestart`,
`ShutdownCommandStatus=Accepted`, the exact exited PID, and the exact exited
StartTimeUtc. It consumes the ticket before launching and clears it only after the
replacement is ready. Exit code 0, exit code 2, or an unavailable exit code may all
accompany a valid ticket; none is sufficient by itself. Without a valid ticket,
including for manual `server shutdown 1`, the supervisor stays down and does not
relaunch.

The supervisor never calls `Stop-Process`, `taskkill`, CTRL_BREAK, or any other
termination API. It does not start authserver, MySQL, or the chatter bridge.

Example adoption command (keep this PowerShell window available during the controlled
test):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\azeroth\ops-rework\Worldserver-Supervisor.ps1
```

After relaunch it checks port 8085 and the new `Server.log` tail for the readiness
marker. It does not assume that spawning alone means startup succeeded.

## Persistent supervisor task

Registration is disabled by default, but the current production task is enabled:
`AzerothCore Worldserver Supervisor`. It uses an `AtLogOn` trigger for the intended
server account, an `Interactive` principal, `MultipleInstances=IgnoreNew`, no
`StartWhenAvailable`, no automatic task-level restart-on-failure, and no finite
execution limit. It launches PowerShell with `-WindowStyle Hidden`; the current
production task was inspected with that action.

The tradeoff is deliberate: it runs only while that account is logged on. A headless
or logged-off VM will have no supervisor and the watcher will safely skip maintenance.
The supervisor task must not be changed to catch up missed logon/startup events unless
the resulting behavior is reviewed. If console visibility is not acceptable, use a
separate reviewed headless supervisor design; do not weaken watcher validation.

## Task registration and XML inspection

Registration is disabled by default. These commands create temporary disabled
inspection tasks and do not restart anything:

```powershell
.\Register-RestartWatcher.ps1 -InspectOnly -InspectInteractive
Export-ScheduledTask -TaskName 'AzerothCore Worldserver Restart Watcher' |
    Out-File -FilePath C:\azeroth\ops-rework\watcher-task.xml -Encoding Unicode
.\Register-Supervisor.ps1 -InspectOnly
Export-ScheduledTask -TaskName 'AzerothCore Worldserver Supervisor' |
    Out-File -FilePath C:\azeroth\ops-rework\supervisor-task.xml -Encoding Unicode
Get-ScheduledTask -TaskName 'AzerothCore Worldserver Supervisor','AzerothCore Worldserver Restart Watcher' | Format-List *
```

Expected XML/configuration:

- one `Once` trigger with a one-minute repetition interval (no fixed wall-clock
  triggers);
- `StartWhenAvailable` absent/default false;
- `MultipleInstances` `IgnoreNew`;
- execution time limit `PT20M`;
- action `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File
  "C:\azeroth\ops-rework\Restart-Watcher.ps1"`, working directory ops-rework root;
- principal is the selected task identity at highest run level. Production must use
  the same identity that provisioned the DPAPI file.

Supervisor task expectations:

- `AtLogOn` for the selected server account;
- `Interactive` principal and `-WindowStyle Hidden` action;
- `MultipleInstances=IgnoreNew`;
- `StartWhenAvailable` absent/default false;
- no task-level restart-on-failure policy;
- no finite execution limit;
- action points to `Worldserver-Supervisor.ps1`.

Remove inspection state:

```powershell
.\Register-RestartWatcher.ps1 -Remove
.\Register-Supervisor.ps1 -Remove
Remove-Item -LiteralPath C:\azeroth\ops-rework\watcher-task.xml -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath C:\azeroth\ops-rework\supervisor-task.xml -Force -ErrorAction SilentlyContinue
```

After inspection, provision the credential and register a disabled production task:

```powershell
.\Register-RestartWatcher.ps1 -RunAsUser 'COMPUTER\serveruser' -InspectOnly
```

The script prompts for the Windows task password, then keeps the task disabled. Only
after reviewing its exported XML and running the harmless preflight should an
administrator explicitly run the same command with `-Enable`. There is no
`StartWhenAvailable` catch-up behavior.

The supervisor task is also disabled until the same review is complete. Because its
trigger is `AtLogOn`, an administrator who enables it while already logged on should
start it explicitly for the controlled adoption check:

```powershell
Enable-ScheduledTask -TaskName 'AzerothCore Worldserver Supervisor'
Start-ScheduledTask -TaskName 'AzerothCore Worldserver Supervisor'
Get-Content -LiteralPath C:\azeroth\ops-rework\state\supervisor-state.json
```

Do not start the watcher until that state shows the current worldserver PID,
`WorldserverStartTimeUtc`, a recent `LastHeartbeatUtc`, and `Status` equal to
`Supervising`.

## Loading revised supervisor code without restarting worldserver

The scheduled supervisor process already running in memory does not reload an edited
`.ps1` file. After an administrator confirms that the exact worldserver process is
running, use this controlled transition. It disables only the watcher, stops only the
PowerShell supervisor task, and verifies that the worldserver PID is unchanged before
starting the revised supervisor. Do not run it while worldserver is absent.

```powershell
$worldPath = 'C:\azeroth\build\bin\RelWithDebInfo\worldserver.exe'
$watcherName = 'AzerothCore Worldserver Restart Watcher'
$supervisorName = 'AzerothCore Worldserver Supervisor'
$before = @(Get-CimInstance Win32_Process -Filter "Name='worldserver.exe'" |
    Where-Object { $_.ExecutablePath -and ([IO.Path]::GetFullPath($_.ExecutablePath).ToLowerInvariant() -eq $worldPath.ToLowerInvariant()) })
if ($before.Count -ne 1) { throw 'Abort: exactly one expected worldserver.exe must be running.' }
$beforePid = [int]$before[0].ProcessId

Disable-ScheduledTask -TaskName $watcherName
Stop-ScheduledTask -TaskName $supervisorName
do { Start-Sleep -Seconds 2; $task = Get-ScheduledTask -TaskName $supervisorName } while ($task.State -eq 'Running')

$during = @(Get-CimInstance Win32_Process -Filter "Name='worldserver.exe'" |
    Where-Object { $_.ExecutablePath -and ([IO.Path]::GetFullPath($_.ExecutablePath).ToLowerInvariant() -eq $worldPath.ToLowerInvariant()) })
if ($during.Count -ne 1 -or [int]$during[0].ProcessId -ne $beforePid) { throw 'Abort: worldserver identity changed during supervisor transition.' }

Start-ScheduledTask -TaskName $supervisorName
do {
    Start-Sleep -Seconds 5
    $state = Get-Content -LiteralPath C:\azeroth\ops-rework\state\supervisor-state.json -Raw | ConvertFrom-Json
} while ($state.Status -ne 'Supervising')
if ([int]$state.WorldserverPid -ne $beforePid) { throw 'Abort: revised supervisor did not adopt the original worldserver PID.' }

powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\azeroth\ops-rework\Restart-Watcher.ps1 -Preflight
if ($LASTEXITCODE -ne 0) { throw 'Abort: watcher preflight failed; leave watcher disabled.' }
Enable-ScheduledTask -TaskName $watcherName
Get-ScheduledTask -TaskName $watcherName,$supervisorName | Format-Table TaskName,State
Get-Content -LiteralPath C:\azeroth\ops-rework\state\supervisor-state.json
```

If any check fails, leave the watcher disabled and investigate; do not start a second
worldserver or use a termination fallback.

## Controlled live test

For a future controlled validation, choose a quiet window and explicitly perform the
following steps. The implementation has already completed this sequence once.

1. Confirm the supervisor adopted the current PID and the watcher task is disabled
   until the final decision.
2. Confirm `Restart-Watcher.ps1 -Preflight` reports successful `server info`.
3. Enable/start the supervisor task and then enable the watcher task with the
   corresponding `Register-Supervisor.ps1 -RunAsUser ... -Enable` and
   `Register-RestartWatcher.ps1 -RunAsUser ... -Enable` commands. If the account is
   already logged on, use `Start-ScheduledTask` for the supervisor as shown above.
4. Wait until the actual uptime threshold. If a shorter validation is required, use
   an isolated reviewed test copy; do not add a production time override.
5. Watch `logs\worldserver-restart-YYYY-MM.log`, `Server.log`, port 8085, and the
   supervisor console. Confirm the maintenance announcement, an `Armed` ticket with
   `ShutdownCommandStatus=Accepted`, AzerothCore native countdown, exact-ticket
   consumption, one new PID, fresh heartbeat, and readiness. Do not require exit code
   2; it is diagnostic only. Authserver and the bridge should remain running.
6. Leave both tasks enabled only when normal automatic maintenance is desired.

The watcher never exposes SOAP beyond 127.0.0.1 and never logs the
credential, password, or Authorization header.

## Distribution archive

Use `New-OpsReworkArchive.ps1` for a distributable ZIP. It excludes
`restart bot account.txt`, the DPAPI credential, credential temporary files, all
runtime JSON/TMP state, logs, task XML exports, and existing ZIPs. It refuses to
overwrite an existing archive:

```powershell
.\New-OpsReworkArchive.ps1 -OutputPath C:\azeroth\ops-rework-distribution.zip
```

The archive contains only the current scripts and README. It intentionally excludes
`.git`, `_corrective-audit`, task XML exports, credentials, runtime state, logs,
temporary tests, and existing ZIP files.

## Rollback / emergency disable

Disable the watcher immediately:

```powershell
Disable-ScheduledTask -TaskName 'AzerothCore Worldserver Restart Watcher'
```

Remove the task. Do not automatically delete restart state during rollback; malformed
or ambiguous state requires the manual recovery procedure above:

```powershell
.\Register-RestartWatcher.ps1 -Remove
```

Do not use the old `Restart-Azeroth.ps1` or `Register-AzerothTasks.ps1`; they remain
outside this implementation and contain unsafe behavior.
