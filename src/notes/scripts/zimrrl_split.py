#!/usr/bin/env python3
# Move zimrnum's reinforcement-learning code into zimrrl.zig.
#
#   python3 src/notes/scripts/zimrrl_split.py --dry-run DIR    write the new zimrnum.zig and zimrrl.zig into DIR
#   python3 src/notes/scripts/zimrrl_split.py --apply          rewrite src/zimrnum.zig and src/zimrrl.zig
#
# A UNIT is a top-level declaration or test block together with the comment lines directly above it. Which units move
# is decided by references: the public declarations in MOVES (zimrrl_split_analysis.py), every private helper whose
# code uses a moved name or that only moved code uses, and every test whose code uses a moved name. Identifiers are read from code only - strings,
# comments and field accesses (`x.name`) are skipped. Every invariant is checked before anything is written; a failure
# exits non-zero and writes nothing.
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
ZIMRNUM = os.path.join(ROOT, "src/zimrnum.zig")
ZIMRRL = os.path.join(ROOT, "src/zimrrl.zig")

# ---- What moves, and the counts the analysis measured for it ----

analysis = open(os.path.join(ROOT, "src/notes/scripts/zimrrl_split_analysis.py")).read()
MOVES = re.search(r'MOVES = """(.*?)"""', analysis, re.S).group(1).split()
EXPECTED_PUBLIC, EXPECTED_PRIVATE, EXPECTED_TESTS = 61, 30, 95

# Each moved public declaration's layer in zimrrl. A layer uses only the layers above it, and zimrnum.
LAYERS = [
    ("R01", "ENVIRONMENTS", """CartpoleState CartpoleStep CartpoleTask CartpoleOutcome cartpoleOutcome cartpoleContinuousStep
        cartpoleStep cartpole_state_dim cartpoleObserve cartpoleReset cartpoleTaskStep cartpoleTaskReset
        cartpoleContinuousStepBatch cartpole_action_dim cartpoleStepBatch"""),
    ("R02", "REPLAY", "Transition ReplayBuffer SequenceReplay MinibatchOrder ObsNormalizer"),
    ("R03", "ROLLOUTS, RETURNS AND ADVANTAGES", """RolloutStep generalizedAdvantage discountedReturns normalizeAdvantages
        gae explainedVariance RolloutBuffer"""),
    ("R04", "POLICY DISTRIBUTIONS AND EXPLORATION", """SquashedGaussian TanhMeanGaussian OrnsteinUhlenbeck
        addGaussianActionNoise Temperature policyUpdateDue"""),
    ("R05", "VALUE TARGETS", "categoricalProject sacTarget dqnTarget DqnKind CriticAggregate aggregateCritics"),
    ("R06", "PPO", "ppoClipSample ppoClipObjective PpoClipLoss PpoConfig PpoStats ppoObjective ppoEpoch PpoModel ppoUpdate"),
    ("R07", "OFF-POLICY TRAINING", "OffPolicyModel offPolicyUpdate"),
    ("R08", "IMITATION AND REWARDS", "advantageWeights discriminatorReward trackingKernel mixRewards"),
    ("R09", "WORLD MODELS", "LatentRollout WorldModelLoss PolicyDistillationLoss"),
    ("R10", "PLANNING", "LatentPlanScorer LatentPolicyPlans LatentValueTargets Mppi"),
]
LAYER_OF = {name: index for index, (_, _, names) in enumerate(LAYERS) for name in names.split()}

# A private test helper that both libraries' tests use: zimrrl gets its own copy rather than widening zimrnum's API.
COPIED = {"ownedTensor"}
# A private helper both libraries' code uses: it becomes public in zimrnum, and zimrrl aliases it.
PUBLISHED = {"addPointMassToGrid"}
# zimrnum's scalar alias for zm's clamp; zimrrl uses the canonical spelling.
RENAMED = {"scalarClamp": "clamp"}
# Locals named with a zm keyword, renamed in zimrrl: zimrnum's header lets its code shadow those words, zimrrl's does
# not. Keyed by the start of the test's name; the new name must not already appear in the test.
LOCAL_RENAMES = {
    "zn SequenceReplay: a window is consecutive steps of ONE environment": {"length": "window_length"},
    "zn SequenceReplay: finished is 0 up to and including the first done": {"length": "window_length"},
}
# Members that become public because the other library now reaches them: Zig lets a file read a type's private
# members only from inside that file. (unit, the member's declaration line before, after)
PUBLIC_IN_ZIMRNUM = [("DiagGaussian", "        const half_log_tau: T = ", "        pub const half_log_tau: T = ")]
PUBLIC_IN_ZIMRRL = [("PpoClipEval", "    fn loss(self: @This(), t: Tensor(f64)) Error!f64 {",
                     "    pub fn loss(self: @This(), t: Tensor(f64)) Error!f64 {")]
# The shape statistics left in zimrnum's L13 after the move; they join L08 STATISTICS.
STATISTICS = ["standardisedMoment", "skew", "kurtosis", "geoMean", "harmMean", "histogram"]

linter = open(os.path.join(ROOT, "tools/zimrlint.zig")).read()
keywords_block = linter[linter.index("const keywords = std.StaticStringMap(void).initComptime(.{"):]
keywords_block = keywords_block[:keywords_block.index("});")]
KEYWORDS = set(re.findall(r'\.\{ "([A-Za-z0-9_]+)", \{\} \}', keywords_block))


def fail(message):
    print("zimrrl_split: " + message)
    sys.exit(1)


# ---- Lines, split into code, strings and comments ----

def segments(line):
    """The line as (kind, text) pieces, kind one of code / string / comment."""
    if line.lstrip().startswith("\\\\"):
        return [("string", line)]
    pieces, i, start = [], 0, 0
    while i < len(line):
        c = line[i]
        if c == "/" and line.startswith("//", i):
            pieces.append(("code", line[start:i]))
            pieces.append(("comment", line[i:]))
            return pieces
        if c in "\"'":
            pieces.append(("code", line[start:i]))
            j = i + 1
            while j < len(line) and line[j] != c:
                j += 2 if line[j] == "\\" else 1
            pieces.append(("string", line[i:j + 1]))
            i = start = j + 1
            continue
        i += 1
    pieces.append(("code", line[start:]))
    return pieces


IDENTIFIER = re.compile(r'(?<![.\w@])([A-Za-z_][A-Za-z0-9_]*)\b')


def identifiers(lines):
    found = set()
    for line in lines:
        for kind, text in segments(line):
            if kind == "code":
                found.update(IDENTIFIER.findall(text))
    return found


def rewrite(lines, mapping):
    """Replace identifiers per `mapping` (name -> replacement) in code only."""
    out = []
    for line in lines:
        pieces = []
        for kind, text in segments(line):
            if kind == "code":
                text = IDENTIFIER.sub(lambda m: mapping.get(m.group(1), m.group(1)), text)
            pieces.append(text)
        out.append("".join(pieces))
    return out


# ---- Units ----

TOP = re.compile(r'^(?:pub )?(?:const|fn|var) ([A-Za-z_][A-Za-z0-9_]*)|^test "([^"]*)"|^comptime \{')


def parse_units(lines):
    """Top-level declarations and tests, each with its leading comment lines, as dicts in source order."""
    units = []
    i = 0
    while i < len(lines):
        m = TOP.match(lines[i])
        if not m:
            i += 1
            continue
        start = i
        while start > 0 and lines[start - 1].startswith("//") and not lines[start - 1].startswith("//!"):
            start -= 1
        end = i
        if not lines[i].rstrip().endswith(";"):
            end = i + 1
            while not (lines[end] and not lines[end][0].isspace() and not lines[end].startswith("//")
                       and (lines[end].rstrip().endswith(";") or lines[end].rstrip() in ("}", "};"))):
                end += 1
        kind = "test" if m.group(2) is not None else ("comptime" if m.group(1) is None else "decl")
        name = m.group(2) if kind == "test" else m.group(1)
        units.append({"kind": kind, "name": name, "start": start, "head": i, "end": end,
                      "public": lines[i].startswith("pub "), "lines": lines[start:end + 1],
                      "uses": identifiers(lines[i:end + 1])})
        i = end + 1
    return units


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("--dry-run", "--apply"):
        fail("usage: --dry-run DIR | --apply")
    original = open(ZIMRNUM).read().split("\n")
    units = parse_units(original)
    decls = {u["name"]: u for u in units if u["kind"] == "decl"}
    if any(name not in decls for name in MOVES):
        fail(f"not found in zimrnum: {[n for n in MOVES if n not in decls]}")
    if set(LAYER_OF) != set(MOVES):
        fail(f"layer table and MOVES differ: {sorted(set(LAYER_OF) ^ set(MOVES))}")

    # What moves: MOVES, the private helpers only moved code uses, and the tests that use a moved name.
    moved = set(MOVES)
    while True:
        moved_tests = {id(u) for u in units if u["kind"] == "test" and u["uses"] & moved}
        users = {}
        for u in units:
            for name in u["uses"]:
                if name in decls and name != u["name"]:
                    users.setdefault(name, []).append(u)
        grown = False
        for name, u in decls.items():
            if name in moved or u["public"] or name in COPIED or name in PUBLISHED:
                continue
            # A private helper moves when its own code uses a moved name (zimrnum cannot refer to zimrrl), or when
            # only moved code uses it. The first rule is what breaks the cycle between a fixture and its tests.
            who = users.get(name, [])
            uses_moved = bool(u["uses"] & moved)
            only_moved_users = bool(who) and all((w["kind"] == "decl" and w["name"] in moved) or id(w) in moved_tests
                                                 for w in who)
            if uses_moved or only_moved_users:
                moved.add(name)
                grown = True
        if not grown:
            break
    tests = [u for u in units if u["kind"] == "test" and u["uses"] & moved]
    private = sorted(n for n in moved if not decls[n]["public"])
    if (len(MOVES), len(private), len(tests)) != (EXPECTED_PUBLIC, EXPECTED_PRIVATE, EXPECTED_TESTS):
        fail(f"counts differ from the analysis: {len(MOVES)} public, {len(private)} private, {len(tests)} tests")

    moving = [u for u in units if (u["kind"] == "decl" and u["name"] in moved) or u in tests]
    moving_ids = {id(u) for u in moving}
    staying = [u for u in units if id(u) not in moving_ids]
    blocked = sorted({u["name"] for u in staying if u["kind"] != "test" and u["uses"] & moved})
    if blocked:
        fail(f"staying code uses a moved name: {blocked}")

    # ---- zimrrl: the names it needs from zimrnum ----
    zn_public = {n for n, u in decls.items() if u["public"]} - moved
    used = set().union(*(u["uses"] for u in moving)) - moved
    qualified = sorted((used & zn_public) & KEYWORDS)             # written zn.exp(...): zm keeps the bare name
    aliased = sorted((used & zn_public) - KEYWORDS) + sorted(used & PUBLISHED)
    private_aliases = sorted(n for n in used & set(decls) if not decls[n]["public"] and n not in COPIED
                             and n not in PUBLISHED and n not in ("zimrnum",))
    unknown = [n for n in private_aliases if not decls[n]["lines"][-1].rstrip().endswith(";")]
    if unknown:
        fail(f"private names that are not one-line aliases: {unknown}")

    mapping = {name: "zn." + name for name in qualified}
    mapping["zimrnum"] = "zn"
    mapping.update(RENAMED)

    # ---- zimrrl: layers in order, private helpers beside their first user, tests last ----
    def layer_of_unit(u):
        if u["kind"] == "test":
            return len(LAYERS)
        if u["name"] in LAYER_OF:
            return LAYER_OF[u["name"]]
        first_users = [w for w in moving if u["name"] in w["uses"] and w is not u]
        layers = [layer_of_unit(w) for w in first_users if w["kind"] == "decl" and w["name"] in LAYER_OF]
        return min(layers) if layers else len(LAYERS)
    # Within a layer, a unit goes after the units it uses (source order otherwise), so nothing is used above its
    # declaration.
    placed = []
    for layer in range(len(LAYERS) + 1):
        pending = sorted((u for u in moving if layer_of_unit(u) == layer), key=lambda u: u["start"])
        while pending:
            names_pending = {u["name"] for u in pending if u["kind"] == "decl"}
            ready = next((u for u in pending if not ((u["uses"] - {u["name"]}) & names_pending)), None)
            if ready is None:
                fail("a cycle within layer " + str(layer) + ": " + ", ".join(sorted(names_pending))[:300])
            placed.append(ready)
            pending.remove(ready)
    position = {u["name"]: k for k, u in enumerate(placed) if u["kind"] == "decl"}
    order_errors = []
    for k, u in enumerate(placed):
        if u["kind"] == "test":
            continue
        for name in u["uses"] & moved:
            if name != u["name"] and position.get(name, -1) > k:
                order_errors.append(f"{u['name']} uses {name}, placed after it")
    if order_errors:
        fail("layer order: " + "; ".join(order_errors))

    copied_units = [decls[n] for n in sorted(COPIED) if n in used]
    # A moved one-line std / zm alias (only moved code used it) joins the other aliases rather than a layer.
    moved_aliases = [u for u in moving if u["kind"] == "decl" and not u["public"] and len(u["lines"]) == 1
                     and re.match(r'const [A-Za-z_][A-Za-z0-9_]* = (std|zm)\.[A-Za-z0-9_.]+;$', u["lines"][0])]
    placed = [u for u in placed if u not in moved_aliases]
    header_end = next(i for i, line in enumerate(open(ZIMRRL).read().split("\n")) if not line.startswith("//!"))
    facade_header = open(ZIMRRL).read().split("\n")[:header_end]
    facade_header = [line for line in facade_header if "Until the code moves here" not in line]
    while facade_header[-1] == "//!":
        facade_header.pop()
    out = facade_header + [
        "//!",
        "//! Thirteen reinforcement-learning kernels still live in zimrnum's src/gpu/zn_mlp.zig: a trainer dispatches",
        "//! them through one pipeline together with its generic kernels, and they import nothing from zrl.",
        "//!",
        "//! ---- LAYERS ----",
        "//!",
        "//! Each layer uses only the layers above it, and zimrnum:",
    ] + [f"//!   {code}  {title}" for code, title, _ in LAYERS] + [
        "//!   then the tests.",
        "//!",
        '//! Import it as `const zrl = @import("zrl");`.',
        "",
    ]
    out += [decls[n]["lines"][-1] for n in ("std", "zm") if n in decls] + ['const zn = @import("zn");', ""]
    out += [decls[n]["lines"][-1] for n in private_aliases if n not in ("std", "zm") and n not in RENAMED]
    out += ["const clamp = zm.clamp;"] if "scalarClamp" in used else []
    out += [u["lines"][0] for u in moved_aliases]
    out += [""] + [f"const {n} = zn.{n};" for n in aliased] + [""]
    for unit in copied_units:
        out += rewrite(unit["lines"], mapping) + [""]
    current = None
    for u in placed:
        layer = layer_of_unit(u)
        if layer != current:
            current = layer
            code, title = (LAYERS[layer][0], LAYERS[layer][1]) if layer < len(LAYERS) else ("", "TESTS")
            banner = f"// {code}  {title}" if code else f"// {title}"
            out += ["// " + "=" * 77, banner, "// " + "=" * 77, ""]
        unit_mapping = dict(mapping)
        for prefix, renames in LOCAL_RENAMES.items():
            if u["kind"] == "test" and u["name"].startswith(prefix):
                taken = identifiers(u["lines"]) & set(renames.values())
                if taken:
                    fail(f"rename target already used in {u['name'][:60]}: {sorted(taken)}")
                unit_mapping.update(renames)
        unit_lines = rewrite(u["lines"], unit_mapping)
        for unit_name, before, after_line in PUBLIC_IN_ZIMRRL:
            if u["name"] == unit_name:
                hits = [k for k, line in enumerate(unit_lines) if line.startswith(before)]
                if len(hits) != 1:
                    fail(f"{unit_name}: expected one `{before.strip()}`")
                unit_lines[hits[0]] = after_line + unit_lines[hits[0]][len(before):]
        out += unit_lines + [""]

    # ---- zimrnum: the moved units removed, the statistics into L08, the shared helper published ----
    keep = [True] * len(original)
    for u in moving:
        for i in range(u["start"], u["end"] + 1):
            keep[i] = False
    remaining = [line for i, line in enumerate(original) if keep[i]]
    moved_line_count = sum(u["end"] - u["start"] + 1 for u in moving)
    if moved_line_count + len(remaining) != len(original):
        fail("line accounting does not add up")
    after = remaining
    stats = parse_units(after)
    stat_units = [u for u in stats if u["kind"] == "decl" and u["name"] in STATISTICS]
    if len(stat_units) != len(STATISTICS):
        fail(f"statistics not found: {set(STATISTICS) - {u['name'] for u in stat_units}}")
    stat_lines = []
    drop = set()
    for u in stat_units:
        stat_lines += after[u["start"]:u["end"] + 1] + [""]
        drop.update(range(u["start"], u["end"] + 1))
    after = [line for i, line in enumerate(after) if i not in drop]
    l13 = after.index("// L13  REINFORCEMENT LEARNING")
    del after[l13 - 1:l13 + 2]
    l09 = after.index("// L09  LINEAR ALGEBRA")
    after[l09 - 1:l09 - 1] = stat_lines
    for name in PUBLISHED:
        i = next(k for k, line in enumerate(after) if line.startswith(f"fn {name}("))
        after[i] = "pub " + after[i]
    for unit_name, before, after_line in PUBLIC_IN_ZIMRNUM:
        hits = [k for k, line in enumerate(after) if line.startswith(before)]
        if len(hits) != 1:
            fail(f"{unit_name}: expected one `{before.strip()}`")
        after[hits[0]] = after_line + after[hits[0]][len(before):]

    # ---- Invariants over the results ----
    zn_units, zrl_units = parse_units(after), parse_units(out)
    before_public = {u["name"] for u in units if u["kind"] == "decl" and u["public"]}
    zn_public_after = {u["name"] for u in zn_units if u["kind"] == "decl" and u["public"]}
    zrl_public_after = {u["name"] for u in zrl_units if u["kind"] == "decl" and u["public"]}
    if zn_public_after & zrl_public_after:
        fail(f"public in both: {sorted(zn_public_after & zrl_public_after)}")
    if before_public | PUBLISHED != zn_public_after | zrl_public_after:
        fail(f"public names not conserved: {sorted((before_public | PUBLISHED) ^ (zn_public_after | zrl_public_after))}")
    before_tests = sorted(u["name"] for u in units if u["kind"] == "test")
    after_tests = sorted([u["name"] for u in zn_units if u["kind"] == "test"] +
                         [u["name"] for u in zrl_units if u["kind"] == "test"])
    if before_tests != after_tests:
        fail("test names not conserved")
    zn_tests = sum(1 for u in zn_units if u["kind"] == "test")
    leftovers = sorted(set().union(*(u["uses"] for u in zn_units)) & moved)
    if leftovers:
        fail(f"zimrnum still uses moved names: {leftovers}")

    print(f"moving: {len(MOVES)} public, {len(private)} private, {len(tests)} tests, {moved_line_count} lines")
    print(f"zimrnum after: {len(after)} lines, {len(zn_public_after)} public, {zn_tests} tests")
    print(f"zimrrl: {len(out)} lines, {len(zrl_public_after)} public, {len(tests)} tests")
    print(f"zimrrl binds {len(aliased)} zimrnum names, qualifies {len(qualified)} ({' '.join(qualified)}),"
          f" copies {len(private_aliases)} aliases and {len(copied_units)} helper(s)")
    if sys.argv[1] == "--dry-run":
        target = sys.argv[2]
        os.makedirs(target, exist_ok=True)
        open(os.path.join(target, "zimrnum.zig"), "w").write("\n".join(after))
        open(os.path.join(target, "zimrrl.zig"), "w").write("\n".join(out))
        print(f"dry run written to {target}")
    else:
        open(ZIMRNUM, "w").write("\n".join(after))
        open(ZIMRRL, "w").write("\n".join(out))
        print("applied to src/zimrnum.zig and src/zimrrl.zig")


main()
