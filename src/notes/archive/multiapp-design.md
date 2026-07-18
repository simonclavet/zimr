# Multi-app — recursive Frame-passing (design note)

This is a design note for a feature we **don't have yet** but want to
keep open as we make decisions.  It's tracked here so future
"shouldn't we put X on App?" questions can be answered with: "no,
because we want recursive multi-app to keep working in userland."

## The capability

Run multiple zimr apps inside one wasm instance, each with its own
state, drawing into its own rect of the canvas, with its own
allocator (so leaks are detectable per-app), RNG, log prefix, and
asset path scope.  Recursively — a multi-app could itself contain
multi-apps, three levels deep with no special support.

Use cases:

- **Examples gallery in one wasm bundle.**  All 14 examples running
  in a 4×4 grid, killable, restartable, leak-checkable.  One bundle
  ships, one set of bytes loads, no iframe coordination.
- **Hot-reload of game state.**  Kill one app, instantiate fresh
  with new state, leak-check the kill.  No page reload.
- **Stress tests.**  100 instances of `particles.zig` running for 60
  frames each, killed, leak-checked.  Catches a class of bugs we
  can't catch otherwise.
- **Composable widgets.**  A "minimap widget" or "inventory panel"
  could be authored as a tiny zimr app and embedded.

## The userland trick

**A `Frame` is a complete environment** — it contains the four
allocators and the four effect handles.  So a parent's `update` fn
can synthesize a virtual `Frame` for a child and call the child's
`tick(f, &child_state)`:

```zig
fn parentUpdate(f: *z.Frame) void {
    // Frame for child #1 — shares time, has scoped allocator, prefixed logs.
    var child_arena = std.heap.ArenaAllocator.init(f.gpa);
    defer child_arena.deinit();  // drop on parent frame end → child gone, leak-checked
    var child_logger = z.logger.Prefixed.init(f.log, "[child1] ");
    var child_rng = z.Rng.Seeded.init(child1_seed);

    var child_frame: z.Frame = .{
        .app = f.app,
        .gpa = child_arena.allocator(),
        .frame = f.frame,        // shared per-frame arena
        .scratch = f.scratch,    // shared scratch
        .loader = f.loader,      // or Loader.Prefixed for asset scoping
        .clock = f.clock,        // honest: same tick, same time
        .rng = child_rng.rng(),
        .log = child_logger.logger(),
    };

    // Drawing scope — scissor + translate so child sees its own origin.
    z.shapes.beginScissorMode(child_x, child_y, child_w, child_h);
    defer z.shapes.endScissorMode();
    child1.tick(&child_frame, &child1_state);
}
```

Same trick again at the next level — `child1.tick` is itself an
update function and can do the same to spawn a grandchild.  No
runtime support needed.

## What zimr has to provide for this to work

After spring cleanup (phases A–E), most of it works automatically.
Specifically, for the userland multi-app trick to be clean we need:

- ☑ **Frame fields, not globals.**  Done in §4 pivot.
- ◐ **Every allocation reachable from user code goes through an
   explicit allocator.**  In progress (spring cleanup phases A–E).
   Until done, multi-app leak detection has false negatives —
   `genMeshCube` calls `libc.malloc`, those bytes never show up on
   `child_arena.deinit()`.  **This is the prerequisite.**
- ☐ **`Logger.Prefixed`** — wrap a parent Logger, prefix every emit.
   ~30 LOC.  Trivial; add when first multi-app demo lands.
- ☐ **`Loader.Scoped`** — wrap a parent Loader, prefix every URL.
   ~50 LOC.  Same: trivial, add when needed.
- ☐ **`Input` as a first-class effect with viewport scoping.**  Today
   input is snapshot-based via globals.  A child wants "input that
   happened inside my rect, with mouse coords translated."  This is
   the one piece that needs design work — and that work is the same
   work as giving Input the §4 treatment.  Defer until then.

## What zimr does NOT need to provide

- **State isolation in `core.zig`** (TIME, FPS, WINDOW, TRACELOG).
  These are intentionally shared — children should see honest time,
  the canvas size is what it is.  No refactor needed.
- **Per-app `App` struct.**  One App per wasm instance, multiple
  user-defined "sub-apps" running inside its update fn.  The App is
  the wasm's unit; the sub-apps are user-level constructs.
- **A `shutdown` callback.**  Children shut down when their parent's
  update fn drops their state and arena.  No runtime hook needed.
  Hot-restart = kill old state, init new.
- **A `should_quit` flag on App.**  Same reason — the parent decides
  when a child stops by simply not calling its `tick` anymore.

## Implications for current design decisions

This shapes a few choices we're making now:

- **Why effect types take `userdata + vtable`, not direct struct
  references.**  So a child can wrap a parent's effect (Logger →
  Prefixed) without the child knowing the parent's concrete impl.
- **Why allocators are first-class on Frame.**  Children get their
  own arena off the parent's gpa.
- **Why `Rng.Seeded` is dual-use as gameplay RNG and test mock.**
  Children get reproducible randomness independent of siblings by
  giving each a `Seeded` with a different seed.
- **Why `Loader` is poll-based, not callback-based.**  A child can
  poll on its own schedule without coordinating with a parent's
  callback registry.

## When to actually build it

After spring cleanup completes (all gen* / load* / image transforms
take explicit allocators).  At that point write one demo —
`examples/gallery.zig` running 4 child apps in a 2×2 grid — and the
adapters needed (`Logger.Prefixed`, `Loader.Scoped`) drop out of
that demo's needs.  No speculative API surface; build what the demo
forces us to build.
