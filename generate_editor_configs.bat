@echo off
REM generate_editor_configs.bat - regenerate the VS Code and Zed editor files.
REM
REM zig build editor-configs fully overwrites all FOUR files, for every app
REM with a web build (build.zig's `wgpu_apps` table and the launcher):
REM   .vscode\launch.json  .vscode\tasks.json
REM   .zed\debug.json      .zed\tasks.json
REM One Chrome debug config + a build task + a release task per app
REM (.vscode\extensions.json stays hand-maintained).
REM
REM Run after adding/removing a row in `wgpu_apps`, then commit the
REM regenerated files. `zig build check` fails until you do.

zig build editor-configs
if errorlevel 1 exit /b 1
