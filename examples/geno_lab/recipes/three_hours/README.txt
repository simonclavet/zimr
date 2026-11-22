THE THREE HOURS

run_three_hours.bat: eleven runs of 13 minutes, then a profile of 3 minutes, one after another - about 3 hours at
a full share of the machine, about 6 at the half the script sets. Its results: three_hours_results.zip - every run's
files and policies, as a runs folder the lab can show.

THE MACHINE'S SHARE
The script's first setting, MACHINE_SHARE, is the share of the computer each run takes. At 0.5 the trainer runs
below the other programs' priority, its physics on half the cores at most, and it rests the GPU after each piece of
work as long as the work took - the GPU busy half the time - so the computer stays usable for other work. Every run
then takes about twice as long: a run's minutes count its training, not its rests. At 1 it runs flat out.

   1  the control           every part on; phase 2 at the world model's gate, or at 4 minutes at the latest
   2  plain SuperTrack      the world model and the policy through it, nothing else: the bar
   3  the control again     another seed: the noise between two runs of one recipe
   4  phase 2 by the gate   the control with no time bound on phase 1, as the first night's control
   5  no teacher            no planners, labels or phases; the flow and the model planner off with them
   6  no flow               the policy and its noise act; the model planner off with the flow
   7  no model planner
   8  no skip head          the policy imagines 16 single decisions
   9  no critic
  10  no root target
  11  no recovery           no pushes, no starts in trouble, no returns
  12  dispatch times        the control for 3 minutes, every dispatch timed: a profile, compared with no run

Each run is judged once, at its end, against the servo on the same starts. Each run trains in its own folder under
"runs".

WATCHING THE RUNS AS THEY TRAIN
Start geno_lab.exe and pick a run in its list. Its curves are read again every 5 seconds. With "follow the newest
policy" on, the character plays each newer policy as soon as the trainer saves it (every 2 minutes). A click on the
curves plays the policy kept nearest that minute (one every 4 minutes); "reload policy" goes back to the newest.

On the character: press on one of his bodies and drag to pull it (mouse or one finger).
Anywhere else: drag to turn the camera, the wheel or a pinch to zoom.
"reset episodes automatically": on, a fall restarts him; off, he lives on until "reset" or the space bar.

The lab draws on the same GPU as the trainer: close it when you are not watching, so that each run has the GPU as
the others had it.
