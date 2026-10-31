@echo off
rem A stand-in for the claude CLI, for install-clients-win.test.ts. Records
rem `claude mcp ...` calls and which config folder they were for in
rem FAKE_CLIENT_LOG; `claude mcp list` prints the config file, so the
rem caller's check that its URL is in there works.
if defined CLAUDE_CONFIG_DIR (set "CDIR=%CLAUDE_CONFIG_DIR%") else (set "CDIR=<unset>")
>>"%FAKE_CLIENT_LOG%" echo claude dir=%CDIR% %*
if "%~1"=="mcp" if "%~2"=="list" (
  if defined CLAUDE_CONFIG_DIR (
    type "%CLAUDE_CONFIG_DIR%\.claude.json" 2>nul
  ) else (
    type "%USERPROFILE%\.claude.json" 2>nul
  )
)
exit /b 0
