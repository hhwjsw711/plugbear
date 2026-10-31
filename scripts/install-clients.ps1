# Wires the agents on this computer to a PlugBear gateway installed on it.
# Running it again is safe. Windows port of scripts/install-clients.sh.
#
#   scripts/install-clients.ps1             wire everything that's installed
#   scripts/install-clients.ps1 -DryRun     say what would change, change nothing
#   scripts/install-clients.ps1 -Rotate     make new tokens for every agent first
#   scripts/install-clients.ps1 -Only codex,grok
#   scripts/install-clients.ps1 -Remove     take the connectors entries out again
#
# The agents come from the gateway's agents.json (connectors agent list),
# and each one's "client" says what to wire: {"type": "claude"} for
# ~/.claude.json, or {"type": "claude", "configDir": "~/some/folder"} for
# another Claude config folder; likewise codex (CODEX_HOME), grok
# (GROK_HOME) and muse (its settings folder). Agents without a client are
# skipped. The MCP URL is the gateway's publicUrl plus /mcp.
#
# For each agent it gets a token from the gateway (connectors agent add,
# or rotate if the gateway already has one this machine doesn't) and keeps
# it in a token file under ~\.config\connectors\tokens, restricted to the
# current user with an ACL, never printed. Then:
#   Claude: the mcpServers.connectors entry in .claude.json (the file
#     `claude mcp add-json --scope user connectors` writes) with a
#     headersHelper that reads the token file. PowerShell 5.1 strips the
#     quotes out of a JSON argument on its way to a native command, so the
#     entry is written through scripts/lib/client-config.mjs rather than
#     the claude CLI. Backed up first.
#   Codex: [mcp_servers.connectors] in config.toml with
#     http_headers_helper. Backed up first.
#   Grok: [mcp_servers.connectors] in config.toml with bearer_token_file
#     pointing at the token file. Backed up first.
#   Muse: mcpServers.connectors in settings.json with a literal
#     Authorization header (Muse can't run helpers). Backed up.
# Existing claude.ai connectors and Codex apps are left alone. Codex's and
# Grok's configs are checked with their own CLIs afterwards and put back if
# they don't read. A client that fails doesn't stop the others; the script
# lists what was wired, skipped and failed, and exits 1 if anything failed.
#
# The token files are the Windows answer to the Mac script's Keychain:
# plain text, but the folder's ACL admits only the current user. The
# gateway's own secrets stay in its data folder.
#
# Environment, mostly for testing this script:
#   CONNECTORS_HOME           this machine's data folder (default %APPDATA%\Connectors)
#   CONNECTORS_URL            gateway MCP URL (default: the gateway's publicUrl + /mcp)
#   CONNECTORS_CLI            run this command line instead of the gateway's CLI
#   CONNECTORS_CLIENT_DIR     where headers.cmd and the token files go
#                             (default ~\.config\connectors)
#   CONNECTORS_NODE           node to run scripts/lib/client-config.mjs
#   CODEX_HOME, GROK_HOME     defaults for agents whose client has no configDir
#
# A gateway on another machine (--host) isn't supported on Windows yet;
# install the gateway on this machine, or run the Mac script on a Mac.

param(
  [switch]$DryRun,
  [switch]$Rotate,
  [switch]$Remove,
  [string]$Only,
  [switch]$Help
)

$ErrorActionPreference = 'Continue'

# The repo this script lives in, for scripts/lib/client-config.mjs.
$Repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

$HomeDir = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
$DataDir = if ($env:CONNECTORS_HOME) { $env:CONNECTORS_HOME } else { Join-Path $env:APPDATA 'Connectors' }
$ClientDir = if ($env:CONNECTORS_CLIENT_DIR) { $env:CONNECTORS_CLIENT_DIR } else { Join-Path $HomeDir '.config\connectors' }
$TokenDir = Join-Path $ClientDir 'tokens'
$HeadersCmd = Join-Path $ClientDir 'headers.cmd'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Say([string]$Text) { Write-Output $Text }
function Die([string]$Text) { Write-Output "install-clients: $Text" | Out-Host; exit 1 }

if ($Help) {
  @'
install-clients.ps1: wires the agents on this computer to a PlugBear gateway

  scripts/install-clients.ps1             wire everything that's installed
  scripts/install-clients.ps1 -DryRun     say what would change, change nothing
  scripts/install-clients.ps1 -Rotate     make new tokens for every agent first
  scripts/install-clients.ps1 -Only codex,grok
  scripts/install-clients.ps1 -Remove     take the connectors entries out again

See the top of the script for how it wires each client.
'@ | ForEach-Object { Say $_ }
  exit 0
}

# --- Running commands -----------------------------------------------------------

# Runs a command and returns @{ Status; Stdout; Stderr }. .NET Framework has
# no ProcessStartInfo.ArgumentList, so the argument string is built here
# with the quoting CreateProcess and the C runtime agree on.
function Quote-Argument([string]$Value) {
  if ($Value -notmatch '[\s"]') { return $Value }
  $escaped = $Value -replace '(\\*)"', '$1$1\"'
  $escaped = $escaped -replace '(\\+)$', '$1$1'
  return '"' + $escaped + '"'
}

function Invoke-Run {
  param(
    [string]$FileName,
    [string[]]$CommandArguments = @(),
    [hashtable]$EnvExtra
  )
  $argumentString = ($CommandArguments | ForEach-Object { Quote-Argument $_ }) -join ' '
  return Invoke-Raw -FileName $FileName -ArgumentString $argumentString -EnvExtra $EnvExtra
}

# The one place a process is started: a ready-made argument string, so
# callers can use each program's own quoting rules (cmd's and the C
# runtime's differ).
function Invoke-Raw {
  param(
    [string]$FileName,
    [string]$ArgumentString,
    [hashtable]$EnvExtra
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FileName
  $psi.Arguments = $ArgumentString
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.RedirectStandardInput = $true
  $psi.CreateNoWindow = $true
  if ($EnvExtra) {
    foreach ($key in $EnvExtra.Keys) {
      $psi.EnvironmentVariables[$key] = [string]$EnvExtra[$key]
    }
  }
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi
  [void]$process.Start()
  $process.StandardInput.Close()
  # Read stderr on the side so a chatty process can't fill the pipe and
  # deadlock the stdout read.
  $stderrTask = $process.StandardError.ReadToEndAsync()
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $stderrTask.Result
  $process.WaitForExit()
  return @{ Status = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

# Runs a .cmd or .bat through cmd.exe. The /S form keeps everything
# between the outer quotes, so the inner path can be quoted for its spaces;
# backslash-escaping (the C runtime's " rule) is NOT cmd's rule and breaks
# it, so the argument string is built by hand. The batch file's own
# arguments are joined raw: the script only passes ids and fixed words,
# never anything with a space or a quote in it.
function Invoke-CmdFile {
  param(
    [string]$Path,
    [string[]]$CommandArguments = @(),
    [hashtable]$EnvExtra
  )
  $inner = '"' + $Path + '"'
  if ($CommandArguments.Count -gt 0) { $inner += ' ' + ($CommandArguments -join ' ') }
  $com = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
  $result = Invoke-Raw -FileName $com -ArgumentString ('/d /s /c "' + $inner + '"') -EnvExtra $EnvExtra
  return $result
}

function Test-IsCmd([string]$Path) { return $Path -match '\.(cmd|bat)$' }

function Invoke-CommandPath {
  param([string]$Path, [string[]]$CommandArguments = @(), [hashtable]$EnvExtra)
  if (Test-IsCmd $Path) { return Invoke-CmdFile -Path $Path -CommandArguments $CommandArguments -EnvExtra $EnvExtra }
  return Invoke-Run -FileName $Path -CommandArguments $CommandArguments -EnvExtra $EnvExtra
}

# The gateway's connectors CLI: the CONNECTORS_CLI command line if there is
# one, else the one installed in the data folder.
function Invoke-ConnectorsCli {
  param([string[]]$CliArguments)
  if ($env:CONNECTORS_CLI) {
    $parts = @($env:CONNECTORS_CLI -split ' +' | Where-Object { $_ -ne '' })
    $leading = @()
    if ($parts.Count -gt 1) { $leading = $parts[1..($parts.Count - 1)] }
    return Invoke-CommandPath -Path $parts[0] -CommandArguments ($leading + $CliArguments)
  }
  $cli = Join-Path $DataDir 'bin\connectors.cmd'
  if (-not (Test-Path -LiteralPath $cli)) {
    Die "There's no gateway installed here ($cli). Install it with scripts\install.ps1."
  }
  return Invoke-CmdFile -Path $cli -CommandArguments $CliArguments
}

# node for scripts/lib/client-config.mjs: CONNECTORS_NODE, then PATH, then
# the pinned Node an install put in the data folder.
$Node = $null
if ($env:CONNECTORS_NODE) {
  $Node = $env:CONNECTORS_NODE
} elseif (Get-Command node -ErrorAction SilentlyContinue) {
  $Node = (Get-Command node).Source
} else {
  $pinned = Get-ChildItem -Path (Join-Path $DataDir 'node') -Filter 'node.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($pinned) { $Node = $pinned.FullName }
}
if (-not $Node) { Die "node wasn't found; pass CONNECTORS_NODE, install Node.js, or install the gateway first." }

function Invoke-ConfigHelper {
  param([string[]]$HelperArguments, [hashtable]$EnvExtra)
  return Invoke-Run -FileName $Node -CommandArguments (@((Join-Path $Repo 'scripts\lib\client-config.mjs')) + $HelperArguments) -EnvExtra $EnvExtra
}

# --- Tokens ---------------------------------------------------------------------

function Test-Token([string]$Agent) { return Test-Path -LiteralPath (Join-Path $TokenDir "$Agent.token") }

# Restricts a file or folder to the current user, the Windows equivalent of
# the Mac script's 0600/0700.
function Restrict-Acl([string]$Path) {
  if ($DryRun) { return }
  $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  $grant = if (Test-Path $Path -PathType Container) { "$identity" + ':(OI)(CI)F' } else { "$identity" + ':F' }
  $null = & icacls.exe $Path /inheritance:r /grant:r $grant 2>&1
  if ($LASTEXITCODE -ne 0) {
    Say "  note: couldn't restrict $Path to the current user (icacls exit $LASTEXITCODE)"
  }
}

function Save-Token([string]$Agent, [string]$Token) {
  if ($DryRun) { return }
  New-Item -ItemType Directory -Force -Path $TokenDir | Out-Null
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText((Join-Path $TokenDir "$Agent.token"), $Token, $encoding)
  Restrict-Acl (Join-Path $TokenDir "$Agent.token")
}

function Get-Token([string]$Agent) {
  return ([System.IO.File]::ReadAllText((Join-Path $TokenDir "$Agent.token"))).Trim()
}

function Remove-Token([string]$Agent) {
  $path = Join-Path $TokenDir "$Agent.token"
  if (Test-Path -LiteralPath $path) {
    if ($DryRun) { Say "  would delete $path"; return }
    Remove-Item -LiteralPath $path -Force
    Say "  token: removed (the gateway still has its hash; run 'connectors agent remove $Agent' there)"
  }
}

function Ensure-Token([string]$Agent, [string]$Gateway) {
  if (-not $Rotate -and (Test-Token $Agent)) {
    Say '  token: already there'
    return
  }
  if ($DryRun) {
    Say "  would get a token from $Gateway and keep it in $TokenDir\$Agent.token"
    return
  }
  $token = $null
  if ($Rotate) {
    $rotated = Invoke-ConnectorsCli @('agent', 'rotate', $Agent)
    if ($rotated.Status -eq 0) { $token = $rotated.Stdout.Trim() }
  }
  if (-not $token) {
    $added = Invoke-ConnectorsCli @('agent', 'add', $Agent)
    if ($added.Status -eq 3) {
      Say "  The gateway already has a token for $Agent that this machine doesn't; replacing it"
      $rotated = Invoke-ConnectorsCli @('agent', 'rotate', $Agent)
      if ($rotated.Status -ne 0) { throw "Couldn't get a token for $Agent from $Gateway (exit $($rotated.Status))." }
      $token = $rotated.Stdout.Trim()
    } elseif ($added.Status -ne 0) {
      throw "Couldn't get a token for $Agent from $Gateway (exit $($added.Status))."
    } else {
      $token = $added.Stdout.Trim()
    }
  }
  if ($token -notmatch ("^cn_" + $Agent + "_[0-9a-f]{64}$")) {
    throw "$Gateway didn't send back a token for $Agent."
  }
  Save-Token $Agent $token
  Say '  token: saved'
}

function Write-HeadersHelper([string]$Gateway) {
  if ($DryRun) {
    Say "  would write $HeadersCmd"
    return
  }
  New-Item -ItemType Directory -Force -Path $ClientDir | Out-Null
  $body = @(
    '@echo off',
    'rem Written by connectors scripts/install-clients.ps1. Prints the Authorization',
    'rem header for one PlugBear agent, read from its token file.',
    'setlocal enableextensions',
    'if "%~1"=="" exit /b 2',
    'set "TOKEN_FILE=%~dp0tokens\%~1.token"',
    'if not exist "%TOKEN_FILE%" exit /b 1',
    'set /p TOKEN=<"%TOKEN_FILE%"',
    'echo {"Authorization":"Bearer %TOKEN%"}'
  ) -join "`r`n"
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($HeadersCmd, $body, $encoding)
  Restrict-Acl $ClientDir
}

# --- Config files -----------------------------------------------------------------

function Backup-File([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  if ($DryRun) { Say "  would back up $Path to $Path.bak-connectors-$Stamp"; return }
  Copy-Item -LiteralPath $Path -Destination "$Path.bak-connectors-$Stamp" -Force
  Say "  backup: $Path.bak-connectors-$Stamp"
}

function Restore-Backup([string]$Path) {
  $backup = "$Path.bak-connectors-$Stamp"
  if (Test-Path -LiteralPath $backup) {
    Copy-Item -LiteralPath $backup -Destination $Path -Force
  }
}

# The TOML table body goes through a file, so newlines in it never touch the
# command line.
function Invoke-Toml {
  param([string]$Path, [string]$Mode, [string]$Body)
  $arguments = @('toml', $Path, $Mode)
  $temp = $null
  if ($Mode -eq 'set') {
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) "connectors-toml-$Stamp.body"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temp, $Body, $encoding)
    $arguments += $temp
  }
  try {
    $result = Invoke-ConfigHelper -HelperArguments $arguments
    if ($result.Status -ne 0) { throw ($result.Stderr.Trim()) }
  } finally {
    if ($temp -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Force }
  }
}

function Invoke-ClientJson {
  param([string]$Kind, [string]$Path, [string]$Mode, [hashtable]$EnvExtra)
  $result = Invoke-ConfigHelper -HelperArguments @($Kind, $Path, $Mode) -EnvExtra $EnvExtra
  if ($result.Status -ne 0) { throw ($result.Stderr.Trim()) }
}

# --- Clients ------------------------------------------------------------------------

# Sets the paths for one agent's client from its type and configDir.
function Set-Paths {
  param([string]$Agent, [string]$Type, [string]$Dir)
  $script:ClaudeFile = ''
  $script:CodexConfig = ''
  $script:GrokConfig = ''
  $script:GrokTokenFile = ''
  $script:MuseSettings = ''
  if ($Dir) {
    if ($Dir -eq '~') { $Dir = $HomeDir }
    elseif ($Dir.StartsWith('~/') -or $Dir.StartsWith('~\')) { $Dir = $HomeDir + '\' + $Dir.Substring(2) }
    $Dir = $Dir -replace '/', '\'
  }
  switch ($Type) {
    'claude' { $script:ClaudeFile = if ($Dir) { Join-Path $Dir '.claude.json' } else { Join-Path $HomeDir '.claude.json' } }
    'codex' {
      $root = if ($Dir) { $Dir } elseif ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HomeDir '.codex' }
      $script:CodexConfig = Join-Path $root 'config.toml'
    }
    'grok' {
      $root = if ($Dir) { $Dir } elseif ($env:GROK_HOME) { $env:GROK_HOME } else { Join-Path $HomeDir '.grok' }
      $script:GrokConfig = Join-Path $root 'config.toml'
      $script:GrokTokenFile = Join-Path $TokenDir "$Agent.token"
    }
    'muse' {
      $root = if ($Dir) { $Dir } else { Join-Path $HomeDir '.config\muse' }
      $script:MuseSettings = Join-Path $root 'settings.json'
    }
  }
}

# Prints why an agent's client isn't on this machine, or $null if it is.
function Get-MissingClient {
  param([string]$Agent, [string]$Type)
  switch ($Type) {
    'claude' {
      $claude = Get-Command claude -ErrorAction SilentlyContinue
      $dir = if ($script:ClaudeFile) { Split-Path -Parent $script:ClaudeFile } else { $null }
      if (-not $claude -and -not (Test-Path -LiteralPath $script:ClaudeFile)) { return 'claude isn''t installed' }
      if ($dir -and -not (Test-Path -LiteralPath $dir)) { return "$dir doesn't exist" }
      return $null
    }
    'codex' {
      if (Test-Path -LiteralPath $script:CodexConfig) { return $null }
      return "$($script:CodexConfig) doesn't exist"
    }
    'grok' {
      if ((Get-Command grok -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $script:GrokConfig)) { return $null }
      return 'grok isn''t installed'
    }
    'muse' {
      $dir = Split-Path -Parent $script:MuseSettings
      if ((Test-Path -LiteralPath $dir) -or (Get-Command muse -ErrorAction SilentlyContinue)) { return $null }
      return 'muse isn''t installed'
    }
    '' { return "agents.json gives $Agent no client" }
    default { return "this script doesn't know how to wire a $Type client" }
  }
}

function Find-ClientCommand([string]$Name) {
  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  return $null
}

function Invoke-WireClaude {
  param([string]$Agent)
  $where = if ($script:ClaudeFile) { $script:ClaudeFile } else { Join-Path $HomeDir '.claude.json' }
  if ($Remove) {
    if (-not (Test-Path -LiteralPath $where)) { Say "  nothing to remove from $where"; return }
    Invoke-ClientJson -Kind 'claude' -Path $where -Mode 'remove'
    Say "  removed connectors from Claude in $where"
    return
  }
  $helper = "$HeadersCmd $Agent"
  if ($DryRun) {
    Say "  would set connectors in Claude ($where) with headersHelper $helper"
    return
  }
  Backup-File $where
  Invoke-ClientJson -Kind 'claude' -Path $where -Mode 'set' -EnvExtra @{
    CONNECTORS_URL_VALUE = $script:Url
    CONNECTORS_HEADERS_HELPER_VALUE = $helper
  }
  # If the claude CLI is there, it must still list the server; if not, undo.
  $claude = Find-ClientCommand 'claude'
  if ($claude) {
    $envExtra = @{}
    if ($script:ClaudeFile) { $envExtra['CLAUDE_CONFIG_DIR'] = (Split-Path -Parent $script:ClaudeFile) }
    $seen = Invoke-CommandPath -Path $claude -CommandArguments @('mcp', 'list') -EnvExtra $envExtra
    if ($seen.Stdout -notlike "*$($script:Url)*") {
      Restore-Backup $where
      throw "claude didn't accept the new config, so $where is back as it was."
    }
  } else {
    Say '  note: claude isn''t on PATH, so the new config wasn''t checked with ''claude mcp list'''
  }
  Say "  Claude ($where): connectors added with headersHelper"
}

function Invoke-WireCodex {
  param([string]$Agent)
  Invoke-Toml -Path $script:CodexConfig -Mode 'check'
  # TOML literal strings (single quotes) keep the backslashes in a Windows
  # path as they are.
  $helper = "'$HeadersCmd $Agent'"
  $body = "[mcp_servers.connectors]`r`nurl = ""$($script:Url)""`r`nhttp_headers_helper = $helper`r`n# Calls that wait for approval hold for up to 45 seconds.`r`ntool_timeout_sec = 300`r`n"
  if ($DryRun) {
    if ($Remove) { Say "  would remove [mcp_servers.connectors] from $($script:CodexConfig)" }
    else { Say "  would set in $($script:CodexConfig):"; ($body -split "`r`n") | ForEach-Object { Say "    $_" } }
    return
  }
  Backup-File $script:CodexConfig
  if ($Remove) {
    Invoke-Toml -Path $script:CodexConfig -Mode 'remove'
    Say '  Codex: removed [mcp_servers.connectors]'
    return
  }
  Invoke-Toml -Path $script:CodexConfig -Mode 'set' -Body $body
  # Codex must still read its config, and see the server; if not, undo.
  $codex = Find-ClientCommand 'codex'
  if ($codex) {
    $envExtra = @{ CODEX_HOME = (Split-Path -Parent $script:CodexConfig) }
    $seen = Invoke-CommandPath -Path $codex -CommandArguments @('mcp', 'get', 'connectors', '--json') -EnvExtra $envExtra
    if ($seen.Stdout -notlike "*$($script:Url)*") {
      Restore-Backup $script:CodexConfig
      throw "Codex didn't accept the new config, so $($script:CodexConfig) is back as it was."
    }
  } else {
    Say '  note: codex isn''t on PATH, so the new config wasn''t checked with ''codex mcp get'''
  }
  Say '  Codex: [mcp_servers.connectors] set with http_headers_helper'
}

function Invoke-WireGrok {
  param([string]$Agent)
  if (Test-Path -LiteralPath $script:GrokConfig) { Invoke-Toml -Path $script:GrokConfig -Mode 'check' }
  $body = "[mcp_servers.connectors]`r`nurl = ""$($script:Url)""`r`nbearer_token_file = '$($script:GrokTokenFile)'`r`ntool_timeout_sec = 300`r`n"
  if ($DryRun) {
    if ($Remove) { Say "  would remove [mcp_servers.connectors] from $($script:GrokConfig) and delete $($script:GrokTokenFile)" }
    else {
      Say "  would write $($script:GrokTokenFile) and set in $($script:GrokConfig):"
      ($body -split "`r`n") | ForEach-Object { Say "    $_" }
    }
    return
  }
  Backup-File $script:GrokConfig
  if ($Remove) {
    if (Test-Path -LiteralPath $script:GrokConfig) { Invoke-Toml -Path $script:GrokConfig -Mode 'remove' }
    if (Test-Path -LiteralPath $script:GrokTokenFile) { Remove-Item -LiteralPath $script:GrokTokenFile -Force }
    Say '  Grok: removed [mcp_servers.connectors] and its token file'
    return
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:GrokConfig) | Out-Null
  # Grok reads the file on every request; write it whole.
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($script:GrokTokenFile, (Get-Token $Agent), $encoding)
  Restrict-Acl $script:GrokTokenFile
  Invoke-Toml -Path $script:GrokConfig -Mode 'set' -Body $body
  # Grok must still read its config, and see the server; if not, undo.
  $grok = Find-ClientCommand 'grok'
  if ($grok) {
    $envExtra = @{ GROK_HOME = (Split-Path -Parent $script:GrokConfig) }
    $seen = Invoke-CommandPath -Path $grok -CommandArguments @('mcp', 'list', '--json') -EnvExtra $envExtra
    if ($seen.Stdout -notlike "*$($script:Url)*") {
      if (Test-Path -LiteralPath "$($script:GrokConfig).bak-connectors-$Stamp") { Restore-Backup $script:GrokConfig }
      else { Invoke-Toml -Path $script:GrokConfig -Mode 'remove' }
      throw "Grok didn't accept the new config, so $($script:GrokConfig) is back as it was."
    }
  } else {
    Say '  note: grok isn''t on PATH, so the new config wasn''t checked with ''grok mcp list'''
  }
  Say '  Grok: [mcp_servers.connectors] set with bearer_token_file'
}

function Invoke-WireMuse {
  param([string]$Agent)
  if ($DryRun) {
    if ($Remove) { Say "  would remove mcpServers.connectors from $($script:MuseSettings)" }
    else { Say "  would set mcpServers.connectors in $($script:MuseSettings) (literal header)" }
    return
  }
  Backup-File $script:MuseSettings
  if (Test-Path -LiteralPath "$($script:MuseSettings).bak-connectors-$Stamp") { Restrict-Acl "$($script:MuseSettings).bak-connectors-$Stamp" }
  if ($Remove) {
    if (Test-Path -LiteralPath $script:MuseSettings) {
      Invoke-ClientJson -Kind 'muse' -Path $script:MuseSettings -Mode 'remove'
    }
    Say '  Muse: removed mcpServers.connectors'
    return
  }
  Invoke-ClientJson -Kind 'muse' -Path $script:MuseSettings -Mode 'set' -EnvExtra @{
    CONNECTORS_URL_VALUE = $script:Url
    CONNECTORS_TOKEN_VALUE = (Get-Token $Agent)
  }
  Restrict-Acl $script:MuseSettings
  Say "  Muse: mcpServers.connectors set; $($script:MuseSettings) is user-only"
}

# Refuses a config file the script can't edit before a token is minted for it.
function Invoke-CheckConfig {
  param([string]$Type)
  switch ($Type) {
    'codex' { Invoke-Toml -Path $script:CodexConfig -Mode 'check' }
    'grok' { if (Test-Path -LiteralPath $script:GrokConfig) { Invoke-Toml -Path $script:GrokConfig -Mode 'check' } }
    'muse' { if (Test-Path -LiteralPath $script:MuseSettings) { Invoke-ClientJson -Kind 'muse' -Path $script:MuseSettings -Mode 'check' } }
    'claude' { if (Test-Path -LiteralPath $script:ClaudeFile) { Invoke-ClientJson -Kind 'claude' -Path $script:ClaudeFile -Mode 'check' } }
  }
}

function Test-Wanted([string]$Agent) {
  if (-not $Only) { return $true }
  return (",$Only," -like "*,$Agent,*")
}

# --- Main ---------------------------------------------------------------------------

$Gateway = if ($env:CONNECTORS_CLI) { 'the gateway' } else { "this machine's gateway" }

$agentsResult = Invoke-ConnectorsCli @('agent', 'list', '--json')
if ($agentsResult.Status -ne 0) { Die "Couldn't list the agents on $Gateway." }
$agentsJson = $agentsResult.Stdout | ConvertFrom-Json

if ($env:CONNECTORS_URL) {
  $script:Url = $env:CONNECTORS_URL
} else {
  $settingsResult = Invoke-ConnectorsCli @('settings', '--json')
  if ($settingsResult.Status -ne 0) { Die "Couldn't read the settings on $Gateway." }
  $script:Url = ($settingsResult.Stdout | ConvertFrom-Json).settings.publicUrl + '/mcp'
}

if (-not $Remove) { Write-HeadersHelper $Gateway }

$wired = New-Object System.Collections.Generic.List[string]
$skipped = New-Object System.Collections.Generic.List[string]
$failed = New-Object System.Collections.Generic.List[string]

foreach ($agent in $agentsJson.agents) {
  $id = $agent.id
  $type = ''
  $dir = ''
  if ($agent.client) {
    if ($agent.client.type) { $type = $agent.client.type }
    if ($agent.client.configDir) { $dir = $agent.client.configDir }
  }
  if (-not (Test-Wanted $id)) { continue }
  Say $id
  Set-Paths -Agent $id -Type $type -Dir $dir
  $missing = Get-MissingClient -Agent $id -Type $type
  if ($missing) {
    Say "  skipped: $missing"
    $skipped.Add($id)
    # A token for a client that's gone still comes out of the store.
    if ($Remove) { Remove-Token $id }
    continue
  }
  $ok = $true
  try {
    Invoke-CheckConfig $type
    if (-not $Remove) { Ensure-Token $id $Gateway }
    switch ($type) {
      'claude' { Invoke-WireClaude -Agent $id }
      'codex' { Invoke-WireCodex -Agent $id }
      'grok' { Invoke-WireGrok -Agent $id }
      'muse' { Invoke-WireMuse -Agent $id }
    }
    if ($Remove) { Remove-Token $id }
  } catch {
    $ok = $false
    Say "  FAILED: $($_.Exception.Message)"
  }
  if ($ok) { $wired.Add($id) } else { $failed.Add($id) }
}

Say ''
Say ("Done: " + (($wired -join ' ') -replace '^$', 'none') + ". Skipped: " + (($skipped -join ' ') -replace '^$', 'none') + ". Failed: " + (($failed -join ' ') -replace '^$', 'none') + ".")
if ($DryRun) { Say 'Dry run: nothing changed.' }
if ($failed.Count -gt 0) { exit 1 }
exit 0
