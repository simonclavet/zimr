@echo off
REM release.bat - rebuild prebuilt/, push main, then update Codeberg Pages.
REM
REM Usage:  release.bat ["commit message"]
REM
REM Steps:
REM   1. zig build -Dmode=release dist  (refreshes prebuilt/)
REM   2. git add prebuilt/ && commit + push to main (only if prebuilt/
REM      changed)
REM   3. git subtree split prebuilt/ -^> origin/pages (force-with-lease)
REM      Codeberg serves the contents of the `pages` branch as the
REM      live gallery at https://simonclavet.codeberg.page/Zimr/.
REM
REM If the working tree isn't a git repo yet, step 1 still runs and
REM the rest is skipped with a note.  Set up the Codeberg remote first,
REM then re-run.

setlocal enabledelayedexpansion

zig build -Dmode=release dist
if errorlevel 1 (
    echo.
    echo zig build failed - aborting release.
    exit /b 1
)

REM Skip git steps if not a git repo yet.
git rev-parse --is-inside-work-tree >nul 2>nul
if errorlevel 1 (
    echo.
    echo prebuilt\ refreshed.  Not a git repo - skipping commit/push.
    echo Initialize git + add the Codeberg remote, then re-run.
    exit /b 0
)

git add prebuilt/

REM Skip the main commit/push if prebuilt/ didn't change, but still
REM update the pages branch (no-op if already in sync; corrective if
REM not).
git diff --cached --quiet
set "PREBUILT_CHANGED=1"
if not errorlevel 1 set "PREBUILT_CHANGED=0"

if "!PREBUILT_CHANGED!"=="1" (
    set "MSG=%~1"
    if "!MSG!"=="" set "MSG=Refresh prebuilt gallery"

    git commit -m "!MSG!"
    if errorlevel 1 exit /b 1

    git push
    if errorlevel 1 (
        echo.
        echo main push failed - aborting before pages update.
        exit /b 1
    )
) else (
    echo.
    echo prebuilt\ unchanged - skipping main commit/push.
)

REM Update Codeberg Pages: subtree-split prebuilt/'s contents to a
REM throwaway local branch, then force-push to origin/pages.
REM force-with-lease so we don't clobber a concurrent update from
REM another machine.
echo.
echo Updating pages branch...
git branch -D pages-update >nul 2>&1
git subtree split --prefix prebuilt main -b pages-update
if errorlevel 1 (
    echo subtree split failed - main is pushed but pages is stale.
    exit /b 1
)
git push origin pages-update:pages --force-with-lease
if errorlevel 1 (
    echo.
    echo pages push failed.  pages-update branch is still local; retry:
    echo     git push origin pages-update:pages --force-with-lease
    exit /b 1
)
git branch -D pages-update >nul 2>&1

echo.
echo Release complete.  main + pages branch both updated.
echo Live gallery: https://simonclavet.codeberg.page/Zimr/
endlocal
