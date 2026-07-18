# Pool/ECS alignment refactor plan

## Status

**Active plan, design locked.**  Generated 2026-05-10 from the
brainstorm-and-questions cycle.  Q1-Q5 closed (see "Decisions
locked in" below); implementation phases queued behind this.

## Motivation

Today zimr has two storage abstractions for generational handles
side-by-side:

- `pool.Pool(T)` — lean, list-side verbs (`pool.get(handle)`),
  used by rlsw for software-renderer-internal state.
- `ecs.Entities` — general-purpose, handle-side verbs
  (`entity.get(world, T)`), used by the gpu module for all
  user-facing GPU resources.

The two surfaces are cosmetically different (different verb
names, different verb placement) and don't share an idiom.  This
hurts a user moving between them — every helper looks slightly
unfamiliar.  Additionally, `Ref(T)` (the gpu-module's typed
wrapper over `ecs.Entity`) introduces a third API shape on top
that's closer to Pool than to raw ECS.

Goal: bring Pool's surface cosmetically closer to ECS+Ref(T)
without merging the implementations.  Pool stays Pool; ECS stays
ECS; both keep their internals.  Only the public method names
and signatures align.

Secondary goal: catch cross-world deref bugs in debug builds.
Once Pool and Ref(T) look identical at call sites, mixing them
up is more likely.  A runtime stamp check in debug catches the
bug class at the misuse site.

## Decisions locked in (Q1-Q5)

| Q | Decision |
|---|----------|
| Q1 — direction | Option A: bring Pool toward ECS+Ref vocabulary (not vice versa). |
| Q2 — shape | Option C: handle-side methods on `Handle(T)` matching `Ref(T)`'s verbs. |
| Q3 — alloc semantics | Option A: Pool keeps `alloc()` (bare slot) AND gains `spawn(value)` (one-step). |
| Q4 — naming | Predicate is `isValid`; destroy returns `bool` (was-live). |
| Q5 — world-stamp | Option A: bundled with this refactor (not a separate effort). |

## Final API surface

### Pool, after refactor

```zig
// Pool(T) — the storage type
pool.init(gpa, capacity)        !Pool(T)        // unchanged
pool.deinit(gpa)                void             // unchanged
pool.alloc()                    Handle(T)        // unchanged — bare slot, fill later
pool.spawn(value)               !Handle(T)       // NEW — alloc + write in one
pool.deinit(gpa)                void             // unchanged

// Handle(T) — the handle, now with handle-side methods
handle.deref(pool)              ?*T              // NEW (was pool.get(handle))
handle.destroy(pool)            bool             // NEW (was pool.free(handle))
handle.isValid(pool)            bool             // NEW (was pool.valid(handle))
handle.isNil()                  bool             // unchanged
handle.index() / .cycle()       (low-level)      // unchanged — for debug/printing
Handle.nil                      Handle(T)        // unchanged

// REMOVED — old list-side verbs no longer compile:
//   pool.get(handle)
//   pool.free(handle)
//   pool.valid(handle)
```

### Ref(T), after the ergonomic additions

```zig
// Ref(T) — the typed wrapper over ecs.Entity
Ref(T).spawn(gpa, world, value) !Ref(T)          // NEW — wraps reserveImmediate + changeArchImmediate
ref.deref(world)                ?*T              // unchanged
ref.destroy(world)              bool             // NEW — wraps destroyImmediate
ref.isValid(world)              bool             // unchanged
ref.isNil()                     bool             // unchanged
Ref(T).nil                      Ref(T)           // unchanged
```

### Underlying ECS primitives — unchanged

`Entity.reserveImmediateOrErr`, `entity.changeArchImmediateOrErr`,
`entity.get`, `entity.exists`, `entity.destroyImmediate` all
keep their existing verbose names.  Power users who need
multi-component archetypes, command-buf deferred ops, or
explicit-step lifecycle still have those primitives at the
underlying API.

`Ref(T)` is the wrapper that makes the common case ergonomic.
Pool's `Handle(T)` is the wrapper that makes pool ergonomic.
The wrappers agree on verbs; the underlying primitives don't
have to.

### Side-by-side: identical user-facing shape

```zig
// Pool flavor:
var pool: Pool(GpuTexture) = try .init(gpa, 256);
defer pool.deinit(gpa);
const h: Handle(GpuTexture) = try pool.spawn(my_gpu_tex);
if (h.isValid(&pool)) {
    const ptr = h.deref(&pool).?;
    // ...
}
_ = h.destroy(&pool);

// Ref flavor:
var world: ecs.Entities = try .init(.{ .gpa = gpa, .cap = ... });
defer world.deinit(gpa);
const r: Ref(GpuTexture) = try Ref(GpuTexture).spawn(gpa, &world, my_gpu_tex);
if (r.isValid(&world)) {
    const ptr = r.deref(&world).?;
    // ...
}
_ = r.destroy(&world);
```

Identical at the call site modulo:
- `spawn` takes a gpa for ECS (archetype changes may allocate),
  not for Pool (slots pre-allocated at init).
- `pool.spawn` may return error.PoolExhausted (no slots free);
  `Ref(T).spawn` may return ECS allocation errors.

Both differences are honest reflections of the underlying
machinery's needs.

## World-stamp mechanism

### Design

Each world (Pool or Entities) gets a unique stamp at init.
Each handle/ref captures the stamp at allocation time.  Deref
checks the stamps match.  In debug builds, mismatch panics with
a clear message.  In release builds, the stamp field is
zero-sized (`void`) and all checks compile out.

### Layout (debug)

```zig
// In a new src/world_stamp.zig or inline at the top of pool.zig:
const builtin = @import("builtin");
const debug_enabled: bool = builtin.mode == .Debug;
pub const Stamp = if (debug_enabled) u64 else void;

var counter = std.atomic.Value(u64).init(1);  // 0 reserved for nil
pub fn nextStamp() Stamp {
    if (!debug_enabled) {
        return {};
    }
    return counter.fetchAdd(1, .monotonic);
}
```

The Stamp is a single u64 — no name field initially.  Name string
would be nice for panic messages but complicates the design (where
does the name live?  Does the user pass it at init?).  Defer the
name to a follow-up if panic messages prove insufficient.

### Stamp lives in...

- `Pool(T)` — `debug_stamp: Stamp` field, set in `init`
- `ecs.Entities` — `debug_stamp: Stamp` field, set in `init`
- `Handle(T)` — captured at `pool.alloc()` / `pool.spawn(value)` time
- `Ref(T)` — captured at `Ref(T).spawn(...)` time

For `Handle(T)`: the existing enum-backed-by-u32 layout MUST
expand to a struct in debug builds (or stay an enum in release).
Two options:

**Option Stamp-A — Handle(T) becomes a struct.**

```zig
pub fn Handle(comptime T: type) type {
    return struct {
        bits: u32,
        debug_stamp: Stamp,
        // ... methods
    };
}
```

Costs: handle size jumps from 4 to 16 bytes in debug (4 bits +
padding + 8-byte stamp), 4 bytes (with stamp zero-sized) in
release.  Comparable to Ref(T) — both are now multi-field
structs.

**Option Stamp-B — Handle(T) stays enum; stamp lives elsewhere.**

Stash stamps in a side-table inside Pool, keyed by handle.index.
Costs: extra lookup per deref in debug; more complex.  Rejected.

**Decision: Stamp-A.**  Cleaner, simpler, matches Ref(T)'s shape.

Side-effect: `Handle(T).pack(idx, cyc)`'s static API has to
change (no stamp to attach when constructed externally).  Pool
internals must use the constructor consistently.

### Stamp check semantics

In `deref` / `destroy` / `isValid`:

```zig
pub fn deref(self: @This(), pool: *const Pool(T)) ?*T {
    if (debug_enabled and self.bits != nil_bits) {
        if (self.debug_stamp != pool.debug_stamp) {
            std.debug.panic(
                "Handle({s}) dereferenced against wrong pool. " ++
                "Handle stamp={d}, pool stamp={d}. " ++
                "Common cause: handle from pool A passed to pool B.",
                .{ @typeName(T), self.debug_stamp, pool.debug_stamp },
            );
        }
    }
    // ... existing lookup logic
}
```

`Handle.nil` skips the stamp check (nil handle has stamp=0,
which never matches any real pool's stamp >= 1; checking nil
first short-circuits cleanly).

Same shape for `Ref(T).deref`.

### What about cross-process or restart?

The atomic counter resets on process restart.  Stamps don't
persist.  This is fine — refs/handles don't persist either
(they're indices into live in-memory storage).  Stamps only
need to be unique WITHIN a single process run, and the atomic
guarantees that.

### Stamp + nil interaction

`Handle.nil` has `bits = 0` and `debug_stamp = 0` (zero-init).
The deref method checks nil before the stamp:

```zig
if (self.isNil()) return null;
if (debug_enabled and self.debug_stamp != pool.debug_stamp) @panic("...");
// ... lookup
```

This way nil refs are safe to deref against any pool (returns
null without complaining about stamps).

## Implementation phases

Each phase ends with `zig build test` + `zig build smoke-test`
green.

### Phase 1 — World-stamp infrastructure

- Create `src/world_stamp.zig` (or inline in pool.zig + ecs.zig
  if dependency churn is undesirable).  Holds the atomic counter
  + `nextStamp()` + `Stamp` type.  ~30 LOC.
- Add `debug_stamp: Stamp` field to `Pool(T)`, set in `init`.
- Add `debug_stamp: Stamp` field to `ecs.Entities`, set in `init`.
- No behavior change yet (stamps not checked).  Pure
  infrastructure.
- **Gate**: tests pass; release build size unchanged.

Estimated effort: 30 min.

### Phase 2 — Handle(T) struct migration

- Change `pool.Handle(T)` from `enum(u32)` to `struct { bits, debug_stamp }`.
- Update internals: `Handle.pack(idx, cyc)` now also takes stamp
  (or rather, Pool's internal alloc populates the stamp).
- `Handle.isNil()` checks `bits == 0`.
- `Handle.nil` is `.{ .bits = 0, .debug_stamp = 0 }`.
- All Pool internals updated to construct handles with stamps.
- No deref/destroy methods yet — just the struct change.
- **Gate**: tests pass; existing pool callers (rlsw, internal pool
  tests) still work via existing `pool.get(handle)` etc.

Estimated effort: 1 hour.  Risk: medium — enum-to-struct is a
real layout change, every cast site needs review.

### Phase 3 — Handle(T) handle-side methods

- Add `handle.deref(pool: *const Pool(T)) ?*T` — wraps existing pool.get.
- Add `handle.destroy(pool: *Pool(T)) bool` — wraps existing pool.free.
- Add `handle.isValid(pool: *const Pool(T)) bool` — wraps existing pool.valid.
- All three include the debug-stamp check.
- Old list-side `pool.get(handle)`, `pool.free(handle)`,
  `pool.valid(handle)` STAY available for back-compat during the
  rlsw migration.
- **Gate**: tests pass; new methods exercised by inline pool tests.

Estimated effort: 30 min.

### Phase 4 — Pool.spawn(value)

- Add `pool.spawn(value: T) !Handle(T)` — alloc + write in one.
- Returns error.PoolExhausted if no slots free.
- Inline test: spawn populates slot value correctly; spawn on full
  pool returns error.
- **Gate**: tests pass.

Estimated effort: 20 min.

### Phase 5 — Ref(T).spawn + Ref(T).destroy

- Add `Ref(T).spawn(gpa, world, value) !Ref(T)` to gpu.zig.
  Wraps `Entity.reserveImmediateOrErr` + `changeArchImmediateOrErr`.
- Add `ref.destroy(world) bool` to gpu.zig.  Wraps
  `entity.destroyImmediate`.
- Both include the debug-stamp check (against
  `world.debug_stamp`).
- Refactor existing gpu.zig loaders to use `Ref(T).spawn` —
  significant simplification, ~5 sites.
- Refactor existing gpu.zig unloaders to use `ref.destroy` — same.
- **Gate**: tests pass; smoke-test renderer demos byte-identical
  GL traces.

Estimated effort: 1 hour.  Most error-prone phase — every loader
in gpu.zig changes shape.  Renderer demos serve as canary.

### Phase 6 — rlsw migration

- Find every `pool.get(h)` / `pool.free(h)` / `pool.valid(h)` in
  rlsw.zig (~20 callsites surveyed earlier).
- Sed-rename to `h.deref(&pool)` / `h.destroy(&pool)` /
  `h.isValid(&pool)`.
- Manual verification of each site (especially mutability — `*const
  Pool` vs `*Pool`).
- **Gate**: tests pass; rlsw smoke test passes (rlsw_side_by_side
  example).

Estimated effort: 1 hour.  Mostly mechanical.

### Phase 7 — Delete old list-side Pool methods

- Remove `pool.get(handle)`, `pool.free(handle)`,
  `pool.valid(handle)` from pool.zig.
- Any remaining callers compile-fail; chase them down.
- **Gate**: tests pass; full audit green (DAG, globals, fmt, smoke,
  test).

Estimated effort: 30 min.

### Phase 8 (optional) — Pool.forEach

Pool lacks `forEach` today.  ECS has it.  For full surface
alignment, Pool could gain `pool.forEach(callback, ctx)`.
Implementation: iterate live slots, call callback per slot.

This is OPTIONAL — adds API surface without an immediate user.
Skip until a real caller appears.

Estimated effort: 20 min if shipped.

### Phase 9 (deferred) — Init signature alignment

Pool's init takes `(gpa, capacity)`.  ECS's init takes an
options struct with nested cap.  Could align by making Pool's
init also take options.

DEFERRED — init is rare per program (1-2 calls), low signal,
high churn cost (every internal Pool consumer updates init
call).  Revisit if other reasons appear.

## Test plan

### New inline tests in pool.zig

- `pool.spawn(value)` populates slot value correctly.
- `pool.spawn` on full pool returns error.
- `handle.deref(pool)` returns same pointer as `pool.get(handle)`
  during the back-compat overlap window.
- `handle.destroy(pool)` returns true for live handle, false for
  destroyed.
- `handle.isValid(pool)` matches `pool.valid(handle)`.
- `Handle(T)` struct size: 16 bytes in debug, 4 bytes in release.
- Cross-pool stamp panic: in debug, deref'ing a handle from pool A
  against pool B panics.  Test via `expectPanic` if Zig 0.16 has
  one, otherwise document as a manual check.

### New inline tests in gpu.zig

- `Ref(T).spawn` creates entity + attaches component.
- `ref.destroy` removes entity, returns true.
- Cross-world stamp panic (analogous to pool's).

### Renderer demo invariants

After Phase 5 ships, pbr_demo / split_screen / png_demo GL traces
MUST match pre-migration counts (10138 / 15298 / 1444+retained=1).

### rlsw smoke

After Phase 6 ships, `rlsw_side_by_side` smoke test passes — this
is the canary for the rlsw migration since it exercises both
backends side-by-side.

## Call-site impact

### Internal pool callers (must rename, ~20 sites)

- `src/rlsw.zig`: ~20 callsites for `pool.get`, `pool.free`,
  `pool.valid` on `Pool(Texture)` and `Pool(Framebuffer)`.

### Internal ECS+Ref callers (cleaned up to use new ergonomics)

- `src/gpu.zig`: ~6 loaders use the verbose
  `reserveImmediate + changeArchImmediate` pattern today.
  Each becomes `Ref(T).spawn(gpa, world, value)`.  ~30 LOC
  removed, ~6 added.
- `src/gpu.zig`: ~5 unloaders use `entity.destroyImmediate` today.
  Each becomes `ref.destroy(world)`.

### External callers — none

User code touches `Ref(T)` and `gpu.X` loaders, not Pool.  Pool
isn't on the user surface; only rlsw uses it internally.  External
zero churn.

## Risk + rollback

### Phase 2 (Handle enum-to-struct) is the highest-risk step

Layout change from `enum(u32)` to `struct { bits: u32, debug_stamp:
Stamp }` changes:
- Sizeof in release: 4 → 4 (stamp is void, zero-sized).
- Sizeof in debug: 4 → 16 (with 4-byte padding then 8-byte stamp).
- Bit-pattern: `enum(u32)` was a bare u32; struct has the u32 in
  a `bits` field but the actual layout is now a Zig struct.
- Equality: `enum` had built-in `==`; struct needs `.eql` or field
  comparison.

Any code that does `@bitCast(@enumFromInt(...))` on handles is
suddenly wrong.  Mitigation: grep for `@enumFromInt` and
`@intFromEnum` on Pool handles BEFORE Phase 2; preserve every
such site explicitly.

### Rollback strategy

If Phase 2 reveals deep dragons (unexpected bit-casts, equality
in surprising places), revert via `git checkout HEAD~ src/pool.zig`
and re-think.  Phases 1, 3-7 each cleanly revertable; Phase 2 is
the structural-pivot phase.

### What if world-stamp adds release bloat?

Test invariant: `zig build --release=small` zimr.js stays at 42.47
KB +/- noise.  If it grows, the `if (debug_enabled)` guards aren't
compiling out — fix before Phase 7.

## Out of scope

The following are NOT addressed by this plan:

- **`z.legacy` namespace** — separate effort.  Once this lands and
  examples are content with the new verbs, introduce `z.legacy.X`
  for the unmigrated raylib-shape types.
- **Material migration to ref-based texture/shader fields** — large
  multi-turn effort.  Independent of this work.
- **Forced rlsw migration to ECS** — explicitly rejected during
  brainstorm (different needs, Pool is correct for rlsw).
- **`anytype` world parameter / duck typing** — explicitly rejected
  by user during brainstorm.  Pool stays Pool, ECS stays ECS.
- **Compile-time world tagging** — refs typed against a specific
  world tag.  Considered, deferred.  Verbose for marginal
  additional safety beyond runtime stamps.
- **GpuWorlds heterogeneity** (some kinds Pool, some ECS) —
  brainstorm idea, not necessary once verbs align cosmetically.
- **Stamp names for better panic messages** — addable later if
  panic messages prove insufficient.

## Total effort estimate

| Phase | Time | Risk |
|---|---|---|
| 1 — stamp infra | 30 min | low |
| 2 — Handle struct | 1 h | **medium** |
| 3 — Handle methods | 30 min | low |
| 4 — pool.spawn | 20 min | low |
| 5 — Ref ergonomics | 1 h | medium |
| 6 — rlsw migration | 1 h | low (mechanical) |
| 7 — delete old | 30 min | low |
| **Total** | **~5 hours** | |

In turns: 3-5 turns to execute.  Each phase is a natural turn
boundary with audit gate green.

## Success criteria

After all phases ship:

1. Pool and Ref(T) have identical user-facing verbs:
   `spawn`, `deref`, `destroy`, `isValid`, `isNil`, `nil`.
2. No more `pool.get(handle)` / `pool.free(handle)` /
   `pool.valid(handle)` anywhere in the codebase.
3. `zig build --release=small` zimr.js stays at 42.47 KB.
4. Renderer demos byte-identical GL traces.
5. Cross-world deref panics in debug with a clear message
   (manually verified or via a deliberate test).
6. Documentation in this file marked complete, retro entry added
   below the phases.

## Open questions during execution

None at design time.  Add here if any appear during phase
implementation.
