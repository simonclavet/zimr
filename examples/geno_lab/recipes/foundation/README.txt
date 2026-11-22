THE FOUNDATION's FIRST CHECK

run_first_check.bat: three runs of 13 minutes, one after another - about 40 minutes at a full share of the machine,
about 80 at the half the script sets. Its results: first_check_results.zip - every run's files and policies, as a
runs folder the lab can show.

   1  the first check        plain SuperTrack's objective and action on the foundation's world model, data and
                             iteration (robotgpu_plan.md 1 and 4, S1 to S3)
   2  its second seed        the same recipe, seed 2: the noise between two runs of one recipe
   3  the three hours' run 2 the same recipe as then, on today's code: what the iteration, the warm-up and the rates
                             change, read against 1 and 2

WHAT TO SEND BACK
first_check_results.zip. In it, for each run: log.csv (one line a round: the world model's loss in its own units,
`world_loss` and `world_loss_last_step`, beside the clips' `world_model_loss`; the share of its updates the bound
clipped; the policy's rate multiplier), status.zon, console.txt (its first lines are the trainer's start check of its
kernels, and the buffers it uses). The first runs warm up for 256 decisions first: "warming up" on the console, no
update until it ends.

THE PASS, read from log.csv: the world model's loss in its units falling at BlinkMimic's pace by iteration - about
0.75 at iteration 100 and 0.41 at iteration 200, in kind - and the training's episodes never shorter than the servo's
after iteration 100. An iteration is a round that trains, the warm-up's left out: log.csv's `world_updates` divided
by the recipe's 10 world updates a round.

THE FILES: this folder's three recipes beside geno_trainer.exe (and geno_lab.exe, to watch); the script makes each
run's folder under runs from its recipe the first time.

BEFORE THE RUNS
geno_trainer.exe --run=runs\01_first_check --layout says whether the recipe fits this build's buffers - the
activations, their gradients, the parameters and the replay's ring - without training. A refusal names the buffer.

THE MACHINE'S SHARE, and watching the runs as they train: as the three hours' README says.
