# Installs PlugBear: builds it, sets up the data folder, its config and
# its scheduled task (scripts/deploy.ps1), wires the agents on this
# computer (scripts/install-clients.ps1) and opens the admin page. Running
# it again updates the gateway and leaves your config alone.
# Windows port of scripts/install.sh; this machine only, local mode or
# tailscale mode.
#
#   scripts/install.ps1                    local mode
#   scripts/install.ps1 -Tailscale         published on your tailnet
#
# Options:
#   -AdminLogin LOGIN  tailscale mode: the Tailscale login allowed on the
#                      admin pages (default: the one signed in here)
#   -PublicUrl URL     tailscale mode: https://<machine>.<tailnet>.ts.net:8443
#                      (default: read from Tailscale)
#   -Owner NAME        what agents call you ("Waiting for Sam to approve this")
#   -NoClients         don't wire the agents on this computer
#   -NoOpen            don't open the admin page at the end
#
# Needs Windows 10 or later and Node.js with npm to build (any recent
# version; the gateway runs on the Node that ops/node.json pins, which the
# deploy downloads and checks).

param(
  [switch]$Tailscale,
  [string]$AdminLogin,
  [string]$PublicUrl,
  [string]$Owner,
  [switch]$NoClients,
  [switch]$NoOpen,
  [switch]$Help
)

$ErrorActionPreference = 'Continue'

$Repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$HomeBin = Join-Path $env:USERPROFILE '.local\bin'

if ($Help) {
  @'
install.ps1: installs PlugBear on this computer

  scripts/install.ps1                    local mode
  scripts/install.ps1 -Tailscale         published on your tailnet

Options:
  -AdminLogin LOGIN  tailscale mode: the Tailscale login allowed on the
                     admin pages (default: the one signed in here)
  -PublicUrl URL     tailscale mode: https://<machine>.<tailnet>.ts.net:8443
  -Owner NAME        what agents call you ("Waiting for Sam to approve this")
  -NoClients         don't wire the agents on this computer
  -NoOpen            don't open the admin page at the end
'@ | ForEach-Object { Write-Output $_ }
  exit 0
}

function Say([string]$Text) { Write-Output "==> $Text" }

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Output "install: Install Node.js (with npm) first, for example from https://nodejs.org. It's only used to build." | Out-Host
  exit 1
}

Say 'Installing the gateway on this computer'
# Splatted by name: an array splat binds positionally, and the switch names
# would land in -Mode and -AdminLogin as strings instead.
$deployArguments = @{ SkipChecks = $true; AllowDirty = $true }
if ($Tailscale) { $deployArguments['Mode'] = 'tailscale' }
if ($AdminLogin) { $deployArguments['AdminLogin'] = $AdminLogin }
if ($PublicUrl) { $deployArguments['PublicUrl'] = $PublicUrl }
if ($Owner) { $deployArguments['Owner'] = $Owner }
& (Join-Path $Repo 'scripts\deploy.ps1') @deployArguments
if ($LASTEXITCODE -ne 0) {
  Write-Output "install: the deploy failed, so the agents weren't wired." | Out-Host
  exit 1
}

# `connectors open` is how a browser signs in to the admin pages, so put the
# command where a shell finds it.
$Data = if ($env:CONNECTORS_HOME) { $env:CONNECTORS_HOME } else { Join-Path $env:APPDATA 'Connectors' }
Say 'Putting the connectors command on PATH'
New-Item -ItemType Directory -Force -Path $HomeBin | Out-Null
$wrapper = Join-Path $HomeBin 'connectors.cmd'
$body = @(
  '@echo off',
  'rem Written by connectors scripts/install.ps1. Runs the gateway''s own',
  'rem wrapper, so it always means the data folder it was installed with.',
  ('"' + (Join-Path $Data 'bin\connectors.cmd') + '" %*')
) -join "`r`n"
[System.IO.File]::WriteAllText($wrapper, $body, (New-Object System.Text.UTF8Encoding($false)))
if ($env:Path.ToLower().Split(';') -notcontains $HomeBin.ToLower()) {
  Write-Output "Add $HomeBin to your PATH to run 'connectors' by name, or run $wrapper."
}

if (-not $NoClients) {
  Say 'Wiring the agents on this computer'
  & (Join-Path $Repo 'scripts\install-clients.ps1')
  if ($LASTEXITCODE -ne 0) {
    Write-Output 'Some agents weren''t wired; see above. Fix it and run scripts\install-clients.ps1 again.'
  }
}

if (-not $NoOpen) {
  Say 'Opening the admin page'
  & (Join-Path $Data 'bin\connectors.cmd') open /admin
}

Say 'Done. Press Connect for each service on the admin page; your agents see its tools from their next session.'
