# How `spv2wgsl` Works — A Tutorial

This is a from-scratch explanation of the `spv2wgsl` transpiler: the part
of zimr that turns compiled shader bytecode (**SPIR-V**) into shader
source text (**WGSL**) that a browser's WebGPU engine can run. It assumes
only a little compiler background. We'll build the mental model first,
then read the actual code.

---

## 1. The 30-second picture

You write a shader once, in Zig. The Zig compiler turns it into **SPIR-V**
— a binary instruction format. The browser's WebGPU API doesn't accept
SPIR-V; it accepts **WGSL** — a text language that looks like Rust. So we
need a translator:

```
your shader (Zig)
      │  zig build-obj -target spirv …
      ▼
   SPIR-V  (binary: a flat list of numbered instructions)
      │  spv2wgsl  ◄── this is what the tutorial is about
      ▼
   WGSL  (text: source code the browser compiles)
      │  browser's Tint (Chrome) / naga (Firefox)
      ▼
   GPU machine code
```

The crucial design rule of `spv2wgsl`: **we do not validate or optimize.**
We produce WGSL and *feed it* to the browser's own validator (Tint in
Chrome, naga in Firefox). So our only job is: emit WGSL that is
**correct and accepted**. We test that with `naga` as an oracle.

---

## 2. The hard part: SPIR-V is "flat", WGSL is "nested"

This is the entire challenge in one idea, so it's worth dwelling on.

### SPIR-V is a flat graph (a CFG)

SPIR-V has no `if`/`while`/`for`. It has **basic blocks** (straight runs
of instructions) connected by **branches**. A block ends with exactly one
"terminator": an unconditional branch, a conditional branch, a switch, or
a return. This is called a **control-flow graph** (CFG).

Here's `if (cond) { a } else { b }` in SPIR-V form (simplified, using
`%N` for instruction ids):

```
%entry:
    OpSelectionMerge %merge       ; "the two branches rejoin at %merge"
    OpBranchConditional %cond %then %else
%then:
    ... a ...
    OpBranch %merge
%else:
    ... b ...
    OpBranch %merge
%merge:
    ... rest ...
```

It's a graph: four nodes, edges between them. There is **no nesting** —
`%then` and `%else` are just blocks sitting at the top level, same as
`%merge`. The only hint that this is an "if" is the `OpSelectionMerge`
annotation saying "these branches reconverge at `%merge`."

### WGSL is a tree

WGSL is normal structured code:

```wgsl
if (cond) {
    // a
} else {
    // b
}
// rest
```

The `then` and `else` bodies are **nested inside** the `if`. The "rest"
is **after** it. It's a tree, not a graph.

**So the core job of `spv2wgsl` is: reconstruct the tree from the graph.**
Take a flat list of blocks-with-branches and figure out "this branch and
that branch are the two arms of an if, and this block is what comes after
the if." This is called **structuring** or **control-flow
reconstruction**, and it's the heart of the transpiler.

### Why is this even possible?

Because the shader compiler emits *structured* SPIR-V: every conditional
branch comes with an `OpSelectionMerge`, every loop with an
`OpLoopMerge`. Those annotations tell us where each construct ends. We're
not reverse-engineering arbitrary spaghetti — we're reading a graph that
secretly *is* a tree and was flattened, and we put it back. (Truly
unstructured graphs — `goto`-like jumps — can't always be turned back
into a tree; even Tint rejects some. We fall back to a different path for
those. More on that at the end.)

---

## 3. The second hard part: phi nodes (SSA)

SPIR-V is in **SSA form** — "Static Single Assignment." The rule: every
variable is assigned **exactly once.** This is great for optimizers but
awkward for a language with normal mutable variables.

The problem: what if a value depends on *which branch ran*? In normal
code:

```wgsl
var x: i32;
if (cond) { x = 1; } else { x = 2; }
// use x
```

`x` is assigned twice — illegal in SSA. SSA's answer is the **phi node**
(`OpPhi`), which means "pick a value based on which block we came from":

```
%merge:
    %x = OpPhi  %1 %then   %2 %else
         ;       ^value ^from-block   ^value ^from-block
    ; "x is %1 if we arrived from %then, %2 if from %else"
```

Read it as: *"`%x` is `%1` when control reached here from `%then`, and
`%2` when it reached here from `%else`."*

WGSL has no phi. So we must turn each phi back into a mutable variable.
**This is the single most important design decision in our transpiler,
and it's where we deliberately differ from Tint.**

---

## 4. Tint vs. us: two ways to kill a phi

We studied Google's **Tint** (Chrome's SPIR-V→WGSL reader) closely. Both
Tint and we reconstruct the tree the same way (we'll see the shared
"walk-stop" trick below). But we handle phi/SSA **differently**, and
understanding why makes everything else click.

### Tint's way: stay in SSA, propagate values through "block parameters"

Tint keeps SSA all the way through its internal IR. To get a phi value out
of an `if`, Tint makes the value an **operand on the exit edges** of the
construct (like a function returning a value), and the merge "receives" it
as a result. When a value is defined deep inside nested constructs and
needed outside, Tint **propagates** it outward, threading it through every
level's exit (Tint calls this `Propagate`). It's elegant but involved:
values flow up through the construct tree as parameters.

### Our way: hoist the phi to one mutable `var`

We don't keep SSA. We turn each phi into a single mutable variable
declared once at the top of the function, and we *assign* it on the
right edges:

```wgsl
fn main() {
    var phi_x: i32;          // ← declared once, at function scope
    if (cond) {
        phi_x = 1;           // ← assigned on the "then" exit edge
    } else {
        phi_x = 2;           // ← assigned on the "else" exit edge
    }
    // use phi_x            // ← readable anywhere; it's a function-scope var
}
```

Because `phi_x` is a function-scope `var`, **it's readable from any later
block automatically.** We never need Tint's multi-level propagation: a
`var` doesn't care how deeply nested the place that assigns it is.

This is the recurring theme of the whole codebase:

> **We borrow Tint's *structure-finding logic* but not its *value model*.
> Tint threads SSA values through the tree; we assign mutable vars at the
> edges. Same questions ("which exit edge does this value belong to?"),
> simpler answers.**

We confirmed this is sound by running the scary-named fixtures
(`Phi_Propagated`, `PropagatedPhiValue`, …) through `spirv-cross` (another
reference translator): they *also* lower to plain mutable vars. The names
describe Tint's internal SSA mechanism, not a shape that requires SSA.

---

## 5. The pipeline, file by file

The transpiler is split into three concerns, plus an integration layer:

| File | Job | Knows about |
|------|-----|-------------|
| `ir.zig` | The **data model** for the reconstructed tree + a validator | only `std` |
| `ir_build.zig` | **SPIR-V → tree** (the structurer) | SPIR-V |
| `ir_emit.zig` | **tree → WGSL text** | WGSL |
| `spv2wgsl.zig` | glue + **value-level emission** (the actual instructions) | both |

A subtle and clever scoping choice: **`ir.zig` only models control flow,
not the straight-line instructions.** A block's body (the actual
`a = b + c` math) is *not* in the IR tree — the tree just holds a SPIR-V
block id and says "emit this block's instructions here." The
instruction-by-instruction emission stays in `spv2wgsl.zig`'s older,
working text emitter. The IR only solves the part that was hard: the
control-flow shape and the phis. This keeps the new code small.

Let's look at each.

---

## 6. `ir.zig` — the tree's shape

The whole tree is made of a few types. Here are the important ones (real
code):

```zig
/// A value is referenced by its SPIR-V result id throughout.
pub const ValueId = u32;

/// One statement inside a block: either emit a SPIR-V block's
/// straight-line body, or a nested construct.
pub const Item = union(enum) {
    body: u32,              // "emit instructions of SPIR-V block N here"
    construct: *Construct,  // a nested If / Loop / Switch
};

/// A run of items terminated by exactly one terminator.
pub const Block = struct {
    items: []Item = &.{},
    term: Terminator,
};
```

So a `Block` is "do these items, then end this way." An `Item` is either
"paste block N's math here" or "here's a nested if/loop/switch."

The **terminator** is how a block ends — and this is where the phi
assignment lives:

```zig
pub const Terminator = union(enum) {
    exit_if: Exit,       // leave the nearest enclosing If (to its merge)
    exit_switch: Exit,   // leave the nearest enclosing Switch
    exit_loop: Exit,     // leave the nearest enclosing Loop (a `break`)
    cont: Exit,          // go to the loop's continuing block (next iteration)
    break_if: BreakIf,   // conditional break out of a loop
    branch: u32,         // plain jump (rare in structured output)
    ret,                 // return
    ret_value: ValueId,  // return a value
    kill,                // discard (fragment shaders)
    unreach,             // unreachable
};

pub const Exit = struct {
    /// The phi values handed to the target construct's params, in order.
    args: []ValueId = &.{},
};
```

Notice `Exit.args`. **This is how phi values travel.** When a block exits
an `if`, it carries the values that the merge's phis need on *this* edge.
The emitter turns each into `phi_whatever = arg;` right before the
structural `}`.

And the constructs themselves:

```zig
pub const If = struct {
    cond: ValueId,
    true_blk: *Block,
    false_blk: *Block,
    merge_id: u32,
    results: []Param = &.{},   // the phis at the merge
};

pub const Loop = struct {
    body: *Block,
    continuing: *Block,        // runs at the end of each iteration
    merge_id: u32,
    header_params: []Param = &.{},  // loop-carried phis (the header OpPhis)
    iter_args: []ValueId = &.{},    // their next-iteration values
    results: []Param = &.{},        // phis at the loop's exit (merge)
};
```

A `Param` is a lowered phi — "declare `var phi_N: T;` and assign it on the
edges":

```zig
pub const Param = struct {
    phi_id: u32,        // becomes the WGSL variable name `phiN`
    type_id: u32,       // for the `var phiN: T;` declaration
    init: ?ValueId = null,  // loop headers only: the pre-loop initial value
};
```

### The validator: making the old bug impossible

`ir.zig` ends with a `validate` pass. Its job is to enforce one invariant:

> **Every exit edge must supply exactly as many phi args as the construct
> it targets declares params.**

Why does this matter? The original (pre-IR) transpiler had a bug: a branch
that reached a merge *through* a nested construct would silently drop a phi
copy, leaving the variable at its default. That made the mandelbrot loop
exit on iteration 1 → a blank screen. The validator makes that bug
**structurally unrepresentable**: a dropped copy shows up as "this exit
carries 2 args but the construct has 3 params" → `PhiArityMismatch`. It's
our tiny analog of Tint's IR validator.

```zig
pub const ValidateError = error{
    PhiArityMismatch,  // an exit supplied the wrong number of phi values
    DanglingExit,      // an exit with no matching enclosing construct
};
```

---

## 7. `ir_build.zig` — turning the graph into the tree

This is the structurer. The core idea is a **recursive walk with a "stop
stack."** This exact trick is what Tint uses too (Tint calls it
`walk_stop_blocks_`); we call it `StopStack`.

### The "stop stack" insight

Here's the problem it solves. When we're building the `then` branch of an
`if`, we follow branches block by block. But how do we know when to
*stop* — when we've hit the merge block (the end of the `if`) versus when
we're still inside the branch?

The answer: before we start building a construct's interior, we **push its
merge block onto a stack** as a "stop." Then, as we follow branches, every
time a branch targets a block on the stop stack, we know: *"this isn't a
normal block to descend into — it's an exit out of construct X."* We emit
the matching exit terminator and stop.

```zig
const StopStack = struct {
    items: [32]Stop = undefined,
    len: usize = 0,

    // ... push / pop ...

    /// Innermost-first lookup: the nearest enclosing construct that
    /// owns `target`.
    fn lookup(self: *const StopStack, target: u32) ?ExitKind {
        var i: usize = self.len;
        while (i > 0) {
            i -= 1;
            if (self.items[i].target == target) {
                return self.items[i].kind;
            }
        }
        return null;
    }
};
```

The stack being *innermost-first* is exactly why an exit "leaves the
nearest enclosing construct of its kind" — a `break` inside two nested
loops breaks the inner one, because that's what's on top of the stack.

### The dispatcher: `buildBlock`

`buildBlock(start_id, stops)` is the engine. It follows the chain of
blocks starting at `start_id`, deciding what to do at each one based on
its kind (which the `BlockTable` precomputed: is it a plain block? a
selection header? a loop header? a switch header?). Here's the shape of
it (lightly trimmed):

```zig
fn buildBlock(self: *Builder, start_id: u32, stops: *StopStack) BuildError!*ir.Block {
    var items: std.ArrayListUnmanaged(ir.Item) = .empty;
    var cur_id: u32 = start_id;
    while (true) {
        const info = self.table.get(cur_id) orelse return error.MalformedFunction;
        switch (info.kind) {
            .plain => {
                try items.append(self.arena, .{ .body = cur_id });   // paste its math
                switch (self.classifyTerminator(info)) {
                    .ret, .ret_value, .kill => { /* finish the block, return */ },
                    .branch => {
                        const target = try self.branchTarget(info);
                        if (stops.lookup(target)) |kind| {
                            // target is an exit out of an enclosing construct
                            return self.finishBlock(items, emptyExit(kind));
                        }
                        cur_id = target;     // otherwise keep walking the chain
                    },
                    .branch_cond => { /* in-loop break/continue → build an If */ },
                    .switch_ => return error.IrBuildUnsupported,
                }
            },
            .selection_header => { /* emit body, then build the nested If */ },
            .loop_header     => { /* build the nested Loop */ },
            // ...
        }
    }
}
```

The key moment is `if (stops.lookup(target)) |kind|`: when a branch points
at a stop, we don't recurse into it — we end the current block with the
matching exit (`exit_if`, `exit_loop`, …). That single check is what
turns "branch to the merge block" into "leave this construct."

### Building an `if` (the pattern for all constructs)

When `buildBlock` hits a selection header, it calls `buildIf`. Conceptually:

1. Read the `OpBranchConditional` to get `cond`, `then`-target, `else`-target.
2. Read `OpSelectionMerge` to get the merge id.
3. **Push the merge id onto the stop stack.**
4. Recursively `buildBlock(then-target)` → the true branch.
5. Recursively `buildBlock(else-target)` → the false branch.
6. **Pop the stop stack.**
7. Read any phis at the merge into `results`, and attach each phi value to
   the correct branch's exit terminator (this is the phi-routing logic we
   studied from Tint).

Loops and switches follow the same push-merge / recurse / pop / wire-phis
rhythm. Loops additionally push the *continuing* block as a `cont` stop,
so a back-edge becomes a `cont` terminator instead of an exit.

### Why we keep ids, not values

Notice that everything is a `u32` SPIR-V id, never a parsed value object.
That's deliberate: the emitter already knows how to turn an id into WGSL
text (`%14` → `_14`, a constant → its literal). Keeping ids avoids
building a second, parallel representation of every value. The IR is
*only* about shape.

---

## 8. `ir_emit.zig` — printing the tree as WGSL

This is the easy half: walk the tree, print text. It's recursive in
lockstep with the tree's shape. The whole `if` emitter:

```zig
fn emitIf(s, out, arena, f, emitBlockBody, depth, enc) !void {
    // Inside the branches, THIS if is the enclosing if for exit assignment.
    const inner = .{ .if_results = f.results, .loop_results = enc.loop_results, ... };
    try indent(out, arena, depth);
    try fmt(out, arena, "if ({s}) {{\n", .{s.wgslNameOf(f.cond)});
    try emitBlock(s, out, arena, f.true_blk, emitBlockBody, depth + 1, inner);
    try indent(out, arena, depth);
    try out.appendSlice(arena, "} else {\n");
    try emitBlock(s, out, arena, f.false_blk, emitBlockBody, depth + 1, inner);
    try indent(out, arena, depth);
    try out.appendSlice(arena, "}\n");
}
```

`emitBlock` prints each item (either calls back into `emitBlockBody` to
print a SPIR-V block's math, or recurses into a nested construct), then
prints the terminator. The terminator emitter is where a phi finally
turns into an assignment: an `exit_if` with `args` prints
`phi_whatever = arg;` for each carried value, then the `}` is closed by
the caller.

Two things worth noting:

- **`s: anytype`** — the emitter is generic over its "state" object. It
  only needs `s.wgslNameOf(id)` (id → text) and `s.scalarTypeNameOf(id)`
  (for signed switch literals). This lets the real transpiler and the unit
  tests pass different state objects. It's dependency injection without a
  framework.
- **`emitBlockBody` is also injected** — the IR emitter doesn't know how
  to print instructions; it calls back to the text emitter in
  `spv2wgsl.zig`. Clean separation: `ir_emit.zig` owns *structure*,
  `spv2wgsl.zig` owns *instructions*.

---

## 9. `spv2wgsl.zig` — instructions, types, and the parts the IR skips

The IR handles control flow and phis. Everything else lives here:

- **Types** — `OpTypeInt` → `i32`/`u32`, `OpTypeVector` → `vec4<f32>`,
  structs, etc. (`emitTypeStruct` and friends.)
- **Instructions** — `OpIAdd` → `let _7: i32 = _5 + _6;`,
  `OpFunctionCall`, texture sampling, and so on.
- **Entry points / I/O** — building the `@vertex`/`@fragment` signatures,
  the `@builtin(position)`/`@location(N)` attributes, and the
  inputs/outputs structs.
- **Hoisting** — the cross-block-value analysis (below).

### How a value becomes text

Each value op produces a `let` binding. For example, a binary op:

```zig
try bindLhs(out, s, result, name, t.wgsl_name);   // "  let _7: i32 = "
try bprint(out, s.arena, "{s} {s} {s};\n", .{ a, op_text, b });  // "_5 + _6;"
```

The `bindLhs` helper is important — it centralizes a recent feature
(hoisting), so let's cover that.

### Hoisting: when a `let` won't do

WGSL's `let` is **block-scoped**: a `let` declared inside an `if` body is
invisible outside it. But SPIR-V is happy to define a value in one block
and use it in a sibling block:

```wgsl
if (a) { let _12 = 2; }    // _12 defined here
if (b) { use(_12); }       // ← ERROR: _12 not in scope here
```

The fix mirrors how we already handle phis: if a value is used outside its
defining block, **hoist it to a function-scope `var`** and *assign* at the
definition instead of `let`-binding:

```wgsl
var _12: i32;              // hoisted to function scope
if (a) { _12 = 2; }        // assignment, not `let`
if (b) { use(_12); }       // ✓ in scope
```

`markHoistedResults` does this with two linear passes over the function:

1. **Record** the defining block of every value.
2. **Scan uses**; if a value is used in a different block than its
   definition, mark it "hoisted."

Then `bindLhs` checks the mark: hoisted values get `_12 = ` (assignment),
normal values get `let _12: i32 = ` (binding). The function prologue
declares a `var _12: T;` for each hoisted value, right next to the phi
vars.

A subtlety we got right: phi *operands* are also "uses," but they happen
at the phi's **predecessor block**, not the phi's own block. So the use
scan checks OpPhi operands against the predecessor block too. (This is the
same "where does this value actually get used?" question, applied to the
synthesized `phi = value` assignment.)

The riskiest part of hoisting is deciding *which operands of an
instruction are value references* — because a switch-case literal or a
shuffle index is a raw number that could be mistaken for an id. So the
classifier (`appendValueOperands`) is deliberately conservative: it only
treats known-id positions as values, and an unrecognized opcode
contributes nothing (it might miss a hoist, but it will never mistake a
literal for a value and miscompile).

---

## 10. How we know it's correct: the naga gate

We don't trust ourselves — we trust **naga** (Firefox's WGSL validator).
Two test layers:

- `zig build wgpu-diff` — runs the transpiler over 181 Tint test fixtures
  + every shader the project builds, and checks each one transpiles and
  structurally validates. Fast, but doesn't run full naga.
- `zig build naga-tint` — runs **naga** over every fixture the IR walker
  translates, compared against a baseline list of "known still-broken"
  fixtures. It **fails** if a new fixture goes invalid (a regression) *or*
  if a baselined one becomes valid (forcing us to shrink the baseline and
  lock in the win).

That second gate is the rule that makes "handled" mean **"naga accepts
it."** Without it, a fixture could "translate" while emitting WGSL the
browser would reject — which is exactly the trap we were in before the
gate existed (21 fixtures were silently invalid; we've since cleared all
but one).

---

## 11. What we *don't* handle (and why that's OK)

Some SPIR-V control flow is genuinely **unstructured** — jumps that don't
form a clean tree (think `goto` across loop boundaries). You cannot always
turn that back into `if`/`while`, and **even Tint rejects some of it.** For
those, `spv2wgsl` falls back to an older "legacy" walker. The long-term
goal ("F5") is to delete the legacy walker once every fixture is either
properly translated or confirmed legitimately-unstructured.

---

## 12. The one-paragraph summary

SPIR-V is a flat graph of blocks; WGSL is a nested tree. `ir_build.zig`
reconstructs the tree using a recursive walk with a "stop stack" (push a
construct's merge block before descending; a branch to a stop becomes an
exit). SSA phi nodes — "pick a value based on which block we came from" —
become a single function-scope `var` assigned on each incoming edge (our
key simplification over Tint, which threads SSA values through the tree).
`ir.zig` is the tree's data model plus a validator that makes the old
phi-dropping bug impossible. `ir_emit.zig` prints the tree as text;
`spv2wgsl.zig` fills in the instructions, types, and I/O the tree skips,
plus hoists any value used across blocks. And `naga` checks everything,
so "it transpiles" really means "the browser will accept it."
