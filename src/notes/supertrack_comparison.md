# supertrack_comparison.md - SuperTrack: the paper, an unofficial implementation, and ours (Sep 27)

Sources, and how much each is worth:
- **The paper** (Fussell, Bergamin, Holden, SIGGRAPH Asia 2021 - read in full from theorangeduck.com). The authority.
- **`SuperTrack-master`** (an unofficial PyTorch pipeline, 966 lines, uploaded by Simon). Its README warns "there may be
  some errors here", and there are. It has NO physics simulator: the world model is trained on LAFAN1 mocap directly,
  with the clip's own joint rotations (plus the current policy's offsets) standing in for PD targets - so it learns
  kinematics, not physics, and its world-model targets were never produced by its inputs. Worth reading for the
  formulation's shape, not for its choices. Its bugs, so nobody copies them: `local()` forgets to subtract the root's
  position (world position leaks into every feature); angular velocities are `axis_angle(R2 R1^T / dt)` - the matrix
  divided BEFORE the log; the integrator moves position with the OLD velocity (explicit Euler, "because of data");
  the rotation loss is `acos(w * 0.99)`, not the angle; `o_hat * 120` treats alpha = 120 as RADIANS.
- **Ours**: `robot_track` (task, fleet, `local`), `robot_latent` (the CPU SuperTrack), `robot_latent_kit` +
  `robot_track_resident` (the GPU learner, parity-tested against the CPU one), `geno_train` (the phone page).

## Where we already match the paper

- `Local(X)` exactly: positions relative to the root (the repo gets this wrong), two-axis rotations, velocities in the
  root frame, heights, the up vector.
- The policy's inputs: `[Local(P_i), Local(K_{i+1})]` - the character and where the reference goes next.
- Offsets on the kinematic joint rotations for ALL joints; one world step and one policy step an iteration; policy
  windows start on real simulated states from the buffer; the world model learns from the targets ACTUALLY applied.
- The normaliser from kinematic data (F4a, Sep 27 - the paper: "from a database of kinematic data offline").
- Reference-state initialisation with vertical correction (`rest_on_floor`); the policy acts every frame at 60 Hz.

## The differences - paper vs ours, and where each goes

| | paper | ours | plan |
|---|---|---|---|
| failure rule | HEAD height off the reference's by > 25 cm, only after a minimum of 48 frames; max episode 512 (drift variant adds root 1 m / 90 deg) | root 1 m / 90 deg, mean height 0.4, tilt 0.8, mean pose 0.35 m / 1.2 rad; grace = a training window (8) | **F3b** - measured, decided |
| physics rate | 240 Hz, 20 solver iterations (4 steps a frame) | 60 Hz, one step a frame | **F3c** - measured |
| PD target velocities | the reference's joint velocities (PhysX); zero in Havok/Bullet, "reasonably similar" | zero (F3: +1% survival with them) | F3 stands; doc corrected |
| world model form | root-local ACCELERATIONS, to world, semi-implicit integration (velocity first); ablation: beats predicting velocities | latent residual z' = z + Net in normalised features | F9 |
| world model inputs | Local(P) + the targets as applied (rotations incl. offsets, + target velocities) | z + the reference's targets (pre-offset) + the action | F9 (equivalent information; revisit with the form) |
| world model loss | L1 in WORLD space: position, velocity, rotation (log of the quaternion difference), angular velocity; weights tuned to contribute equally at the start; summed over the window | L2 in normalised latent space, averaged | **F4b** |
| policy loss | L1 in LOCAL space per group - position, velocity, rotation (two-axis), angular velocity, height, up - equal contribution at the start; + L2^2 and L1 on o, two orders of magnitude smaller | one L2 over all NORMALISED features (weights each feature by 1 / its variance - fast features count less); L2 on o, 0.01 | **F4b** |
| offsets | t = exp(alpha/2 o) (x) k - LEFT, the parent's frame; alpha = 120 (degrees: 2.09 rad a unit); output unbounded | k (x) exp(a) - RIGHT, the child's frame; 0.6 rad a unit (supertrack_action_scale) | **F4c** (scale); the side is equivalent in expressiveness - noted, not changed |
| exploration noise | sigma = 0.1 in units of o -> 0.21 rad | 0.1 -> 0.06 rad | **F4c** |
| networks | 5 x 1024 ELU, both | 2 hidden tanh; 256 (CPU default) / 64 (phone) | F8 |
| optimiser | RAdam; gradient clipping "helped somewhat" (the repo: 25 world, 100 policy) | Adam, no clipping, constant rates | **F4d** |
| batches, windows | world 2048 x 8, policy 1024 x 32; policy 64 unstable | phone: 16 rows, one window of 8 for both | F8 |
| buffer, gym | ~150k samples; 256 characters; ~5,000 samples/s | phone: 4 characters x 256 steps | F8 / ON's probe |
| learning rates | 1e-3 world, 1e-4 policy | 1e-3 world, 3e-4 policy (kit) | F4d |
| survival metric | episodes CONTINUE past the clip's end at a new random frame, the timer kept - "survival past t seconds" (Dance: > 95% past a minute) | the judge stops at the clip's end | F1c (later, optional) |
| time to results | basic balance ~10^4 iterations (~2 h, GTX 1070); full 1-2 x 10^5 (20-40 h) | - | ON's expectations |

## From the repo, worth taking (not in the paper's text)

- Gradient-clip values: 25 (world model), 100 (policy) - the paper says clipping helped, not by how much.
- A learning-rate warm-up then a polynomial decay - worth having for a 10-hour night.
- Near-zero initial outputs (every Linear N(0, 0.01)): the world model starts as "constant velocity" (zero
  acceleration) - a better trivial prior than our latent model's "nothing changes" - and the policy starts at zero
  offsets.

## From the repo, NOT to take

Its bugs (above); BatchNorm on the inputs (the paper normalises from kinematic data - F4a); the tanh on the policy's
output (not in the paper; our unbounded output + penalties matches the paper); training the world model on mocap.
