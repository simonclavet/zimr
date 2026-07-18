# `spv2wgsl` — Simplification Opportunities

Concrete, code-grounded suggestions for making the transpiler smaller and
easier to understand, ranked by value-for-effort. Each says *what*, *why*,
*how*, and *risk*. None of these are urgent — the code is in good shape
(149/181 fixtures, naga-gated). These are about reducing the cognitive
load for the next reader.

The codebase is **8,263 lines** across the spv2wgsl files, and the single
biggest fact about it is:

> **`spv2wgsl.zig` (3,021 lines) and `walker.zig` (1,434 lines) are ~54%
> of the code, and a large chunk of both is the *legacy walker path* that
> is scheduled for deletion ("F5").**

So the highest-leverage simplification isn't a refactor — it's *finishing
the migration so the legacy path can be deleted.* Everything else is
secondary. Suggestions are ordered with that in mind.

---

## Tier 1 — Biggest wins

### 1.1 Finish F5: delete the legacy walker

**What:** Once naga-debt is 0 and the 32 fallbacks are either translated
or confirmed legitimately-unstructured, delete `walker.zig` (1,434 lines),
the `WalkerChoice` enum, the `.ir_or_legacy`/`.legacy` modes, the
`-Dwalker` build option, the `phi_assigns_ref`/`StopSet` machinery in
`spv2wgsl.zig`, and `tools/zglsl.zig`.

**Why:** This is by far the largest simplification available — it removes
~1,400+ lines outright and collapses every "which walker?" fork in
`spv2wgsl.zig` (71 references to walker/legacy/choice today). A reader no
longer has to hold two control-flow-reconstruction strategies in their
head. The IR path becomes *the* path.

**How:** It's gated work, not a single edit — keep clearing fallbacks
until the IR walker handles everything reachable, then delete. The naga
gate already tells you when you're safe.

**Risk:** None if sequenced correctly (the gates catch any shape the IR
walker can't handle). This is the planned endgame, already documented.

---

### 1.2 Replace the two hand-written operand classifiers with one table

**What:** `appendValueOperands` (156 lines) and `bodyResultId` both encode
"what do this opcode's operands mean?" — one for *uses*, one for *defs*.
They're two big `switch`es over the same opcode space, and they must be
kept consistent by hand.

**Why:** 156 lines of `switch` arms is the single densest "you just have
to know SPIR-V" spot in the new code, and having the def-side and use-side
knowledge in *two separate functions* invites drift (add an opcode to one,
forget the other). The tutorial had to explain this carefully precisely
because it's the least self-evident code.

**How:** Introduce one small table keyed by opcode that records the two
facts we actually need:

```zig
const OpShape = struct {
    /// Does this op define a hoistable value result? (result at ops[1].)
    has_value_result: bool = false,
    /// Operand index where <id> value-refs begin, or null if this op
    /// needs custom handling (literals interleaved: Switch, ExtInst, …).
    value_operands_from: ?u8 = null,
};

fn opShape(op: Op) OpShape {
    return switch (op) {
        .IAdd, .FAdd, .ISub, /* … the 63 "all ids from [2]" ops … */
            => .{ .has_value_result = true, .value_operands_from = 2 },
        .Store           => .{ .value_operands_from = 0 },  // no result
        .BranchConditional, .Switch, .ReturnValue
                         => .{ .value_operands_from = 0 },  // first operand only (custom-trimmed)
        .CompositeExtract, .VectorShuffle, .ExtInst, .FunctionCall
                         => .{ .has_value_result = true, .value_operands_from = null }, // custom
        // terminators / merges / labels / decls: all-default (none)
        else             => .{},
    };
}
```

Then `appendValueOperands` becomes: look up the shape; if
`value_operands_from` is set and not custom, loop from there; else
fall to the handful of genuinely-custom cases (Switch/ExtInst/Shuffle/etc.
— maybe 5 arms). And `bodyResultId` becomes a one-liner: `return if
(opShape(op).has_value_result and ops.len >= 2) ops[1] else null;`.

This roughly halves the operand-classification code and puts the def/use
facts **in one place**, so they can't drift.

**Risk:** Low-medium. It's behavior-preserving and well-covered by the
naga gate (any misclassification → a fixture goes invalid → gate fails).
Do it as a pure refactor *after* a clean snapshot, verify naga-tint
unchanged.

---

## Tier 2 — Real clarity gains, contained

### 2.1 Collapse `Enclosing`'s three fields into the construct's params

**What:** `ir_emit.zig` threads an `Enclosing` struct with three parallel
fields (`if_results`, `loop_results`, `switch_results`) through every emit
function, and each construct rebuilds it:

```zig
const inner = .{ .if_results = f.results, .loop_results = enc.loop_results,
                 .switch_results = enc.switch_results };
```

**Why:** Three near-identical fields + the "rebuild but keep the other
two" boilerplate at every construct is repetitive and easy to get subtly
wrong (swap a field, carry the wrong one through). A reader has to track
three slots that all mean the same kind of thing.

**How:** A terminator already knows which *kind* of construct it exits
(`exit_if`/`exit_loop`/`exit_switch`). So the emitter only needs, at the
point it emits a terminator, the params of the **nearest enclosing
construct of each kind**. That's genuinely three things — but they can be
modeled as a small stack of `(kind, params)` pushed as we descend, instead
of a 3-field struct rebuilt by hand. Or, simpler: since exit terminators
are matched to the nearest enclosing construct anyway, store a pointer to
the nearest enclosing `If`/`Loop`/`Switch` and read `.results` from it —
one field per kind, but no manual "carry the other two" rebuild (just push
the new innermost). The rebuild boilerplate disappears.

**Risk:** Low. Pure emitter-internal change; the IR emit unit tests +
naga gate cover it.

### 2.2 Split `spv2wgsl.zig` (3,021 lines) along its natural seams

**What:** `spv2wgsl.zig` mixes several concerns in one file: the State
type + id table, type emission, instruction emission, entry-point/IO
emission, the hoisting analysis, and the walker-choice glue.

**Why:** 3,000 lines in one file is a lot to navigate, and the concerns
are quite separable. After F5 (1.1) removes the walker glue, the natural
seams are obvious:

- `spv2wgsl/types.zig` already exists for opcode enums — type *emission*
  (`emitTypeStruct`, `emitTypeVector`, …) could join a `type_emit.zig`.
- `value_emit.zig` — the per-instruction emitters (`emitBinOp`,
  `emitFunctionCall`, the `bindLhs` family).
- `io_emit.zig` — entry signatures, `@builtin`/`@location`, inputs/outputs.
- `hoist.zig` — `markHoistedResults` + the operand classifier (esp. after
  1.2 makes it a tidy table).

**Why not yet:** Do this *after* F5, because the walker deletion will
already churn this file heavily — splitting first means re-splitting after.

**Risk:** Low (mechanical moves), but only worth it post-F5 to avoid
double work.

### 2.3 Make the hoist analysis a small named struct, not loose arrays

**What:** Hoisting currently lives as two parallel arrays on `State`
(`hoisted: []bool`, `hoist_type: []u32`) plus a method. The two-pass
algorithm allocates two more local arrays (`def_block`, `def_type`).

**Why:** Four parallel id-indexed arrays is the kind of thing that's
correct but hard to *read* — the reader has to remember which array means
what and that they're co-indexed. A named struct documents intent.

**How:**

```zig
const HoistInfo = struct {
    needs_var: bool = false,
    type_id: u32 = 0,
};
// one `[]HoistInfo` instead of two parallel arrays;
// def-side likewise a single `[]struct { block: u32, type_id: u32 }`.
```

**Risk:** Trivial. Local to the hoist code.

---

## Tier 3 — Small polish

### 3.1 Name the "magic" SPIR-V opcode numbers once

Several places compare raw opcode numbers (`245`=Phi, `248`=Label, …) or
have them only in comments. `types.zig` already has the `Op` enum — make
sure every site uses `@intFromEnum(Op.Phi)` rather than a bare `245`, so
nobody has to cross-reference a comment. (Mostly done; worth a grep sweep.)

### 3.2 The `StopStack` fixed cap of 32 could be a named constant

`items: [32]Stop` — the 32 is a "deeper than any real shader" guard. A
named `const max_construct_nesting = 32;` with the rationale next to it
reads better than a bare literal in a struct field.

### 3.3 Unify the "empty exit block" construction

`buildBranch`, `buildCaseTarget`, and a couple of other spots all build "a
block whose only content is an empty exit terminator." A tiny helper
`emptyExitBlock(arena, kind)` would remove a few copies of the same 3-line
pattern.

---

## What NOT to change

A few things look like they *could* be simplified but shouldn't:

- **Keeping values as raw `u32` ids instead of parsed value objects.**
  This looks "stringly-typed," but it's a deliberate, load-bearing choice:
  it avoids a second parallel value representation and matches how the
  text emitter already resolves ids. Introducing a `Value` type would
  *add* code, not remove it.
- **The IR modeling only control flow, not instruction bodies.** Tempting
  to "complete" the IR to cover instructions too — but that would pull the
  large, working text emitter into the new model for no correctness gain.
  The scoping is the reason the IR is only ~500 lines.
- **The `validate` pass.** It's "extra" code that never runs in
  production logic, but it's what makes the original phi-dropping bug
  *unrepresentable*. Keep it.
- **The naga gate's baseline file.** It looks like test cruft, but it's
  the mechanism that forces "handled = naga-valid." Keep it.

---

## Suggested order

1. Keep clearing fallbacks toward **F5** (1.1) — the deletion is the big
   prize, and it makes 2.2 worthwhile.
2. Once snapshotted clean, do the **operand-table refactor** (1.2) — it's
   the densest remaining new code and the table is satisfying.
3. Then the **emitter `Enclosing` cleanup** (2.1) and **hoist struct**
   (2.3) — small, local, immediate readability.
4. After F5, **split `spv2wgsl.zig`** (2.2) along its seams.
5. Tier 3 polish whenever touching those areas.
