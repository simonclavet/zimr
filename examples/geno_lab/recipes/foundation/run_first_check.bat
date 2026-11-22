@echo off
rem THE FOUNDATION's FIRST CHECK: three runs of 13 minutes, one after another, each in its own folder under runs - the
rem first check, its second seed, and the three hours' run 2 again on today's code. A run that crashes, or that a
rem tripwire stops, ends alone and the next one starts. Then every run's small files and its policies gathered into
rem first_check_results.zip, beside this file. Started again after an interruption, every run carries on from its
rem folder: finished ones end at once. README.txt says what to send back.
setlocal
cd /d "%~dp0"
set ZIMR_VK_VALIDATE=0
set MACHINE_SHARE=0.5
set RUNS=01_first_check 02_first_check_seed2 03_three_hours_run2
rem Each run's folder made from its recipe beside this file, where it is not there yet.
for %%R in (%RUNS%) do (
    if not exist runs\%%R\run.zon (
        mkdir runs\%%R 2>nul
        copy /y %%R.zon runs\%%R\run.zon >nul
    )
)
for %%R in (%RUNS%) do (
    echo.
    echo === %%R ===
    geno_trainer.exe --run=runs\%%R --machine-share=%MACHINE_SHARE% 2>&1 | powershell -NoProfile -Command "$input | Tee-Object -FilePath runs\%%R\console.txt"
)
echo.
echo === the report: every run against the first check ===
geno_trainer.exe --report=runs --control=01_first_check
echo.
echo === gathering the results ===
if exist results_first_check rmdir /s /q results_first_check
for %%R in (%RUNS%) do (
    mkdir results_first_check\runs\%%R
    for %%F in (run.zon console.txt log.csv judge.csv status.zon time.csv policy) do (
        if exist runs\%%R\%%F copy /y runs\%%R\%%F results_first_check\runs\%%R\%%F >nul
    )
    if exist runs\%%R\policy_m* copy /y runs\%%R\policy_m* results_first_check\runs\%%R\ >nul
)
if exist runs\report.txt copy /y runs\report.txt results_first_check\runs\report.txt >nul
powershell -NoProfile -Command "Compress-Archive -Path results_first_check\runs -DestinationPath first_check_results.zip -Force"
echo.
echo Done: the results are in first_check_results.zip, in this folder.
pause
