@echo off
REM install-bun.bat - install bun via the official installer.
REM Bun is required for `zig build serve` (dev hot-reload) and the
REM smoke tests.  Static viewing of prebuilt/ via serve.bat does NOT
REM need bun -- only Python.

where bun >nul 2>nul
if %errorlevel%==0 (
    echo bun already installed:
    bun --version
    exit /b 0
)

echo bun not found.  Installing from https://bun.sh/install.ps1 ...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://bun.sh/install.ps1 | iex"
if errorlevel 1 (
    echo.
    echo Install failed.  See https://bun.sh/docs/installation for manual steps.
    exit /b 1
)

echo.
echo bun installed.  You may need to open a new terminal for PATH to update.
