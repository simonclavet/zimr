@echo off
rem THE THREE HOURS: eleven runs of 13 minutes, one after another, each in its own folder under runs - the control
rem twice, plain SuperTrack, the control with phase 2 left to the world model's gate, and seven runs each without one
rem part - then a profile of 3 minutes with every dispatch timed. A run that crashes, or that a tripwire stops, ends
rem alone and the next one starts. Then every run's small files and its policies gathered into three_hours_results.zip,
rem beside this file: unzipped, a runs folder the lab shows as it is.
rem About 3 hours at a full share of the machine, about 6 at a half (MACHINE_SHARE, below): keep the computer from
rem sleeping meanwhile (Settings, System, Power).
rem Started again after an interruption, every run carries on from its folder: finished ones end at once.
rem Watch the runs as they train with geno_lab.exe, beside this file (README.txt).
setlocal
cd /d "%~dp0"
rem Vulkan's validation layer, where it is installed, checks every call the trainer makes: off, for speed. The dry run
rem on this machine had it on, and it reported nothing.
set ZIMR_VK_VALIDATE=0
rem THE MACHINE's SHARE each run takes: 1 runs flat out; 0.5 leaves half the cores and half the GPU's time to the
rem computer's other work, so it stays usable meanwhile, and every run takes about twice as long. A run's clock counts
rem its work, not its rests: its minutes are minutes of training at any share.
set MACHINE_SHARE=0.5
set RUNS=01_control 02_plain_supertrack 03_control_seed2 04_phase_two_by_gate 05_no_teacher 06_no_flow 07_no_model_planner 08_no_skip_head 09_no_critic 10_no_root_target 11_no_recovery 12_dispatch_times
for %%R in (%RUNS%) do (
    echo.
    echo === %%R ===
    geno_trainer.exe --run=runs\%%R --machine-share=%MACHINE_SHARE% 2>&1 | powershell -NoProfile -Command "$input | Tee-Object -FilePath runs\%%R\console.txt"
)
echo.
echo === the report: every run against the control ===
geno_trainer.exe --report=runs --control=01_control
echo.
echo === gathering the results ===
if exist results_three_hours rmdir /s /q results_three_hours
for %%R in (%RUNS%) do (
    mkdir results_three_hours\runs\%%R
    for %%F in (run.zon console.txt log.csv judge.csv recovery.csv status.zon time.csv kernel_times.csv policy) do (
        if exist runs\%%R\%%F copy /y runs\%%R\%%F results_three_hours\runs\%%R\%%F >nul
    )
    if exist runs\%%R\policy_m* copy /y runs\%%R\policy_m* results_three_hours\runs\%%R\ >nul
)
if exist runs\report.txt copy /y runs\report.txt results_three_hours\runs\report.txt >nul
powershell -NoProfile -Command "Compress-Archive -Path results_three_hours\runs -DestinationPath three_hours_results.zip -Force"
echo.
echo Done: the results are in three_hours_results.zip, in this folder.
pause
