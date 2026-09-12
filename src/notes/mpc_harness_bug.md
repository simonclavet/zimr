# The planner loses everywhere — and it is not the problems

## What is now established, each by its own measurement

  1. **The reference is feasible.** Holding the tracking path needs **79 N·m against a 400 N·m
     rating** — five times the margin. The arm can do it easily.
  2. **It is not IK.** A control experiment with a CLOSED-FORM joint reference — a sinusoid per
     joint, no solver, no convergence, nothing that can be wrong — fails exactly the same way.
     That removes the strongest suspect completely.
  3. **`optimize` restores `d`.** The state handoff between planner and simulator is correct.
  4. **`PoseHold` was exceeding its own torque limit** by up to 4x (1589 N·m on a 400 N·m arm).
     Real bug, fixed, suite clean — and every earlier comparison was unfair in the servo's favour
     because of it.
  5. **The weights matter monotonically and never enough**: mean error 0.93 / 1.34 / 1.49 / 1.61
     as the tracking weight goes 0.5 / 2 / 8 / 40. Lower is better, none is competitive with a
     PD's 0.186.

## ★★★ THE TWO ANOMALIES THAT POINT AT THE CALL, NOT THE PROBLEM

**Zero cost progress at steady state:**

    t 0.50  live 2.3991  plan@1 2.3923  cost 5.34e3 -> 5.34e3  it 6  conv false
    t 1.00  live 1.8226  plan@1 1.8185  cost 6.34e3 -> 6.34e3  it 6  conv false

`cost in == cost out`, six iterations, every time. **The line search is rejecting every step on a
feasible problem from a reasonable start.** That is not a cost-shaping symptom; a badly shaped
cost still descends.

**And the plan predicts impossible motion from a perfect start:**

    t 0.00  live 0.0000  plan@1 0.1567

The arm sits exactly on the reference, and the plan's own rollout says it will be 0.157 rad off
after ONE 4 ms step. The reference moves 0.0036 rad in that time and the arm is travelling at
0.9 rad/s. **0.157 rad is forty times more motion than anything in the problem allows.**

★ EITHER `plan.states` is not what I think it is after `optimize` returns — plausibly left from a
rejected line-search trial rather than the accepted rollout — or the rollout genuinely diverges.
**Establish which before anything else**, because one is a harmless reporting quirk and the other
is the whole bug.

## The next moves, in order, and none of them is a weight

  1. **Roll out `plan.ctrl` by hand** after `optimize` returns, stepping a scratch `Data`, and
     compare against `plan.states`. If they disagree, `plan.states` is stale and every reading
     taken from it this session is void.
  2. **Call `backward` directly** on one knot of this problem with hand-checkable numbers, the
     way the LQR gain test does. `optimize` composes linearisation, backward, line search and
     rollout; only a direct call separates them.
  3. **Check `Predicted`** — the backward pass returns an expected improvement. If it predicts a
     large decrease and the line search still rejects, the Jacobians and the rollout disagree,
     which localises the fault to `transition` against `rbt.step` for THIS model.
  4. Only then look at cost scaling.

## ★★ AND THE META-LESSON, WHICH COST MOST OF A SESSION

Three problems, nine formulations, every one explained on its own terms — a destination used as a
reference, a smoothstep with the wrong slope, a horizon that should or should not shrink, a
rank-deficient task cost. **Several of those were real and worth fixing. None of them was the
reason.**

**When the same side loses across unrelated problems while its unit tests pass, the harness is
the suspect and a control experiment is the move.** The closed-form-reference run took twenty
minutes and eliminated more than the previous three turns combined.
