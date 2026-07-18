@echo off
REM generate_vscode.bat - regenerate the script-driven editor files.
REM
REM zig build gen-vscode fully overwrites all FOUR files from
REM build.zig's `const wgpu_examples = ...`:
REM   .vscode\launch.json  .vscode\tasks.json
REM   .zed\debug.json      .zed\tasks.json
REM One Chrome debug config + a build task + a standalone task per wgpu
REM demo (.vscode\extensions.json stays hand-maintained).
REM
REM Run after adding/removing a row in `const wgpu_examples`, then commit
REM the regenerated files.

zig build gen-vscode
if errorlevel 1 exit /b 1
