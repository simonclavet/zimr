@echo off
REM release.bat - rebuild prebuilt/, publish it to the orphan `pages` branch.
REM
REM Usage:  release.bat
REM
REM main stays source-only: prebuilt/ is gitignored and never committed to
REM main.  This script builds prebuilt/, then publishes ITS CONTENTS to a
REM single-commit (orphan) `pages` branch and force-pushes it.  Because the
REM branch is rewritten from scratch each run, history never accumulates -
REM the gallery costs one copy on the remote instead of growing main.
REM
REM GitHub Pages serves the `pages` branch (Settings -> Pages -> Deploy from
REM a branch -> `pages`, `/ (root)`) at
REM   https://simonclavet.github.io/zimr/
REM `zig build dist` writes a `.nojekyll` marker into prebuilt/ so Pages
REM serves the files as-is instead of running them through Jekyll.
REM
REM GitHub limits: 100 MB per file (warns above 50 MB), 1 GB per Pages site.
REM
REM Source commits to main are a separate, manual concern - this script does
REM not touch main.  Requires the GitHub remote set up as `origin`
REM (https://github.com/simonclavet/zimr.git).

setlocal enabledelayedexpansion

zig build -Dmode=release dist
if errorlevel 1 (
    echo.
    echo zig build failed - aborting release.
    exit /b 1
)

REM Skip the pages publish if this isn't a git repo yet.
git rev-parse --is-inside-work-tree >nul 2>nul
if errorlevel 1 (
    echo.
    echo prebuilt\ refreshed.  Not a git repo - skipping pages publish.
    echo Initialize git + add the GitHub remote, then re-run.
    exit /b 0
)

if not exist prebuilt\ (
    echo.
    echo prebuilt\ not found after build - aborting.
    exit /b 1
)

echo.
echo Publishing prebuilt\ to the orphan `pages` branch...

REM Build the pages commit off to the side using a throwaway index file, so
REM neither the working tree nor main's index is ever touched.
set "GIT_INDEX_FILE=%TEMP%\zimr-pages.index"
if exist "%GIT_INDEX_FILE%" del "%GIT_INDEX_FILE%"

REM Force past .gitignore - prebuilt/ is ignored on purpose.
git add -f -A -- prebuilt
if errorlevel 1 (
    echo staging prebuilt\ failed - aborting.
    set "GIT_INDEX_FILE="
    exit /b 1
)

REM Write the staged tree, then pull out just the prebuilt/ subtree so its
REM CONTENTS (index.html, wasm, ...) sit at the branch root, not under a
REM prebuilt/ subdir.
for /f "delims=" %%i in ('git write-tree') do set "FULLTREE=%%i"
for /f "delims=" %%i in ('git rev-parse "!FULLTREE!:prebuilt"') do set "PAGESTREE=%%i"

REM Root commit (no -p parent) => orphan branch tip, no history growth.
for /f "delims=" %%i in ('git commit-tree "!PAGESTREE!" -m "Update pages gallery"') do set "PAGESCOMMIT=%%i"

REM Done with the throwaway index.
set "GIT_INDEX_FILE="
if exist "%TEMP%\zimr-pages.index" del "%TEMP%\zimr-pages.index"

REM Force-replace the remote pages branch with our fresh orphan commit.
git push origin "!PAGESCOMMIT!:refs/heads/pages" --force
if errorlevel 1 (
    echo.
    echo pages push failed.  Retry:
    echo     git push origin !PAGESCOMMIT!:refs/heads/pages --force
    exit /b 1
)

echo.
echo Release complete.  pages branch updated (main untouched).
echo Live gallery: https://simonclavet.github.io/zimr/
endlocal
