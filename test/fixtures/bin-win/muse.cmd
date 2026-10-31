@echo off
rem A stand-in for the muse CLI, for install-clients-win.test.ts.
>>"%FAKE_CLIENT_LOG%" echo muse %*
exit /b 0
