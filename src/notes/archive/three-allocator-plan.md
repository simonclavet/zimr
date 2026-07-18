# Three-allocator plan — `app.persistent`, `app.gpa`, `frame.scratch`

## Pushback first — you already have most of this

The current state of zimr is closer to your proposal than you might
realize.  Looking at `src/zimr.zig`:

```zig
pub const Frame = struct {
    gpa: std.mem.Allocator,        // long-lived
    frame: std.mem.Allocator,      // per-frame arena
    scratch: std.mem.Allocator,    // per-update arena
    // ...
};
```

So we have THREE allocators on Frame today, plus a separate `app.gpa`
(via the App struct).  The actual missing piece is `app.persistent` —
the rest is mostly renaming + one cleanup.

The current model has a quiet bug, though: `frame.frame` and
`frame.scratch` are both `reset(.retain_capacity)` at the same point
in the frame:

```zig
// from app.endFrame() — line 711-712
_ = app.scratch_arena.reset(.retain_capacity);
_ = app.frame_arena.reset(.retain_capacity);
```

with a comment admitting the distinction is aspirational:

> Frame arena is reset *after* the next frame's commands are
> submitted (effectively right before the next update) — for now we
> reset both here since we don't have GPU sync events plumbed
> through; a future optimisation.

So today, `frame.frame` and `frame.scratch` are two pools with
identical lifetime semantics.  That's confusing without paying off.
Your proposal is the right cleanup: collapse them into one and call
it `scratch`.

## Pushback on the framing — "after GPU finishes" doesn't apply in WebGL2

You said: "Scratch arena is wiped after GPU has finished."

In a desktop OpenGL or Vulkan context, that's a real concern — the
driver may hold pointers into your buffer until the GPU consumes
them, and reading-back-while-the-GPU-is-still-using is UB.  WebGL2
sidesteps this entirely: every data-submission API in the spec
(`gl.bufferData`, `gl.bufferSubData`, `gl.texImage2D`,
`gl.texSubImage2D`, `gl.uniformXfv`, etc.) is **specified to copy**
the source data immediately into driver-managed memory.  Once the
call returns, your CPU pointer is yours to do with as you please.

This is great for us — it means we don't need GPU fence events, we
don't need a ping-pong of two scratch arenas, and we don't need to
wait for anything before wiping.  The right reset point is **at the
start of the next frame**, before the user's `update` is called.
Same place we reset today's scratch_arena — just the only such
arena going forward.

## Pushback on the gpa/persistent boundary

This is where the proposal needs sharpening.  "Never freed" sounds
clean but it isn't a sufficient distinguishing rule on its own —
plenty of `gpa` allocations in zimr today are also never freed (the
default font, the embedded shaders, etc.).  The page tear-down
collects them all the same.

If we don't define crisp rules for which pool is which, callers
will coin-flip and the partition becomes meaningless.  Concrete
rules I propose:

### `app.persistent` — strict criteria

- Allocated **once during app boot or first-touch initialization**
- Never freed during normal operation
- Has no per-app or per-instance variation — same data every run
- Examples: default font atlas, embedded shader source strings,
  built-in lookup tables, the wasi-stdout buffer

### `app.gpa` — strict criteria

- Allocated dynamically during runtime
- May or may not be freed before page unload — the lifetime is
  *capable* of being managed
- Per-app or per-instance variation: this asset depends on what
  the user loaded, this state depends on what the user did
- Examples: textures the user loaded from URLs, level data, async
  fetch buffers, sub-app state in multi-app harnesses

### `frame.scratch` — strict criteria

- Allocation lifetime ENDS this frame, no exceptions
- Pointer is NEVER captured into any longer-lived structure
- Examples: temporary `std.fmt.allocPrint` for HUD strings,
  intermediate compute buffers, per-frame culling lists, cull
  result arrays

If a candidate fits two pools' criteria, prefer the **shorter**
lifetime.  "When in doubt, scratch" is a good default — the worst
that happens is a faster reset.

## Wins this delivers

1. **Less typing for the common case.**  Today's setup-once-then-
   never-touch allocations all need `defer gpa.free(...)` ceremony
   for correctness on host tests, even though wasm doesn't care.
   `app.persistent` removes the ceremony entirely.

2. **Frame.scratch becomes meaningfully cheaper than gpa.**  Today
   it isn't — both delegate to wasm_allocator with the same
   bookkeeping.  Going forward, scratch is a true bump pointer:
   one-instruction allocation, one-call wipe.

3. **Mental model gets sharper.**  Three pools with clear rules
   beats two pools with a fuzzy boundary.

4. **Multi-app harness gets cleaner.**  Currently each sub-app in
   `gallery.zig` shares the parent's frame.scratch — a child can
   accidentally hold pointers across `runSubApp` boundaries.  With
   the unified scratch model, child Frames inherit parent's
   scratch (same memory, same wipe schedule), and a child can opt
   for its own arena layered on top of `app.gpa` if it wants
   isolation.

## Wins this does NOT deliver

Be honest: this is mostly an ergonomics / clarity refactor, not a
performance win.  The browser's `wasm_allocator` is fast for our
allocation sizes.  The arena bump-pointer is faster but we're not
allocator-bound — we're texture-upload-bound and shader-execution-
bound.  Don't sell this as a perf improvement; sell it as making
the code easier to read and harder to leak.

## Migration plan — 5 turns, incremental

### Turn A — formalize the three-pool model

1. Add `app.persistent: std.mem.Allocator` (backed by a new
   `app.persistent_arena: ArenaAllocator`, never reset)
2. Collapse `frame_arena` and `scratch_arena` into one
   `scratch_arena`.  `frame.scratch` is the only per-frame pool.
   `frame.frame` field is REMOVED.
3. Document the rules in `docs/style-guide.md` Rule 8.
4. Update existing examples that reference `f.frame` to use
   `f.scratch` instead (a small handful).

This breaks user code that uses `f.frame` — pre-1.0, fine.

Test gate: 483/483 host + 19/19 smoke green, no behaviour changes.

### Turn B — migrate boot-time allocations to persistent

Hunt down `try gpa.alloc(...)` calls inside `App.create`,
`loadFontDefaultImpl`, default shader compilation, etc., and route
them to `app.persistent`.

Concrete candidates I expect to find:
- The default font atlas pixels (currently in a static `var`, but
  there's a glyph array allocated somewhere)
- Pre-compiled default vertex/fragment shader source strings
  (today they're string literals which need no allocation, but
  future work might dynamically build them)
- The wasi panic message buffer

This phase is small — most "boot-time" allocations are already
either static module-level vars or short-lived gpa scopes.

Test gate: 483/483 host + 19/19 smoke green.

### Turn C — migrate hot per-frame paths to scratch

Find `try gpa.alloc(...)` calls inside update functions (or
functions reachable from update) where the allocation is freed in
the same call.  Replace with `frame.scratch.alloc`, drop the
`defer gpa.free` (arena handles it).

Hot candidates I expect:
- `std.fmt.allocPrint` calls for HUD strings, debug labels
- Per-frame culling result arrays in `models3d.zig`
- The temporary CPU mirror arrays in image_editor's update()

Cold candidates to LEAVE on gpa:
- Anything that crosses async boundaries (loader handles)
- Anything stored in user State across frames
- GPU resource CPU mirrors that get re-uploaded conditionally

Test gate: 483/483 host + 19/19 smoke green.  A bonus: gl call
counts should stay identical.  Behaviour-preserving refactor.

### Turn D — multi-app harness cleanup

Update `gallery.zig`'s `runSubApp` to make explicit how children
inherit scratch.  Today `child_frame.scratch = parent.scratch` is
fine (same arena), but the docs don't say so explicitly.

Add a `Frame.withChildScratch(arena)` helper for sub-apps that
want their own scratch (e.g., to budget allocation per child or
to detect leaks per-child).  Most won't use it; the gallery's
current pattern (shared parent scratch) is the recommended one.

Test gate: 483/483 host + 19/19 smoke green.  `gallery.zig` keeps
its 7790 GL count.

### Turn E — leak-test sweep + docs

Run `leak_test.zig` (already in `src/tests/`) against every
example in turn.  Confirm:
- `app.persistent` allocations don't show as leaks (they're
  intentional)
- `gpa` allocations all match a paired `gpa.free`
- `frame.scratch` allocations don't matter (arena reset wipes
  them)

Update `docs/style-guide.md` Rule 8 with the rules verbatim.
Update `README.md`'s short example to use the new shape.  Update
`docs/cheatsheet.md` to mark which allocator each function takes.

Test gate: same.

## What stays the same

- `App.create`'s constructor arg shape
- `z.run(cfg, State, init, update)` API
- All non-allocator parts of `Frame`
- `effects.{Loader,Clock,Rng,Logger}` (none of these allocate
  enough to matter; their internals stay on gpa)
- The Loader async pattern (still needs gpa-lifetime handles)

## What breaks

- User code that referenced `f.frame.allocator()` will need to
  rename to `f.scratch.allocator()`.  Pre-1.0, no callers in the
  example tree, ~10-line patch.
- Anyone manually constructing a Frame with the old field shape
  (only the multi-app harness does this internally — fix in
  Turn D).

## Recommendation

Do it.  The wins are real, the migration is cheap because the
infrastructure is mostly there, and the result aligns with both
Zig's allocator-first culture and the browser's no-real-teardown
reality.

The two pieces of pushback that still matter:
1. **Sharpen the persistent/gpa rules** — without them this is
   two names for the same pool.
2. **Drop the GPU-fence framing** — WebGL2 copies on submit, so
   "after GPU finishes" doesn't apply.  Reset scratch at frame
   start, same place as today.

If you agree with those two clarifications, the 5-turn plan above
is what I'd execute.  If you'd rather skip the gallery cleanup or
the leak-test sweep that's fine — they're polish.  The core wins
land in Turns A-C.
