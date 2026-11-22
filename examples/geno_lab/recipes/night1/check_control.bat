@echo off
rem THE CHECK BEFORE THE NIGHT: the control alone, 20 minutes on the GPU, judged at 20 against the servo, every
rem dispatch timed. Then its small files and its last policy gathered into check_results.zip, beside this file.
rem About 25 minutes at a full share of the machine, about 50 at a half (MACHINE_SHARE, below). Watch it as it trains
rem with geno_lab.exe, beside this file (README.txt).
setlocal
cd /d "%~dp0"
rem THE MACHINE's SHARE each run takes: 1 runs flat out; 0.5 leaves half the cores and half the GPU's time to the
rem computer's other work, so it stays usable meanwhile, and every run takes about twice as long. A run's clock counts
rem its work, not its rests: its minutes are minutes of training at any share.
set MACHINE_SHARE=0.5
set R=00_check_control
echo.
echo === %R% ===
geno_trainer.exe --run=runs\%R% --machine-share=%MACHINE_SHARE% 2>&1 | powershell -NoProfile -Command "$input | Tee-Object -FilePath runs\%R%\console.txt"
echo.
echo === gathering the results ===
if exist results_check rmdir /s /q results_check
mkdir results_check\runs\%R%
for %%F in (run.zon console.txt log.csv judge.csv recovery.csv status.zon time.csv kernel_times.csv policy) do (
    if exist runs\%R%\%%F copy /y runs\%R%\%%F results_check\runs\%R%\%%F >nul
)
if exist runs\%R%\policy_m* copy /y runs\%R%\policy_m* results_check\runs\%R%\ >nul
powershell -NoProfile -Command "Compress-Archive -Path results_check\runs -DestinationPath check_results.zip -Force"
echo.
echo Done: the check's results are in check_results.zip, in this folder.
pause
