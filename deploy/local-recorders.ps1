#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Check')]
param(
    [Parameter(ParameterSetName = 'Check')]
    [switch]$Check,

    [Parameter(Mandatory = $true, ParameterSetName = 'Start')]
    [switch]$Start,

    [Parameter(ParameterSetName = 'Start')]
    [ValidateRange(1, 2147483647)]
    [int]$StartBus29Minutes,

    [string]$SystemPython = 'D:\Python311\python.exe'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$DatabaseWorkspace = Join-Path $RepoRoot '.local\data-workspace\backend'
$DatabasePython = Join-Path $RepoRoot '.local\data-workspace\.local\venv\Scripts\python.exe'
$BusWorkspace = Join-Path $RepoRoot '.local\worktrees\bus29-short'
$RunsRoot = Join-Path $BusWorkspace '.local\runs'
$BusRoute = 'bus-29-outbound-mornington-crescent-tottenham-court-road'

function Get-RecorderProcesses {
    # Fail closed: an unreadable process list must never authorize another writer.
    try {
        @(Get-CimInstance Win32_Process -Filter "Name LIKE 'python%.exe'" |
            Where-Object { $_.CommandLine -match 'ingest\.poller|ingest\.database_poller|backend\.ingest' })
    }
    catch {
        throw 'Cannot inspect Python processes; no recorder will be started.'
    }
}

function Protect-CommandLine([string]$CommandLine) {
    # Never echo connection URLs or credential arguments from another process.
    $safe = $CommandLine -replace '(?i)\b[a-z][a-z0-9+.-]*://[^\s"'']+', '[redacted-url]'
    $safe -replace '(?i)(?:--?)?\b[\w-]*(?:key|token|secret|password|passwd|database_url|authorization)[\w-]*\b\s*(?:=|:|\s)\s*(?:"[^"]*"|''[^'']*''|[^\s]+)', '[redacted-argument]'
}

function Show-DatabaseHealth {
    Write-Output 'Database health:'
    if (-not (Test-Path -LiteralPath $DatabasePython -PathType Leaf) -or
        -not (Test-Path -LiteralPath $DatabaseWorkspace -PathType Container)) {
        Write-Output '  unavailable (workspace or Python missing)'
        return
    }
    Push-Location -LiteralPath $DatabaseWorkspace
    try {
        # Capture both streams, including native errors in Windows PowerShell 5.1.
        # -B prevents a read-only check from creating Python bytecode caches.
        $ErrorActionPreference = 'Continue'
        $raw = @(& $DatabasePython -B -m ingest.admin health 2>&1)
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($code -ne 0) {
            Write-Output '  unavailable (health command failed; details hidden)'
            return
        }
        $health = ($raw -join "`n") | ConvertFrom-Json
        foreach ($field in @('last_polled_at', 'seconds_since_last_poll', 'prediction_rows', 'stop_events')) {
            Write-Output ('  {0}: {1}' -f $field, $health.$field)
        }
        foreach ($route in $health.route_coverage) {
            Write-Output ('  {0}: trips_observed={1}' -f $route.route_id, $route.trips_observed)
        }
    }
    catch {
        Write-Output '  unavailable (health output could not be read; details hidden)'
    }
    finally {
        Pop-Location
    }
}

function Show-BusRecording {
    Write-Output 'Latest independent bus 29 recording:'
    if (-not (Test-Path -LiteralPath $RunsRoot -PathType Container)) {
        Write-Output '  unavailable (runs directory missing)'
        return
    }
    $latest = Get-ChildItem -LiteralPath $RunsRoot -Directory -Filter 'bus29-short-*' |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($null -eq $latest) {
        Write-Output '  no runs found'
        return
    }
    Write-Output ('  run: {0}' -f $latest.Name)
    try {
        $metadata = Get-Content -LiteralPath (Join-Path $latest.FullName 'run.json') -Raw | ConvertFrom-Json
        Write-Output ('  status: {0}' -f $metadata.status)
    }
    catch {
        Write-Output '  status: unavailable (run.json missing or unreadable)'
    }
    # Runs keep a sibling .log file; recorder.log inside a run is from the earlier helper layout.
    $log = Join-Path $latest.FullName 'recorder.log'
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) {
        $log = $latest.FullName + '.log'
    }
    try {
        $last = Get-Content -LiteralPath $log -Tail 1 | ConvertFrom-Json
        if ($null -ne $last.result) { $last = $last.result | ConvertFrom-Json }
        if ($null -eq $last.polls -or $null -eq $last.independent_trips) {
            Write-Output '  last_log: polls=unavailable independent_trips=unavailable (no counts on last line)'
        }
        else {
            Write-Output ('  last_log: polls={0} independent_trips={1}' -f $last.polls, $last.independent_trips)
        }
    }
    catch {
        Write-Output '  last_log: unavailable (log missing or unreadable)'
    }
}

function Start-HiddenPython([string]$Python, [string]$Workspace, [string[]]$Arguments, [string]$LogBase) {
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf) -or
        -not (Test-Path -LiteralPath $Workspace -PathType Container)) {
        throw 'Cannot start recorder: workspace or Python missing.'
    }
    if ((Test-Path -LiteralPath ($LogBase + '.log')) -or (Test-Path -LiteralPath ($LogBase + '.err'))) {
        throw 'Cannot start recorder: log names already exist; files preserved.'
    }
    try {
        $process = Start-Process -FilePath $Python -ArgumentList $Arguments -WorkingDirectory $Workspace `
            -WindowStyle Hidden -RedirectStandardOutput ($LogBase + '.log') `
            -RedirectStandardError ($LogBase + '.err') -PassThru
        Write-Output ('  launched PID={0}; inspect -Check and logs to confirm collection' -f $process.Id)
        Write-Output ('  stdout: {0}.log' -f $LogBase)
        Write-Output ('  stderr: {0}.err' -f $LogBase)
    }
    catch {
        throw 'Recorder launch failed; error details hidden. No process was stopped.'
    }
}

Write-Output ('Checked at UTC: {0}' -f [DateTime]::UtcNow.ToString('o'))
$recorders = @(Get-RecorderProcesses)
Write-Output 'Python recorder processes (credential arguments redacted):'
if ($recorders.Count -eq 0) { Write-Output '  none' }
foreach ($recorder in $recorders) {
    Write-Output ('  PID={0} CommandLine={1}' -f $recorder.ProcessId, (Protect-CommandLine $recorder.CommandLine))
}
Show-DatabaseHealth
Show-BusRecording
if (-not $Start) { return }

# Serialize starts from this helper, then inspect again immediately before launch.
# Manual launches outside this helper must also respect the single-writer rule.
$mutex = New-Object System.Threading.Mutex($false, 'Local\DelayLensDatabaseRecorderStart')
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another local recorder start is in progress; try -Check later.' }
    $writers = @(Get-RecorderProcesses | Where-Object {
        $_.CommandLine -match '\bingest\.(?:poller|database_poller)\b' -and
        $_.CommandLine -notmatch '\bbackend\.ingest\b'
    })
    if ($writers.Count -gt 0) {
        Write-Output 'Database start refused: a database recorder is already running. Existing processes preserved.'
    }
    else {
        $logs = Join-Path $DatabaseWorkspace '.local\logs'
        if (-not (Test-Path -LiteralPath $DatabaseWorkspace -PathType Container)) {
            throw 'Database workspace missing; no recorder started.'
        }
        [System.IO.Directory]::CreateDirectory($logs) | Out-Null
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')
        Start-HiddenPython $DatabasePython $DatabaseWorkspace @('-u', '-m', 'ingest.poller') (Join-Path $logs ('database-' + $stamp))
    }
    if ($PSBoundParameters.ContainsKey('StartBus29Minutes')) {
        if (-not (Test-Path -LiteralPath $BusWorkspace -PathType Container) -or
            -not (Test-Path -LiteralPath $SystemPython -PathType Leaf)) {
            throw 'Bus 29 workspace or system Python missing; independent recorder not started.'
        }
        $busWriters = @(Get-RecorderProcesses | Where-Object { $_.CommandLine -match '\bbackend\.ingest\s+record\b' })
        if ($busWriters.Count -gt 0) {
            Write-Output 'Bus 29 start refused: an independent recorder is already running. Existing processes preserved.'
        }
        else {
            $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')
            $run = Join-Path $RunsRoot ('bus29-short-' + $stamp)
            if (Test-Path -LiteralPath $run) { throw 'Run directory already exists; files preserved.' }
            # The recorder creates the run directory and refuses an existing one, so logs sit beside it.
            [System.IO.Directory]::CreateDirectory($RunsRoot) | Out-Null
            $minutes = $StartBus29Minutes.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            Start-HiddenPython $SystemPython $BusWorkspace @('-u', '-m', 'backend.ingest', 'record',
                '--route-id', $BusRoute, '--run', ('"' + $run + '"'), '--minutes', $minutes) $run
        }
    }
}
finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
