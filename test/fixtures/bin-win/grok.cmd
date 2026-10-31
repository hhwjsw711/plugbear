@echo off
rem A stand-in for the grok CLI, for install-clients-win.test.ts. `grok mcp
rem list --json` prints the config, so the caller's check that its URL is in
rem there works, unless FAKE_GROK_REJECT is set.
>>"%FAKE_CLIENT_LOG%" echo grok %*
if "%~1"=="mcp" if "%~2"=="list" (
  if defined FAKE_GROK_REJECT (
    echo No MCP servers configured.
    exit /b 0
  )
  if not defined GROK_HOME set "GROK_HOME=%USERPROFILE%\.grok"
  type "%GROK_HOME%\config.toml"
)
exit /b 0
