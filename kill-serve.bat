@echo off
REM kill-serve.bat - kill whatever is holding the bun dev server port.
REM Use when `zig build serve` reports "Is port 8000 in use?".

setlocal
set PORT=8000

set "FOUND="
for /f "tokens=5" %%P in ('netstat -ano ^| findstr "LISTENING" ^| findstr ":%PORT%"') do (
    set "FOUND=1"
    echo Killing PID %%P on port %PORT%...
    taskkill /PID %%P /F >nul 2>&1
)

if not defined FOUND echo No process listening on port %PORT%.
endlocal
