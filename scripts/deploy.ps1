# Installs or updates the PlugBear gateway on this computer: builds here,
# stages the release, points `app` at it, restarts the scheduled task and
# waits for /health. If the new release doesn't come up, `app` goes back to
# the previous one. Windows port of scripts/deploy.sh, local deploys only:
# a gateway on another machine still wants the Mac script over ssh.
#
#   scripts/deploy.ps1               check, build and deploy
#   scripts/deploy.ps1 -SkipChecks   build and deploy without typecheck/tests
#   scripts/deploy.ps1 -Rollback     go back to the previous release
#   scripts/deploy.ps1 -NoPublish    leave `tailscale serve` alone
#   scripts/deploy.ps1 -DryRun       build and stage, then stop before going live
#
# The first deploy also writes settings.json (connectors init), from these
# options; later ones leave it alone:
#   -Mode local|tailscale  -AdminLogin LOGIN  -PublicUrl URL  -Owner NAME
#
# On this machine, under %APPDATA%\Connectors:
#   releases\<id>\  dist\connectors.mjs and google-mcp.mjs, config\ (the examples),
#                   ops\node.json, release.json, and .went-live once it has
#                   served /health (only those are rollback targets; a
#                   release that never came up is deleted)
#   app             junction to the live release, swapped per deploy
#   node\<version>\bin\node.exe  the pinned official Node (ops/node.json)
#   bin\node.exe    a copy of the pinned Node, so the task and the wrapper
#                   don't change between deploys
#   bin\connectors.cmd  wrapper that runs the live release's CLI
# Logs go to %LOCALAPPDATA%\Connectors\logs\connectors.log.
#
# Environment, mostly for testing this script:
#   CONNECTORS_HOME      this machine's data folder (default %APPDATA%\Connectors)
#   CONNECTORS_NODE_CACHE  where the Node download is cached
#   CONNECTORS_HEALTH_WAIT  seconds to wait for /health (default 60)

param(
  [switch]$SkipChecks,
  [switch]$Rollback,
  [switch]$NoPublish,
  [switch]$DryRun,
  [switch]$AllowDirty,
  [switch]$Local,
  [string]$Mode,
  [string]$AdminLogin,
  [string]$PublicUrl,
  [string]$Owner,
  [switch]$Help
)

$ErrorActionPreference = 'Continue'

$Repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Data = if ($env:CONNECTORS_HOME) { $env:CONNECTORS_HOME } else { Join-Path $env:APPDATA 'Connectors' }
$LogsDir = Join-Path $env:LOCALAPPDATA 'Connectors\logs'
$LogFile = Join-Path $LogsDir 'connectors.log'
$NodeCache = if ($env:CONNECTORS_NODE_CACHE) { $env:CONNECTORS_NODE_CACHE } else { Join-Path $env:LOCALAPPDATA 'Connectors\node-cache' }
$HealthWait = if ($env:CONNECTORS_HEALTH_WAIT) { [int]$env:CONNECTORS_HEALTH_WAIT } else { 60 }

if ($Help) {
  @'
deploy.ps1: installs or updates the PlugBear gateway on this computer

  scripts/deploy.ps1               check, build and deploy
  scripts/deploy.ps1 -SkipChecks   build and deploy without typecheck/tests
  scripts/deploy.ps1 -Rollback     go back to the previous release
  scripts/deploy.ps1 -NoPublish    leave `tailscale serve` alone
  scripts/deploy.ps1 -DryRun       build and stage, then stop before going live

See the top of the script for the layout it installs, and
scripts/install.ps1 for the one-command form.
'@ | ForEach-Object { Write-Output $_ }
  exit 0
}

function Say([string]$Text) { Write-Output "==> $Text" }
function Die([string]$Text) { Write-Output "deploy: $Text" | Out-Host; exit 1 }

# --- Running commands ------------------------------------------------------------

function Quote-Argument([string]$Value) {
  if ($Value -notmatch '[\s"]') { return $Value }
  $escaped = $Value -replace '(\\*)"', '$1$1\"'
  $escaped = $escaped -replace '(\\+)$', '$1$1'
  return '"' + $escaped + '"'
}

function Invoke-Raw {
  param([string]$FileName, [string]$ArgumentString, [hashtable]$EnvExtra)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FileName
  $psi.Arguments = $ArgumentString
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.RedirectStandardInput = $true
  $psi.CreateNoWindow = $true
  if ($EnvExtra) {
    foreach ($key in $EnvExtra.Keys) { $psi.EnvironmentVariables[$key] = [string]$EnvExtra[$key] }
  }
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi
  [void]$process.Start()
  $process.StandardInput.Close()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $stderrTask.Result
  $process.WaitForExit()
  return @{ Status = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Invoke-Run {
  param([string]$FileName, [string[]]$CommandArguments = @(), [hashtable]$EnvExtra)
  $argumentString = ($CommandArguments | ForEach-Object { Quote-Argument $_ }) -join ' '
  return Invoke-Raw -FileName $FileName -ArgumentString $argumentString -EnvExtra $EnvExtra
}

# A batch file through cmd.exe: the /S form keeps everything between the
# outer quotes, so the inner path can be quoted for its spaces.
function Invoke-CmdFile {
  param([string]$Path, [string[]]$CommandArguments = @(), [hashtable]$EnvExtra)
  $inner = '"' + $Path + '"'
  if ($CommandArguments.Count -gt 0) { $inner += ' ' + ($CommandArguments -join ' ') }
  return Invoke-Raw -FileName $env:ComSpec -ArgumentString ('/d /s /c "' + $inner + '"') -EnvExtra $EnvExtra
}

# --- The install, as functions so rollback can use them too -----------------------

$nodeSpec = Get-Content -LiteralPath (Join-Path $Repo 'ops\node.json') -Raw | ConvertFrom-Json
$NodeVersion = $nodeSpec.version
$NodeFile = $nodeSpec.win64.file
$NodeSha = $nodeSpec.win64.sha256
if (-not $NodeVersion -or -not $NodeFile -or -not $NodeSha) { Die 'ops/node.json is missing version or the win64 file or sha256.' }

$PinnedNode = Join-Path $NodeCache "$NodeVersion\bin\node.exe"

function Read-Settings([string]$ReleaseDir) {
  $result = Invoke-Run -FileName $PinnedNode -CommandArguments @((Join-Path $ReleaseDir 'dist\connectors.mjs'), 'settings', '--json', '--home', $Data)
  if ($result.Status -ne 0) { Die "Couldn't read the settings with $ReleaseDir." }
  return ($result.Stdout | ConvertFrom-Json).settings
}

function Get-LiveRelease {
  $app = Join-Path $Data 'app'
  if (Test-Path $app) {
    $item = Get-Item $app
    if ($item.LinkType -eq 'Junction' -or $item.LinkType -eq 'SymbolicLink') {
      return (Split-Path -Leaf $item.Target)
    }
  }
  return $null
}

function Write-Wrapper {
  $wrapper = Join-Path $Data 'bin\connectors.cmd'
  $body = @(
    '@echo off',
    'rem Written by scripts/deploy.ps1. Runs the live release''s CLI on the',
    'rem pinned Node, with the data folder this install lives in, so the',
    'rem command works whatever CONNECTORS_HOME says.',
    'set "ROOT=%~dp0.."',
    '"%~dp0node.exe" "%ROOT%\app\dist\connectors.mjs" --home "%ROOT%" %*'
  ) -join "`r`n"
  [System.IO.File]::WriteAllText($wrapper, $body, (New-Object System.Text.UTF8Encoding($false)))
}

function Point-AppAt([string]$ReleaseId) {
  $app = Join-Path $Data 'app'
  if (Test-Path $app) {
    # .NET's Delete removes a junction itself, never what it points at.
    (Get-Item $app).Delete()
  }
  # A junction needs no developer mode, unlike a file symlink. The gateway
  # is stopped while it's swapped, so there's no atomicity to lose.
  $null = New-Item -ItemType Junction -Path $app -Target (Join-Path $Data "releases\$ReleaseId")
}

function Get-Task([string]$TaskLabel) {
  return Get-ScheduledTask -TaskName $TaskLabel -ErrorAction SilentlyContinue
}

function Restart-Gateway([string]$TaskLabel, [int]$GatewayPort) {
  # The task runs its command through wscript, which starts it with no
  # console window. An action on cmd.exe put one on the desktop, where a
  # Ctrl+C killed the gateway with 0xC000013A and the scheduler never
  # brought it back (checked 31 Oct 2026); the loop in the script restarts
  # it whatever way it stops, like the Mac script's launchd KeepAlive.
  $Wscript = Join-Path $env:windir 'System32\wscript.exe'
  $HiddenScript = Join-Path $Data 'bin\run-hidden.vbs'
  $task = Get-Task $TaskLabel
  if ($task -and (@($task.Actions)[0].Execute -ne $Wscript)) {
    # An earlier registration ran cmd.exe as the action; take it out.
    Unregister-ScheduledTask -TaskName $TaskLabel -Confirm:$false
    $task = $null
  }
  if (-not $task) {
    Say "Registering the scheduled task $TaskLabel"
    $node = Join-Path $Data 'bin\node.exe'
    $cli = Join-Path $Data 'app\dist\connectors.mjs'
    # NODE_ENV=production is what lets the gateway report its own bugs to
    # Sentry if settings.json has a DSN (src/sentry.ts); only this task sets
    # it, so tests and dev runs never report.
    $command = 'set "NODE_ENV=production"&& ' + '"' + $node + '" --max-old-space-size=384 "' + $cli + '" serve --home "' + $Data + '" >> "' + $LogFile + '" 2>&1'
    $body = @(
      'Written by scripts/deploy.ps1. Runs the gateway with no console',
      'window and brings it back whatever way it stops. Stopping the',
      'scheduled task stops this script and the gateway with it.',
      'Dim shell',
      'Set shell = CreateObject("WScript.Shell")',
      'Do',
      '  shell.Run "cmd.exe /d /c ' + ($command -replace '"', '""') + '", 0, True',
      '  WScript.Sleep 5000',
      'Loop'
    ) -join "`r`n"
    [System.IO.File]::WriteAllText($HiddenScript, $body, (New-Object System.Text.ASCIIEncoding))
    $action = New-ScheduledTaskAction -Execute $Wscript -Argument ('"' + $HiddenScript + '"') -WorkingDirectory $Data
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
    Register-ScheduledTask -TaskName $TaskLabel -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
  } else {
    Stop-ScheduledTask -TaskName $TaskLabel -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
  }
  Start-ScheduledTask -TaskName $TaskLabel
}

function Wait-Healthy([int]$GatewayPort, [string]$ReleaseId) {
  for ($i = 0; $i -lt $HealthWait; $i++) {
    try {
      $response = Invoke-WebRequest -Uri "http://127.0.0.1:$GatewayPort/health" -UseBasicParsing -TimeoutSec 3
      $health = $response.Content | ConvertFrom-Json
      if ($health.release -eq $ReleaseId) { return $true }
    } catch {
      Start-Sleep -Seconds 1
      continue
    }
    Start-Sleep -Seconds 1
  }
  return $false
}

function Get-GoodReleases {
  $dirs = Get-ChildItem (Join-Path $Data 'releases') -Directory -ErrorAction SilentlyContinue
  return @($dirs | Where-Object { Test-Path (Join-Path $_.FullName '.went-live') } | ForEach-Object { $_.Name } | Sort-Object)
}

function Prune-Releases {
  $liveNow = Get-LiveRelease
  $good = Get-GoodReleases
  foreach ($dir in (Get-ChildItem (Join-Path $Data 'releases') -Directory -ErrorAction SilentlyContinue)) {
    if ($dir.Name -ne $liveNow -and -not (Test-Path (Join-Path $dir.FullName '.went-live'))) {
      Remove-Item -Recurse -Force $dir.FullName
    }
  }
  $keep = @($good | Where-Object { $_ -ne $liveNow } | Sort-Object -Descending | Select-Object -Skip 2)
  foreach ($old in $keep) { Remove-Item -Recurse -Force (Join-Path $Data "releases\$old") }
}

function Test-NodeCached {
  return (Test-Path $PinnedNode)
}

# --- Rollback ----------------------------------------------------------------------

if ($Rollback) {
  if (-not (Test-NodeCached)) { Die "The pinned Node isn't in $NodeCache, so nothing here can run." }
  $live = Get-LiveRelease
  if (-not $live) { Die 'Nothing is live to roll back from.' }
  $previous = @(Get-GoodReleases | Where-Object { $_ -lt $live } | Select-Object -Last 1)
  if ($previous.Count -eq 0) { Die "No release older than $live has been live, so there's nothing to go back to." }
  Say "Rolling back from $live to $($previous[0])."
  $liveSettings = Read-Settings (Join-Path $Data 'app')
  $label = if ($liveSettings.launchdLabel) { $liveSettings.launchdLabel } else { 'local.connectors' }
  $port = if ($liveSettings.port) { [int]$liveSettings.port } else { 8795 }
  Point-AppAt $previous[0]
  Restart-Gateway $label $port
  if (Wait-Healthy $port $previous[0]) {
    Say "$($previous[0]) is live."
    exit 0
  }
  Say "$($previous[0]) didn't come up. Going back to $live." | Out-Host
  Point-AppAt $live
  Restart-Gateway $label $port
  if (Wait-Healthy $port $live) { Say "$live is live again." } else { Say "$live isn't healthy either." | Out-Host }
  exit 1
}

# --- Build -------------------------------------------------------------------------

# npx, on whatever Node the machine has, only to build: the gateway runs on
# the Node ops/node.json pins, downloaded and checked below. Application
# type only, so a PowerShell shim on PATH (npx.ps1) is passed over: this
# script runs npx through cmd.exe, which can't start a .ps1 and would open
# it in whatever .ps1 files are associated with (Notepad, by default)
# instead of building anything.
$Npx = (Get-Command npx -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $Npx) { Die "Install Node.js (with npm) first, for example from https://nodejs.org. It's only used to build." }

$dirty = $false
$sha = '0000000000000000000000000000000000000000'
if (Test-Path (Join-Path $Repo '.git')) {
  $status = git -C $Repo status --porcelain 2>$null
  if ($status) {
    $dirty = $true
    if (-not $AllowDirty) { Die 'The working tree has uncommitted changes. Commit them, or pass -AllowDirty.' }
  }
  $sha = (git -C $Repo rev-parse HEAD 2>$null)
  if (-not $sha) { $sha = '0000000000000000000000000000000000000000' }
} else {
  $dirty = $true
}
$id = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$($sha.Substring(0, 8))"

if (-not (Test-Path (Join-Path $Repo 'node_modules')) -or ((Get-Item (Join-Path $Repo 'package-lock.json')).LastWriteTime -gt (Get-Item (Join-Path $Repo 'node_modules') -ErrorAction SilentlyContinue).LastWriteTime)) {
  Say 'Installing dependencies'
  $ci = Invoke-CmdFile -Path $Npx -CommandArguments @('-y', '-p', "node@$($NodeVersion.TrimStart('v'))", 'npm', 'ci')
  if ($ci.Status -ne 0) { Die "npm ci failed: $($ci.Stderr)" }
}

if ($SkipChecks) {
  Say 'Building (checks skipped)'
} else {
  Say 'Typecheck, tests and build'
}
$build = Invoke-CmdFile -Path $Npx -CommandArguments @('-y', '-p', "node@$($NodeVersion.TrimStart('v'))", 'npm', 'run', $(if ($SkipChecks) { 'build' } else { 'check' }))
if ($build.Status -ne 0) { Die "Build failed: $($build.Stderr)" }

# --- The pinned Node ----------------------------------------------------------------

if (-not (Test-NodeCached)) {
  Say "Downloading $NodeFile"
  $nodeDir = Join-Path $NodeCache $NodeVersion
  New-Item -ItemType Directory -Force -Path (Join-Path $nodeDir 'bin') | Out-Null
  $zip = Join-Path $nodeDir $NodeFile
  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  if ($curl) {
    $null = & curl.exe -fsSL "https://nodejs.org/dist/$NodeVersion/$NodeFile" -o $zip
  }
  if (-not (Test-Path $zip)) {
    Invoke-WebRequest -Uri "https://nodejs.org/dist/$NodeVersion/$NodeFile" -OutFile $zip -UseBasicParsing
  }
  $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
  if ($actual -ne $NodeSha) { Die "$NodeFile has SHA-256 $actual, but ops/node.json pins $NodeSha" }
  $extract = Join-Path $nodeDir 'extract'
  if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
  Expand-Archive -LiteralPath $zip -DestinationPath $extract
  $inner = Get-ChildItem -Path $extract -Directory | Select-Object -First 1
  Copy-Item (Join-Path $inner.FullName 'node.exe') (Join-Path $nodeDir 'bin\node.exe') -Force
  Copy-Item (Join-Path $inner.FullName 'LICENSE') (Join-Path $nodeDir 'LICENSE') -Force -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $extract
}
$version = (& $PinnedNode --version)
if ($version -ne $NodeVersion) { Die "$PinnedNode isn't $NodeVersion" }

# --- Stage -------------------------------------------------------------------------

Say "Staging release $id"
$stage = Join-Path ([System.IO.Path]::GetTempPath()) "connectors-stage-$id"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'dist'), (Join-Path $stage 'config'), (Join-Path $stage 'ops') | Out-Null
Copy-Item (Join-Path $Repo 'dist\connectors.mjs'), (Join-Path $Repo 'dist\google-mcp.mjs') (Join-Path $stage 'dist\')
# Only the examples: each machine's own config lives in its data folder.
Copy-Item (Join-Path $Repo 'config\*.example.json') (Join-Path $stage 'config\')
Copy-Item (Join-Path $Repo 'ops\node.json') (Join-Path $stage 'ops\')
$packageVersion = ((Get-Content -LiteralPath (Join-Path $Repo 'package.json') -Raw | ConvertFrom-Json).version)
$releaseJson = "{`n  `"id`": `"$id`",`n  `"sha`": `"$sha`",`n  `"version`": `"$packageVersion`",`n  `"dirty`": $($(if ($dirty) { 'true' } else { 'false' })),`n  `"builtAt`": `"$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))`",`n  `"node`": `"$NodeVersion`"`n}`n"
[System.IO.File]::WriteAllText((Join-Path $stage 'release.json'), $releaseJson, (New-Object System.Text.UTF8Encoding($false)))

# The staged bundle must run on the pinned Node and accept the examples.
$checkHome = Join-Path ([System.IO.Path]::GetTempPath()) "connectors-check-$id"
$probe = Invoke-Run -FileName $PinnedNode -CommandArguments @((Join-Path $stage 'dist\connectors.mjs'), 'agent', 'list', '--home', $checkHome)
if ($probe.Status -ne 0) { Die "The staged bundle didn't run: $($probe.Stderr)" }
if (Test-Path $checkHome) { Remove-Item -Recurse -Force $checkHome }
# The built-in Google server must start too (it exits when stdin closes).
$google = Invoke-Run -FileName $PinnedNode -CommandArguments @((Join-Path $stage 'dist\google-mcp.mjs'), 'gmail')
if ($google.Status -ne 0) { Die "The staged Google server didn't run: $($google.Stderr)" }

if ($DryRun) {
  Say "Dry run: release $id is staged and checked; stopping before it goes live"
  exit 0
}

# --- The target --------------------------------------------------------------------

Say 'Preparing this machine'
New-Item -ItemType Directory -Force -Path (Join-Path $Data 'releases'), (Join-Path $Data 'node'), (Join-Path $Data 'bin'), (Join-Path $Data 'secrets'), (Join-Path $Data 'state'), $LogsDir | Out-Null
$live = Get-LiveRelease
# A release live from before .went-live existed counts as one that came up.
if ($live -and (Test-Path (Join-Path $Data "releases\$live"))) {
  New-Item -ItemType File -Force -Path (Join-Path $Data "releases\$live\.went-live") | Out-Null
}
$targetNodeDir = Join-Path $Data "node\$NodeVersion"
$nodePresent = Test-Path (Join-Path $targetNodeDir '.verified')
Write-Output "Live release: $(if ($live) { $live } else { 'none' }). Node $NodeVersion on this machine: $(if ($nodePresent) { 'present' } else { 'missing' })."

if (-not $nodePresent) {
  Say "Copying Node $NodeVersion into the data folder"
  New-Item -ItemType Directory -Force -Path (Join-Path $targetNodeDir 'bin') | Out-Null
  Copy-Item (Join-Path $NodeCache "$NodeVersion\bin\node.exe") (Join-Path $targetNodeDir 'bin\node.exe') -Force
  Copy-Item (Join-Path $NodeCache "$NodeVersion\LICENSE") (Join-Path $targetNodeDir 'LICENSE') -Force -ErrorAction SilentlyContinue
  # The NUL-safe sqlite check, straight from the Mac script.
  $nulTest = 'import { DatabaseSync } from "node:sqlite"; const db = new DatabaseSync(":memory:"); db.exec("CREATE TABLE t (body TEXT)"); db.prepare("INSERT INTO t VALUES (?)").run("a\u0000b"); const ok = db.prepare("SELECT body FROM t").get().body === "a\u0000b"; if (process.version !== process.argv[1] || !ok) { console.error(`node ${process.version}, NUL-safe sqlite ${ok}`); process.exit(1); }'
  $check = Invoke-Run -FileName $PinnedNode -CommandArguments @('--input-type=module', '-e', $nulTest, $NodeVersion)
  if ($check.Status -ne 0) { Die "The pinned Node didn't pass the sqlite check: $($check.Stderr)" }
  $verified = "{`n  `"sha256`": `"$NodeSha`",`n  `"checkedAt`": `"$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))`"`n}`n"
  [System.IO.File]::WriteAllText((Join-Path $targetNodeDir '.verified'), $verified, (New-Object System.Text.UTF8Encoding($false)))
  # bin\node.exe is what the task and the wrapper run; it changes only when
  # the pinned version does.
  Copy-Item (Join-Path $targetNodeDir 'bin\node.exe') (Join-Path $Data 'bin\node.exe') -Force
}

Say "Copying release $id into the data folder"
Copy-Item -Recurse -Force $stage (Join-Path $Data "releases\$id")
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue

# --- Activate ----------------------------------------------------------------------

$release = Join-Path $Data "releases\$id"
if (-not (Test-Path (Join-Path $release 'dist\connectors.mjs'))) { Die "$release is incomplete" }

$initArguments = @((Join-Path $release 'dist\connectors.mjs'), 'init', '--home', $Data)
if ($Mode) { $initArguments += @('--mode', $Mode) }
if ($AdminLogin) { $initArguments += @('--admin-login', $AdminLogin) }
if ($PublicUrl) { $initArguments += @('--public-url', $PublicUrl) }
if ($Owner) { $initArguments += @('--owner', $Owner) }
$null = Invoke-Run -FileName $PinnedNode -CommandArguments $initArguments

# The new release must read the config before it goes live.
$settings = Read-Settings $release
$Label = if ($settings.launchdLabel) { $settings.launchdLabel } else { 'local.connectors' }
$Port = if ($settings.port) { [int]$settings.port } else { 8795 }
$ModeSetting = $settings.mode
$ServePort = if ($settings.servePort) { [int]$settings.servePort } else { 8443 }
$PublicUrlSetting = $settings.publicUrl
$null = Invoke-Run -FileName $PinnedNode -CommandArguments @((Join-Path $release 'dist\connectors.mjs'), 'agent', 'list', '--home', $Data)

# Something else on our port would make the health check lie.
$holder = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($holder) {
  $holderProcess = Get-Process -Id $holder.OwningProcess -ErrorAction SilentlyContinue
  $holderPath = if ($holderProcess) { $holderProcess.Path } else { $null }
  if ($holderPath -and ($holderPath -ne (Join-Path $Data 'bin\node.exe'))) {
    Die "Port $Port is in use by $holderPath, which isn't the gateway."
  }
}

# A big log is moved aside before the restart reopens it.
if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 52MB)) {
  Move-Item -Force $LogFile "$LogFile.1"
}

Say "Activating $id"
$previous = Get-LiveRelease
Point-AppAt $id
Write-Wrapper
Restart-Gateway $Label $Port
if (Wait-Healthy $Port $id) {
  New-Item -ItemType File -Force -Path (Join-Path $release '.went-live') | Out-Null
  Say "Release $id is live."
  Prune-Releases
} else {
  Say "Release $id didn't report healthy within $HealthWait seconds. Last log lines:" | Out-Host
  if (Test-Path $LogFile) { Get-Content $LogFile -Tail 20 | Out-Host }
  if ($previous -and $previous -ne $id -and (Test-Path (Join-Path $Data "releases\$previous"))) {
    Say "Going back to $previous." | Out-Host
    Point-AppAt $previous
    Restart-Gateway $Label $Port
    if (Wait-Healthy $Port $previous) {
      Say "$previous is live again." | Out-Host
      Remove-Item -Recurse -Force $release
      Say "Deleted the failed release $id." | Out-Host
    } else {
      Say "$previous isn't healthy either." | Out-Host
    }
  }
  exit 1
}

# --- Publish -----------------------------------------------------------------------

if (-not $NoPublish) {
  Say 'Publishing with tailscale serve'
  if ($ModeSetting -ne 'tailscale') {
    Write-Output 'Local mode, so tailscale serve isn''t needed.'
  } else {
    $tailscale = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (-not (Test-Path $tailscale)) {     $tailscale = (Get-Command tailscale -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
    if (-not $tailscale) {
      Write-Output 'Tailscale CLI not found; skipping tailscale serve.' | Out-Host
    } else {
      $status = & $tailscale serve status --json 2>$null
      $publishPort = $ServePort
      $current = 'unknown'
      if ($status) {
        try {
          $parsed = $status | ConvertFrom-Json
          $proxies = @()
          foreach ($property in $parsed.Web.PSObject.Properties) {
            if ($property.Name -like "*:$publishPort") {
              foreach ($handler in $property.Value.Handlers.PSObject.Properties) { $proxies += $handler.Value.Proxy }
            }
          }
          if ($proxies.Count -eq 1) { $current = $proxies[0] }
          elseif ($proxies.Count -gt 1) { $current = "$($proxies.Count) handlers" }
          elseif ($parsed.TCP.$publishPort) { $current = 'a TCP forward' }
          else { $current = 'free' }
        } catch { $current = 'unknown' }
      }
      switch ($current) {
        'unknown' { Write-Output 'Couldn''t read ''tailscale serve status'', so tailscale serve is left alone.' | Out-Host }
        'free' {
          & $tailscale serve --bg "--https=$publishPort" "http://127.0.0.1:$Port"
          if ($LASTEXITCODE -eq 0) { Write-Output "Published on :$publishPort." }
          else { Write-Output 'tailscale serve failed; the gateway runs, but only on this machine''s loopback.' | Out-Host }
        }
        default {
          if ($current -like "*127.0.0.1:$Port*" -or $current -like "*localhost:$Port*") {
            Write-Output "Already published on :$publishPort."
          } else {
            Write-Output "Port $publishPort already serves $current; leaving tailscale serve alone." | Out-Host
          }
        }
      }
    }
  }
}

Say "Checking $PublicUrlSetting/health"
try {
  $final = Invoke-WebRequest -Uri "$PublicUrlSetting/health" -UseBasicParsing -TimeoutSec 10
  Write-Output $final.Content
} catch {
  Write-Output "Couldn't reach $PublicUrlSetting/health from here. It's live on this machine's loopback; check tailscale serve." | Out-Host
}
