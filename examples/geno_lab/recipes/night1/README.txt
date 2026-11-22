THE FIRST NIGHT

1. check_control.bat: the control alone for 20 minutes, about 25 with its judgement.
   Its results: check_results.zip.
2. run_night.bat: the night's ten runs, an hour each, about 11 hours.
   Its results: night_results.zip.

Each script's first setting, MACHINE_SHARE, is the share of the computer each run takes: at 0.5, the scripts' own,
the trainer leaves half the cores and half the GPU's time to other work, and every run takes about twice as long -
its minutes count training, not rests. Set it to 1 for a night nobody uses the computer.

Each run trains in its own folder under "runs".

WATCHING THE RUNS AS THEY TRAIN
Start geno_lab.exe and pick a run in its list. Its curves are read again every 5 seconds. With "follow the newest
policy" on, the character plays each newer policy as soon as the trainer saves it (every 5 minutes). A click on the
curves plays the policy kept nearest that minute (one every 10 minutes); "reload policy" goes back to the newest.

On the character: press on one of his bodies and drag to pull it (mouse or one finger).
Anywhere else: drag to turn the camera, the wheel or a pinch to zoom.
"reset episodes automatically": on, a fall restarts him; off, he lives on until "reset" or the space bar.

The lab draws on the same GPU as the trainer: close it when you are not watching, so that each run of the night
has the GPU as the others had it.
