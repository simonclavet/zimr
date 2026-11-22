# The first run - handover

## The run

One recipe, `examples/geno_lab/recipes/first_run.zon`: the system as built, every part on, on the device.

- 1,024 characters of Geno simulated on the GPU, each with a stiffness per limb in its action.
- The minute (dance, get-up, walk, run) and its variants: mirrored, and both sides at 0.8 and 1.2 of their speed -
  24 clips.
- The teacher: 32 planners (the first 32 characters, one or more per clip), 16 candidates each, a replan every 8
  decisions over a plan of 8 - 512 candidate worlds beside the characters, 1,536 worlds in all.
- The two phases: the teacher's labels alone for at most 10 minutes (sooner if the world model's gate passes twice),
  then the world model's rollouts ramped in over 3 minutes, a tenth of the policy's updates kept on the labels.
- The critic on lambda-returns at 0.5 and on imagined rollouts; its value tail ramped in over 1,000 updates.
- Pushes from the first minute (0.5 a second per character), their top opening to 5 m/s at hour 6 and braked while
  fewer than 0.6 of the pushes near it are come back from; returns after a loss (5 s to come back).
- The policy judged, probed and saved as its slow average (0.995).
- Judged and checkpointed every 30 minutes, until stopped; every dispatch timed (`kernel_times.csv`).

## Build

```
zig build geno-trainer-windows          -> zig-out\windows\geno_trainer.exe
```

The desktop trainer's simulator holds 5,090 worlds of Geno; the run needs 1,536. If it stops at once with
`a storage binding of ... bytes; <your GPU> binds at most ...`, send the message and the GPU's name.

## Set up the run folder

```
mkdir C:\dev\geno_runs\first_run
copy examples\geno_lab\recipes\first_run.zon C:\dev\geno_runs\first_run\run.zon
```

A folder with no `run.zon` gets one with every default, which is not this run.

## Start, stop, resume

```
zig-out\windows\geno_trainer.exe --run=C:\dev\geno_runs\first_run
```

To stop: create an empty file `stop` in the folder (`type nul > C:\dev\geno_runs\first_run\stop`); it saves and
exits within a round. To resume: the same command. Exit codes: 0 finished or stopped; 1 the run file refused (the
console names the field); 2 the run failed - the GPU, a file, or the watchdog (`status.zon` names it, and the state
saved before it is kept).

## The first ten minutes

At the start the trainer says how full its buffers are, the device's envelope, the worlds simulated (1,536) and the
teacher's line (32 planners, 512 candidates, a replan every 8 decisions over 8). Write down the first two lines. The
activations are expected about 80% full (the replay of 64 decisions per character is most of them); if the trainer
refuses the run for its buffers, halve `.replay_steps` and send the line.

`time.csv`, read first, for itself - every round, each line:

| check | expect |
|---|---|
| `gpu_busy_ms` <= `gpu_span_ms` <= `wall_ms` | always |
| `untimed_dispatches` | 0 |
| each phase's `_segments` | steady from round to round |
| `wall_ms` over 16 | the decision's time: the estimate is about 193 ms - write it down |
| `replans_gpu_ms` against `acting_gpu_ms` + `physics_gpu_ms` | the teacher's share of a decision |
| `gpu_idle_share` | the device waiting for the host - write it down |

`log.csv`:

| column | expect |
|---|---|
| rounds per minute (`round` over `training_minutes`) | write it down |
| `acting_ms` against `training_ms` | acting well above training; if training is under a tenth of acting, the updates can be raised (below) |
| `label_share` | 1 in phase 1; falling to 0.1 over 3 minutes once phase 2 starts (by minute 10 at the latest) |
| `gate_passes` | 0 at first; 2 opens phase 2 before its bound |
| `device.gate_world_error` over `device.gate_no_change_error` | falling; under 0.25 passes |
| `labels_kept`, `lookaheads` | rising from the first replans |
| `windows_refused` | a few in the first rounds, then 0 |
| `nonfinite_actions`, `mirrors_refused` | 0 |
| `critic_value_error` | finite and falling |
| `world_gradient_norm` | spikes on falls, bounded at 50 |
| `push_top_speed` | rising slowly from 0.5 m/s |

**The training's intensity.** The recipe trains the world model 32 times and the policy 16 times a round (16
decisions). If `training_ms` stays well below `acting_ms`, the device is busy with the physics and can train more:
stop the run, raise `.world_updates` and `.policy_updates` alike (64 and 32), delete the folder's state, start again.
If training takes longer than acting, lower them.

At the first judgement (30 minutes) the trainer says "judging and probing took N s" - write it down.

## The first-hour rule, decided now

- **Continue** when: the run has not stopped itself; `status.zon` shows no `collapse`; phase 2 started (`label_share`
  below 1); in `judge.csv` the 60-minute judgement of each clip keeps the reference longer than the servo's line of
  that clip, or longer than at 30 minutes.
- **Stop and send** when the run failed (exit 2): its `status.zon` and the last 50 lines of `log.csv` and
  `time.csv`; or when every clip at 60 minutes is below its servo and not rising: `judge.csv`, `log.csv`, `time.csv`.

## The morning

- `status.zon`: the state, `collapse`, `nonfinite`, and the success: `success_round` and `success_active_minutes` -
  the first judgement at which every clip was completed whole and the mean normalised return reached 0.82.
- `judge.csv`: each clip's time to failure through the night; each clip's `<clip>/whole` line is SuperMimic's
  evaluation (the whole clip from its first frame), with the tracking quality beside it.
- `recovery.csv`: per clip and push speed - survived, lost, returned, not returned, and how a return moves (its
  action's rate of change and the root's jerk).
- Send `status.zon`, `judge.csv`, `recovery.csv`, `log.csv`, `time.csv` and `kernel_times.csv` - not the state files.
