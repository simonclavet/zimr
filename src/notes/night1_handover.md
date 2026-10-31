# Night 1 - handover

## The three runs, and what each answers

The recipes are in `examples/geno_lab/recipes/`, one `.zon` each. A run's folder lives outside the repository - what a
run writes is large and is not source - in `C:\dev\geno_runs\`, with the recipe copied in as its `run.zon`.

| recipe | what it is | read against |
|---|---|---|
| `night1_full` | the whole system: the flow actor with its three teachers sharing each update, the planner searching for characters in danger, returns, the time-to-return cost | `night1_improve`: what the flow and the search add |
| `night1_improve` | the Gaussian policy with returns - a character that loses the reference lives on and comes back where the motion has got to | `night1_reproduce`: what returning teaches |
| `night1_reproduce` | SuperMimic's recipe on the minute: an episode ends at a loss | - |

All three: the minute (dance, get-up, walk, run), 32 characters, horizon 32 over the world model's 8, networks 256 wide,
the critic and its tail, the rates' cosine over 8 hours, pushes from hour 1 to full strength at hour 7 (0.5 a second,
up to 3.5 m/s, a quarter of starts in trouble), judged and checkpointed every 30 minutes, until stopped.

## Sharing one machine

One GPU, N logical cores. Each recipe says `.physics_threads = 0` - every core - which is right for ONE run. For three
at once, give each a third of the cores: edit the line to `N / 3` (16 cores: 5) in each run folder's `run.zon`. For two
(full and improve), `N / 2`. The GPU's buffers are about 500 MB a run (256 MB of activations, 64 of their gradients,
five parameter buffers of 32) - 1.5 GB for three.

## Build

```
zig build geno-trainer-windows          -> zig-out\windows\geno_trainer.exe
```

If a run stops at once with `a storage binding of 268435456 bytes; <your GPU> binds at most 134217728`, the GPU's
Vulkan cannot bind the night's 256 MB buffers (most desktop GPUs bind gigabytes; some bind 128 MB). The trainer built
with `-Dtrainer-portable=true` runs on any GPU, but only smaller runs fit it - send the message and the GPU's name.

## Set up the run folders

```
mkdir C:\dev\geno_runs\night1_full C:\dev\geno_runs\night1_improve C:\dev\geno_runs\night1_reproduce
copy examples\geno_lab\recipes\night1_full.zon C:\dev\geno_runs\night1_full\run.zon
copy examples\geno_lab\recipes\night1_improve.zon C:\dev\geno_runs\night1_improve\run.zon
copy examples\geno_lab\recipes\night1_reproduce.zon C:\dev\geno_runs\night1_reproduce\run.zon
```

A folder with no `run.zon` gets one with every default, which is not the night's recipe.

## Start, stop, resume

```
zig-out\windows\geno_trainer.exe --run=C:\dev\geno_runs\night1_full
zig-out\windows\geno_trainer.exe --run=C:\dev\geno_runs\night1_improve
zig-out\windows\geno_trainer.exe --run=C:\dev\geno_runs\night1_reproduce
```

One terminal each. To stop a run: create an empty file `stop` in its folder
(`type nul > C:\dev\geno_runs\night1_full\stop`); it saves and exits within a round. To resume: the same command - it
carries on from the folder's state and log. Exit codes: 0 finished or stopped; 1 the run file refused (the console
names the field); 2 the run failed - the GPU, a file, or the watchdog (something stopped being finite; `status.zon`
names it, and the state saved before it is kept).

## The first ten minutes

At the start each run says:

```
geno_trainer: buffers used - activations 59%, their gradients 74%, parameters 47%      (full; the others less)
geno_trainer: SuperTrack on the minute in C:\dev\geno_runs\night1_full, 32 characters
```

then a line every few seconds: the round, the minutes, the updates, and how often the reference is lost, overall and
per clip. In `log.csv` (a spreadsheet, or the lab):

| column | expect |
|---|---|
| rounds per minute (`round` over `training_minutes`) | write it down - unknown before this machine |
| `acting_ms` against `training_ms` | acting no longer dominating; if it is ten times training or more, note it |
| `windows_refused` | a few in the first rounds, then 0 |
| `nonfinite_actions`, `mirrors_refused` | 0 |
| `planned_step_share` (full) | 0.4 to 0.7 |
| `critic_value_error` | below about 20 |
| `world_gradient_norm` | 15 to 40, spikes on falls (the bound, 50, catches them) |
| `flow_dpg_weight_gradient`, `flow_distill_...`, `flow_fpo_...` (full) | all three moving; FPO's growing with `critic_trust` |
| `push_schedule` | 0 for the first hour |
| `world_updates`, `policy_updates` | rising by 4 and 2 a round (a few policy updates skipped at the start, while the replay is shorter than their windows) |

At the first judgement (30 minutes) each run says "judging and probing took N s" - write it down.

**The training's intensity.** Each file trains the world model 4 times and the policy twice a round. If `training_ms`
stays well below `acting_ms`, the GPU is waiting on the physics and can train more: stop the runs, raise
`.world_updates` (8, then 16) and `.policy_updates` (4) alike in all three `run.zon` files, and start again - a changed file
starts a new run, so delete the old folders' state first. If training takes longer than acting, lower them.

## The first-hour rule, decided now

At one hour - before any push:

- **Continue** when: no run has stopped itself; `status.zon` shows no `collapse`; in `judge.csv` the 60-minute
  judgement of each clip keeps the reference longer than the servo's line of that clip, or longer than at 30 minutes;
  in the full run `planned_step_share` is above 0 and the three teachers' lengths are moving.
- **Stop and send** when a run failed (exit 2): its `status.zon` and the last 50 lines of `log.csv`; or when every
  clip of a run at 60 minutes is below its servo and not rising: that run's `judge.csv` and `log.csv`.

## The morning

- `status.zon`: the state, `collapse`, `nonfinite`.
- `judge.csv`: each clip's time to failure through the night, run against run at the same minutes.
- `recovery.csv`: per clip and push speed - survived, lost, returned, not returned. The night's question is the return
  rate, returned / (returned + not returned), at 2 to 5 m/s: full against improve against reproduce.
- Send the three folders' `status.zon`, `judge.csv`, `recovery.csv` and `log.csv` - not the state files.
