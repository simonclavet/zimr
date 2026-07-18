# Ideas discovered during alignment-refactor execution

Running notebook of additional improvements spotted while
implementing the alignment plan.  Each item is a candidate for
a future turn; collected here so they don't get lost during
execution focus.

## 1. Add a `name` field to debug_stamp

**Spotted during**: Phase 1.

**Idea**: Stamps are currently bare integers.  Panic messages
say "handle.debug_stamp=5, pool.debug_stamp=7" — which tells
you they don't match but doesn't tell you WHICH pool was which.

Add an optional name parameter to `pool.init`/`Entities.init`
that the stamp captures (in debug only).  Panic message
becomes: "handle from pool 'textures' deref'd against pool
'meshes'".  Concrete, actionable.

**Cost**: ~10 LOC.  Plumbing-only.  `name: []const u8 = "(unnamed)"`
on both init signatures.

**Decision**: defer.  Bare-number panics are useful enough for
first ship; add name field if real users find the message
unhelpful in practice.

## 2. `release_safe` should keep stamps

**Spotted during**: Phase 1.

**Idea**: Currently `enabled = builtin.mode == .Debug`.  But
ReleaseSafe is a sensible build mode for production where you
WANT safety checks at low cost.  The stamp check should be
active there too.

**Refinement**: `enabled = builtin.mode == .Debug or builtin.mode == .ReleaseSafe`.

**Cost**: 1 line.  May grow release_safe binary slightly.

**Decision**: hold for after Phase 7.  Want to see actual
ReleaseSafe size impact before deciding.

## 3. The whole `<Handle>.pack(idx, cyc)` test pattern is fragile

**Spotted during**: Phase 1 survey.

**Observation**: rlsw has ~12 sites that do
`Pool(Texture).Handle.pack(99, 1)` to construct synthetic
handles for testing out-of-range/stale paths.  These work
because `pack` is exposed, but they're brittle — they encode
"slot 99 with cycle 1" which assumes Pool's internal layout
and the meaning of cycle=1 (live, generation 1).

**Better idea**: provide named test helpers in Pool:
- `Handle.test_oob` — a handle that's deliberately out of range
- `Handle.test_stale(idx)` — a handle that points at a valid
  slot but has a wrong cycle

Or simpler: a test-only `Pool.allocSyntheticOob()` that
returns a Handle guaranteed to fail OOB checks.

**Cost**: ~20 LOC for the test helpers, plus rename of ~12 sites.

**Decision**: defer.  Doesn't pay for itself yet; bring up
again if tests change shape.

## 4. Pool's `valid` doesn't take `*const`, but it should

**Spotted during**: Phase 3 planning.

**Observation**: Pool's existing `pub fn valid(self: *const Self,
handle: Self.Handle) bool` is correctly *const.  Pool's
existing `get` is also correctly *const.  When we add
`handle.deref(pool)`, the pool should be `*const` for read
operations.  Plan already says this; just noting that the
existing Pool surface is already correct.

**Decision**: no action needed.

## 5. Could `world_stamp` panic message include a backtrace?

**Spotted during**: Phase 1 write.

**Observation**: `std.debug.panic` prints a stack trace
automatically.  Good — the user gets the call chain from the
panic site back to the cross-world misuse.  No extra work
needed; just confirming the design is sufficient.

**Decision**: no action; the existing behavior is right.

## 6. Test for the panic case via abort handler?

**Spotted during**: Phase 1 testing.

**Observation**: We can't `expectError`-test a panic.  Zig
0.16's test framework doesn't have `expectPanic` AFAIK.  But
we could install a panic handler in the test, set a flag, and
have the handler longjmp out (POSIX) or trap then catch.

This is hacky.  Better: manually verify the panic message
during development by intentionally misusing, OR add a
deliberate test that's `pub fn` (not a test block) callable
from a CI script that runs the binary and grep's stderr.

**Decision**: defer.  Manual verification during Phase 3
implementation.

## 7. Pool capacity argument could be inferred from usage

**Spotted during**: Phase 1 viewing.

**Observation**: `Pool(T).init(gpa, capacity)` requires
specifying capacity at init.  But many callers know roughly
how many they'll need at compile time.  Could have
`Pool(T).initFixed(comptime cap)` that uses a comptime cap and
stack-allocates the backing slices (no allocator).

This is the "stack-allocated worlds" idea from the earlier
brainstorm.  Marginal value vs heap pools; defer.

**Decision**: defer.

## 8. The retained-loader pattern is the last verbose-ECS holdout

**Spotted during**: Phase 5.

**Observation**: 5 of 7 loaders in gpu.zig refactored to use
`Ref(T).spawn(gpa, world, value)`.  The retained loader
(`loadFromMemoryRetained`) stayed verbose because it spawns with
TWO components at once (`gpu: GpuTexture, source: SourceBytes`)
and `Ref(T).spawn` only handles a single component.

**Options**:
- `Ref(T).spawnWith(gpa, world, anytype)` — comptime-variadic
  helper for multi-component spawns
- `attachMetadata(gpa, world, ref, metadata)` post-spawn helper —
  decouples attachment from the spawn moment, enables dynamic
  metadata on existing refs

Latter is more useful: it makes metadata-on-resources a runtime
operation, not just a load-time one.  Users could tag existing
textures with `BundleTag` to participate in asset-bundle queries.

**Decision**: ship `attachMetadata` next turn (small).

## 9. Pool has no `forEach` — last asymmetry with ECS

**Spotted during**: Phase 5/6.

**Observation**: ECS exposes `world.forEach(callback, ctx)` for
iterating live entities.  Pool has no equivalent — callers iterate
`pool.data[1..pool.watermark]` manually, checking cycle parity.

After alignment, this is the last asymmetry between the two
storage shapes.  Phase 8 in the plan was marked optional; now
it's worth doing.

**Decision**: ship next turn alongside attachMetadata.

## 10. `Ref(T).eql` is missing — same gap Handle had

**Spotted during**: Phase 2.

**Observation**: When Handle went enum→struct, structural equality
broke (rlsw's `h == self.bound_framebuffer` site needed an `eql`
method).  `Ref(T)` is a struct from day one and presumably also
can't be compared with `==`, but no caller has tried yet — so
the gap is silent.

**Decision**: ship next turn — pre-emptively add before someone
hits it.

## 11. `pack()` semantics are now subtly different

**Spotted during**: Phase 1.

**Observation**: `Handle.pack(idx, cyc)` historically built a
fully-formed handle via `@enumFromInt(bits)`.  Post-refactor it
builds a handle with `debug_stamp = nil_stamp` — deref against
any pool skips the cross-pool check.

This is the test-fixture pattern, intentionally — but the name
`pack` doesn't reflect it.  A user reaching for `pack()` in
non-test code might be surprised their handle bypasses the
stamp check.

**Better name**: `unstamped(idx, cyc)` or `synthesizeForTest`.

**Decision**: defer.  Renaming touches ~10 rlsw test sites; do
in a "cleanup naming" turn, not now.

## 12. Comparison-style tests are fragile to API evolution

**Spotted during**: Phase 7.

**Observation**: 2 of the 9 inline pool tests I added in Phase 3
compared the NEW handle-side method to the OLD list-side method:
```zig
try std.testing.expectEqual(pool.get(h), h.deref(&pool));
```

When Phase 7 deleted `pool.get`, these tests broke.  Had to
rewrite them to test against the CONTRACT (pointer is writable,
deref reflects alloc/destroy state) rather than against an
alternative impl.

**Lesson**: comparison-style tests are useful as a temporary
bridge during migration but should be replaced with contract
tests before the old impl is deleted.

## 13. wasm32 atomic constraint surprise

**Spotted during**: Phase 1.

**Observation**: My initial `world_stamp` used `u64` atomics.
`zig build` (wasm32 target) errored: "expected 32-bit integer
type or smaller; found 64-bit integer type" — wasm32 atomic ops
cap at u32.

Switched to u32.  4 billion stamps per process is plenty.

**Lesson**: when designing wasm-compatible code, atomic widths
matter.

## 14. Pool ≈ single-archetype ECS world (conceptually)

**Spotted during**: post-Phase 7 reflection.

**Observation**: After the alignment, `Pool(T)` and
`ecs.Entities` look almost identical from outside.  Same verbs,
same lifecycle, same sentinel handling.  The conceptual
equivalence is now plain to see.

This argues that the rejected "duck-typed worlds" approach was
the right one to reject — they're not technically the same
thing, they just LOOK the same.  The cosmetic alignment captures
all the user benefit without the implementation complexity of
trait-based polymorphism.

**Decision**: validation of design.

## 15. Cross-world detection doesn't catch use-after-deinit

**Spotted during**: Phase 7 reflection.

**Observation**: The stamp check catches "ref from pool A used
against pool B."  But it doesn't catch "ref from pool A, pool A
was deinit'd, then ref is used against a new pool that happens
to occupy the same memory."

When `pool.deinit` is called, the struct gets zeroed.  After
deinit, `debug_stamp = 0 = nil_stamp` which SKIPS the check.

Better: `assert(!self.deinit_called)` in every public method.
Cheap, catches the use-after-deinit bug class.

**Decision**: ship in a follow-up turn (low priority — pool's
zeroed-on-deinit state already prevents derefs from succeeding
in most cases, since the data slice is empty).
