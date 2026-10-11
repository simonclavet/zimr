@echo off
REM kill-serve.bat [port] - kill whatever is listening on the dev server's port.
REM Use when a dev server (`zig build serve` / `serve-only`, tools/serve.zig)
REM from an earlier session still holds it. The port defaults to 8080, the one
REM serve.zig listens on. A new serve uses a running one of the same directory
REM as it is, so this is for one serving another directory, an older serve
REM that does not say what it serves, or any other program on the port.

setlocal
set PORT=8080
if not "%~1"=="" set PORT=%~1

set "FOUND="
for /f "tokens=5" %%P in ('netstat -ano ^| findstr "LISTENING" ^| findstr ":%PORT%"') do (
    set "FOUND=1"
    echo Killing PID %%P on port %PORT%...
    taskkill /PID %%P /F >nul 2>&1
)

if not defined FOUND echo No process listening on port %PORT%.
endlocal
