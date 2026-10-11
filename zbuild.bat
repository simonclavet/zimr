@echo off
REM zimr - `zbuild` from the repo root runs tools\zig-out\bin\zbuild.exe.
REM cmd.exe finds this file by name in the current directory.  PowerShell
REM doesn't search the current directory, so there it is `.\zbuild`, or a
REM `zbuild` function in your $PROFILE.
"%~dp0tools\zig-out\bin\zbuild.exe" %*
exit /b %errorlevel%
