@echo --------------------- off
REM zimr — launch a local web server for the prebuilt examples.
REM
REM Requires Python 3 (built into Windows 10+ via the Microsoft Store
REM if not installed manually).  No build step needed — the wasm files
REM and gallery page are already in `prebuilt/`.

setlocal

REM Need a prebuilt\ directory to serve.  Generate it via release.bat
REM (or `zig build -Drelease=true dist`) if it's missing.
if not exist "%~dp0prebuilt" (
    echo.
    echo prebuilt\ not found.  Run release.bat first to generate it,
    echo or `zig build -Drelease=true dist` if you don't want to push.
    echo.
    pause
    exit /b 1
)

REM Pick whichever Python is on PATH.  py.exe is the launcher
REM that ships with Python on Windows; falls back to python.exe.
where py >nul 2>nul
if %errorlevel%==0 (
    set "PY=py -3"
) else (
    where python >nul 2>nul
    if %errorlevel%==0 (
        set "PY=python"
    ) else (
        echo.
        echo Python 3 not found on PATH.  Install Python from python.org
        echo or the Microsoft Store, then re-run this script.
        echo.
        pause
        exit /b 1
    )
)

set PORT=8000

echo.
echo zimr examples gallery
echo
echo  Serving prebuilt\ on http://localhost:%PORT%/
echo  Press Ctrl+C to stop.
echo.

REM Open the browser — gives the user something to click.  The server
REM launches a moment later, so the page might briefly show
REM "connection refused"; one refresh sorts it out.
start "" "http://localhost:%PORT%/"

cd /d "%~dp0prebuilt"
%PY% -m http.server %PORT%
