# Task: Local recorder operations helper

- Task ID: d-live-ops
- Owner (person / AI tool): Jintian-JTST / Codex
- Branch: `codex/d-live-ops`
- Status: implementation and checks complete; ready for PR review
- Integrator / reviewer: repository maintainer
- Plan / contract reference: PLAN sections 3 and 6; owner-requested local operations scope

## Outcome and acceptance criteria

Add `deploy/local-recorders.ps1` for Windows PowerShell 5.1: default read-only
inspection, guarded hidden database start, and optional independent short bus 29
capture. Never print credentials, stop processes or delete files.

## Ownership and dependencies

- Changed files: `deploy/local-recorders.ps1`, appended usage in `deploy/README.md`,
  and this explicitly requested evidence record. No shared progress/API/schema edits.
- Existing database workspace retains the old `ingest.poller` module; the
  independent worktree uses `backend.ingest record`. Their evidence remains separate.
- Existing Python installations and private local configuration are prerequisites;
  this task does not configure environments or read environment-file contents.

## Handoff

- Windows PowerShell **5.1.26100.9711**: parser check passed.
- Actual read-only command from the repository root:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File deploy/local-recorders.ps1 -Check`
  completed with exit code 0. Restricted CIM access initially refused the check;
  rerunning with normal process access succeeded. No live recorder was launched.
- Six isolated PowerShell 5.1 checks passed: default inspection leaves fixture
  files unchanged; mocked hidden starts preserve module/workspace/log/route/duration
  arguments and paths with spaces; existing old and renamed database writers each
  block another launch; synthetic credential arguments are redacted; failed CIM
  inspection refuses startup. Fixtures and the harness remain ignored in `.local/`.
- Startup checks mock `Start-Process`; actual recorder launch and sustained
  collection through this helper remain unverified. Existing recorders were untouched.
- `git diff --check`: passed before commit.
- Next action: maintainer reviews the PR into `main`; no merge/deployment requested.

### Actual -Check output

Captured 2026-10-24 at 16:11 UTC / 17:11 Europe/London. Only machine-specific
Python paths are replaced with `<repo>` and `<system-python>` for portability.
Database `trips_observed` counts use its existing inference contract; they are
not equivalent to the independent recorder's usable `independent_trips` count.

```text
Checked at UTC: 2026-10-24T16:11:41.0325305Z
Python recorder processes (credential arguments redacted):
  PID=10080 CommandLine="<repo>\.local\data-workspace\.local\venv\Scripts\python.exe" -u -m ingest.poller
  PID=53292 CommandLine="<system-python>" -u -m ingest.poller
  PID=50952 CommandLine="<system-python>" -m backend.ingest record --run .local\runs\bus29-short-20261024T1546Z --route-id bus-29-outbound-mornington-crescent-tottenham-court-road --minutes 90
Database health:
  last_polled_at: 2026-10-24 16:11:23.664598+00:00
  seconds_since_last_poll: 21.209977
  prediction_rows: 35091
  stop_events: 988
  bus-29-outbound-finsbury-park-tottenham-court-road: trips_observed=14
  bus-29-outbound-mornington-crescent-tottenham-court-road: trips_observed=22
  tube-victoria-outbound-brixton-oxford-circus: trips_observed=47
Latest independent bus 29 recording:
  run: bus29-short-20261024T1546Z
  status: recording
  last_log: polls=51 independent_trips=1
```

### Fix: bus 29 start, 2026-10-24 16:40 UTC (17:40 London)

Owner for this fix: Claude, after Jintian moved Codex's D work to Claude.

- Bug: `-Start -StartBus29Minutes` created the run directory before launching
  `backend.ingest record`, which calls `mkdir(exist_ok=False)`. The recorder
  printed `FileExistsError` and exited at once, so no bus 29 run could start
  through the helper. The earlier checks mocked `Start-Process` and missed it.
- Fix: the helper no longer creates the run directory; logs go to the sibling
  `bus29-short-<stamp>.log`/`.err`, matching runs started by hand and the
  existing `-Check` fallback. A running `backend.ingest record` process now
  blocks another bus 29 launch (its `replay` children do not).
- Checks (Linux, PowerShell 7.4.6 with mocked `Get-CimInstance` and a fake
  Python that refuses an existing run directory, like the real recorder): parser
  0 errors; the original script reproduced `FileExistsError`; the fixed script
  launched with the run directory absent, a repository path containing a space
  and logs beside the run; a mocked running recorder refused the launch.
  `python -m backend.ingest record` against an existing directory printed
  `FileExistsError` and exited 2. Windows PowerShell 5.1 and a real launch
  remain unverified.
