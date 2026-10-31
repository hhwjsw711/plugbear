@echo off
rem A stand-in for the codex CLI, for install-clients-win.test.ts. `codex mcp
rem get connectors --json` prints the config, so the caller's check that its
rem URL is in there works, unless FAKE_CODEX_REJECT is set.
>>"%FAKE_CLIENT_LOG%" echo codex %*
if defined FAKE_CODEX_REJECT (
  echo Error: invalid configuration 1>&2
  exit /b 1
)
if not defined CODEX_HOME set "CODEX_HOME=%USERPROFILE%\.codex"
type "%CODEX_HOME%\config.toml"
exit /b 0
