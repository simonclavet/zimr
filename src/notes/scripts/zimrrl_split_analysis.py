# Classify zimrnum.zig into what moves to zimrrl.zig and what stays, by references, not by position.
#   python3 src/notes/scripts/zimrrl_split_analysis.py      prints the inventory and the counts the split must conserve
import re, sys
SOURCE = "src/zimrnum.zig"
# The public declarations that move: their docs or signatures speak of agents (environments, rewards, returns,
# policies, critics, replays, planners). Borderline names that stay are listed in STAYS with the reason.
MOVES = """CartpoleState CartpoleStep CartpoleTask CartpoleOutcome cartpoleOutcome cartpoleContinuousStep cartpoleStep
cartpole_state_dim cartpoleObserve cartpoleReset cartpoleTaskStep cartpoleTaskReset cartpoleContinuousStepBatch
cartpole_action_dim cartpoleStepBatch
generalizedAdvantage discountedReturns normalizeAdvantages gae explainedVariance
categoricalProject Transition sacTarget dqnTarget DqnKind CriticAggregate aggregateCritics
SquashedGaussian TanhMeanGaussian
OrnsteinUhlenbeck addGaussianActionNoise Temperature policyUpdateDue
ReplayBuffer SequenceReplay RolloutStep RolloutBuffer MinibatchOrder ObsNormalizer
ppoClipSample ppoClipObjective PpoClipLoss PpoConfig PpoStats ppoObjective ppoEpoch PpoModel ppoUpdate
OffPolicyModel offPolicyUpdate
advantageWeights discriminatorReward trackingKernel mixRewards
LatentRollout WorldModelLoss PolicyDistillationLoss LatentPlanScorer LatentPolicyPlans LatentValueTargets Mppi""".split()
STAYS = {  # borderline names that stay in zimrnum, and why
    "CategoricalScalar": "a regression representation (two-hot over symlog bins), not an RL concept",
    "klRobustExpectation": "a statistic", "RunningScale": "a statistic", "gatherColumns": "a tensor operation",
    "klGaussianDiag": "a statistic", "DiagGaussian": "a distribution", "Categorical": "a distribution",
    "categorical": "sampling", "entropyRows": "a statistic",
    "squashCorrection": "the tanh change-of-variables formula; GPU kernels call it",
    "SquashedDraw": "the return type of a Graph operation", "stepParameters": "a plain gradient step",
    "clipGradNorm": "training", "emaUpdate": "training", "linearSchedule": "a schedule", "randomSubset": "sampling",
    "maskedMean": "a reduction",
    "l2NormalizeRows": "a row operation", "dtwDistance": "a sequence distance",
}
lines = open(SOURCE).read().split("\n")
code = [re.sub(r'//.*$', '', l) for l in lines]
top = re.compile(r'^(pub )?(fn|const|var) ([A-Za-z_][A-Za-z0-9_]*)')
test = re.compile(r'^test "([^"]*)"')
units = []  # (kind, name, start, end, is_pub): top-level declarations and test blocks, each with its doc comments
starts = []
for i, line in enumerate(lines):
    m, t = top.match(line), test.match(line)
    if m or t:
        s = i
        while s > 0 and lines[s - 1].startswith("///"):
            s -= 1
        starts.append((s, i, ("decl", m.group(3), bool(m.group(1))) if m else ("test", t.group(1), False)))
for k, (s, i, (kind, name, is_pub)) in enumerate(starts):
    end = starts[k + 1][0] if k + 1 < len(starts) else len(lines)
    units.append((kind, name, s, end, is_pub))
words = lambda u: set(re.findall(r'\b[A-Za-z_][A-Za-z0-9_]*\b', "\n".join(code[u[2]:u[3]])))
decl_units = {u[1]: u for u in units if u[0] == "decl"}
missing = [n for n in MOVES if n not in decl_units]
moved = set(MOVES)
# A test moves when its code uses a moved name; a private helper moves when only moved code uses it.
changed = True
while changed:
    changed = False
    users = {}
    for u in units:
        key = (u[0], u[1], u[2])
        for w in words(u):
            if w in decl_units and w != u[1]:
                users.setdefault(w, set()).add(key)
    moved_keys = {(u[0], u[1], u[2]) for u in units if (u[0] == "decl" and u[1] in moved)}
    moved_keys |= {(u[0], u[1], u[2]) for u in units if u[0] == "test" and words(u) & moved}
    for name, u in decl_units.items():
        if name in moved or u[4] or name in STAYS:
            continue
        who = users.get(name, set())
        if who and who <= moved_keys:
            moved.add(name)
            changed = True
moved_tests = [u for u in units if u[0] == "test" and words(u) & moved]
all_tests = [u for u in units if u[0] == "test"]
moved_private = sorted(n for n in moved if not decl_units[n][4])
moved_lines = sum(u[3] - u[2] for u in units if (u[0] == "decl" and u[1] in moved)) + sum(u[3] - u[2] for u in moved_tests)
# What the moved code needs from zimrnum: the names it uses that stay.
needs = set()
for u in units:
    if (u[0] == "decl" and u[1] in moved) or (u[0] == "test" and words(u) & moved):
        needs |= {w for w in words(u) if w in decl_units and w not in moved}
needs_private = sorted(n for n in needs if not decl_units[n][4])
needs_public = sorted(n for n in needs if decl_units[n][4])
# What stays but would use a moved name: must be empty, or zimrnum would need zimrrl.
blockers = sorted({u[1] for u in units if not ((u[0] == "decl" and u[1] in moved) or (u[0] == "test" and words(u) & moved))
                   and u[0] == "decl" and words(u) & moved})
print(f"public declarations moving: {len(MOVES)} (not found: {missing or 'none'})")
print(f"private helpers moving with them: {len(moved_private)}: {' '.join(moved_private)}")
print(f"tests moving: {len(moved_tests)} of {len(all_tests)}; lines moving: about {moved_lines} of {len(lines)}")
print(f"public zimrnum names the moved code uses (zrl binds them at file scope): {len(needs_public)}")
print(f"PRIVATE zimrnum names the moved code uses (aliases to redeclare, or helpers to make pub): {' '.join(needs_private)}")
print(f"declarations that stay but use a moved name (must be none): {blockers or 'none'}")
if "--names" in sys.argv:
    print("NEEDS_PUBLIC " + " ".join(needs_public))
