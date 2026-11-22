@echo off
rem THE FIRST NIGHT: ten runs of an hour, one after another, each in its own folder under runs - the control twice,
rem plain SuperTrack, and seven runs each without one part (the last without the root target). A run that crashes,
rem or that a tripwire stops, ends alone and the next one starts. Then the small files of all ten and their policies
rem gathered into night_results.zip, beside this file: unzipped, a runs folder the lab shows as it is.
rem About 11 hours at a full share of the machine, about 22 at a half (MACHINE_SHARE, below): keep the computer from
rem sleeping meanwhile (Settings, System, Power). For a night nobody uses the computer, set the share to 1.
rem Started again after an interruption, every run carries on from its folder: finished ones end at once.
rem Watch the runs as they train with geno_lab.exe, beside this file (README.txt).
setlocal
cd /d "%~dp0"
rem THE MACHINE's SHARE each run takes: 1 runs flat out; 0.5 leaves half the cores and half the GPU's time to the
rem computer's other work, so it stays usable meanwhile, and every run takes about twice as long. A run's clock counts
rem its work, not its rests: its minutes are minutes of training at any share.
set MACHINE_SHARE=0.5
set RUNS=01_control 02_control_seed2 03_plain_supertrack 04_no_teacher 05_no_flow 06_no_model_planner 07_no_skip_head 08_no_critic 09_no_recovery 10_no_root_target
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
if exist results_night rmdir /s /q results_night
for %%R in (%RUNS%) do (
    mkdir results_night\runs\%%R
    for %%F in (run.zon console.txt log.csv judge.csv recovery.csv status.zon time.csv policy) do (
        if exist runs\%%R\%%F copy /y runs\%%R\%%F results_night\runs\%%R\%%F >nul
    )
    if exist runs\%%R\policy_m* copy /y runs\%%R\policy_m* results_night\runs\%%R\ >nul
)
if exist runs\report.txt copy /y runs\report.txt results_night\runs\report.txt >nul
powershell -NoProfile -Command "Compress-Archive -Path results_night\runs -DestinationPath night_results.zip -Force"
echo.
echo Done: the night's results are in night_results.zip, in this folder.
pause
