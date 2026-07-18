# CHANGELOG — turns 240-249

Per-turn journal for turns 240-249.  Prepend new entries after the
`## [Unreleased]` line; do not edit existing entries.  When turn 250
opens, this file is frozen and a fresh `changelog250-259.md` starts.

Earlier turns: see the sibling files in this directory
(`changelog230-239.md`, `changelog220-229.md`, `changelog210-219.md`,
`changelog200-209.md`, `changelog093-199.md`, `changelog001-092.md`).

## [Unreleased]

### Turn 249 — wave 2 banked; build install default fixed

**Wave 2 (`Vector3 → zmath.Vec`) banked in `zmath-adoption-plan.md`.**
Added a "✅ DONE turns 247-248" status block under the Z4 wave list
summarising the surface migrated (~507 struct-literal sites + ~195
method-call sites), the three structural hazards discovered along
the way (Rule 13 / out-param init contract / two EPA degeneracies),
the Bun-style assert module, and the turn-248 gates (1400/1400 host
tests, 100/100 smoke).  Counts as the canonical record of what Z4
wave 2 *actually delivered* — vs the speculation in the original
turn-247 plan.

**Build install default fixed.**  Zig 0.16's `standardOptimizeOption(.{
.preferred_optimize_mode = .ReleaseSmall })` does NOT mean "default
to ReleaseSmall" — it means "default to Debug; pick ReleaseSmall
when the user passes `--release`".  Discovered while running the
turn-248 audit gate: `zig build install` was silently producing
Debug-mode wasm (2.7 MB physics_pyramid) instead of the expected
ReleaseSmall (202 KB).  Fix: skip `standardOptimizeOption` entirely
and declare the option directly with the right default:
`b.option(std.builtin.OptimizeMode, "optimize", ...) orelse
.ReleaseSmall`.  Debug install is still possible via `zig build
install -Doptimize=Debug`.  Smoke and host-test paths are
unaffected (smoke has its own `-Dsmoke-optimize`; host tests use
`b.addTest` which defaults Debug).

**Audit gate:** `zig build test` 1400/1400 ✅, `zig build smoke-test`
100/100 ✅, `zig build install` produces 202 KB ReleaseSmall wasm
✅, globals 0/0/0, DAG clean.

**Files touched:** `build.zig` (optimize default), `src/notes/zmath-
adoption-plan.md` (wave 2 banked), `src/notes/changelogs/...`.

**Next.**  Discuss wave 3 priority with user.  My recommendation:
**`Vector4 → Vec`** as the next wave (smallest blast radius, ~30
call sites mostly in Color math and shader corners), then
**`Quaternion → Quat (= Vec)`** (~100 sites; collapses the
`quatStructToVec`/`quatVecToStruct` bridges added in pbr_demo /
split_screen / physics_demo / physics_pyramid / raytracer), then
**`Vector2 → @Vector(2, f32)`** (~800 sites, widest).  Rectangle
decomposition stays a separate refactor — it's an API change
(field renames `x/y/width/height → pos/size`), not a type swap.

---



**Two changes, both small, that closed out the wave-2 smoke regression:**

**1. `src/assert.zig` — Bun-style assertion helpers.**  zimr now has
three assert functions instead of `std.debug.assert`:

- `assert(ok)` — stripped in ReleaseSmall/Fast (default).  No
  message.  Suitable as a drop-in replacement for `std.debug.assert`.
- `assertf(ok, fmt, args)` — stripped in ReleaseSmall/Fast.  Args
  only evaluated on failure.  Preferred for new code: the
  formatted message localises failures even when wasm stack
  traces are unsymbolicated.
- `alwaysAssert(ok, fmt, args)` — never stripped.  For memory-
  corruption preconditions where the alternative is silent UB.

In Debug mode all three log the source location + message before
trapping via `unreachable`.  In ReleaseSafe they trap silently
(panic mechanism handles the diagnostic).  In
ReleaseSmall/ReleaseFast the check + log are stripped entirely.

**Build option `-Dassert-log=true`** forces both the check AND
the log back on in every optimize mode — for capturing
assertion failures in a near-production wasm during a debug
session without rebuilding in Debug.

Why the new module instead of `std.debug.assert`:  on
`wasm32-wasi-none` Debug, Zig's panic handler emits "reached
unreachable code" with "Cannot print stack trace: debug info
unavailable for target" — no line, no message.  The new module
logs `{file}:{line}:{col}: <message>` via `std.log.err` (which
routes through `js_log` to the browser/smoke harness) BEFORE the
trap, so the diagnostic survives the unsymbolicated wasm crash.

Pattern adopted from Bun (`src/bun.zig`'s assertion machinery).
`physics.zig` migrated to the new module (5 sites converted to
`assertf` with descriptive messages); `entities.zig`, `math.zig`,
`codecs.zig` continue on `std.debug.assert` for now — migration
deferred until a turn where touching those files is cheap.

**2. Physics dt clamp at `[0.001, 0.5]` inside the solver.**  The
old code clamped only the lower bound (`@max(dt, 0.001)`) and
documented "caller must clamp upper bound".  That contract was
fragile — every example separately did `@min(f.time.delta_time, 1/30)`
or similar.  Moved the clamp into `PhysicsWorld.step` itself via
`std.math.clamp(dt, 0.001, 0.5)`.  Upper bound at 500 ms is
generous enough for any reasonable browser frame pacing, tight
enough that a `dt = 5` from a debugger pause can't integrate the
world to infinity.

**Net effect.**  `physics_pyramid` now PASSES smoke (was the last
remaining smoke failure after the turn-248 lifetime-bug fix).
Combined with all the other turn 248 work:

- `zig build test`: **1400/1400 PASS** ✅ (+1 from `assert.zig`'s test)
- `zig build smoke-test`: **100/100 PASS** ✅
- `zig build install`: green
- Globals: 0/0/0, DAG: green

**Files touched this half-turn:**  `build.zig` (assert-log option,
build_options wiring), `src/assert.zig` (new file), `src/tests.zig`
(test discovery), `src/physics.zig` (dt clamp + assertf migration —
already done; verified in place), `src/notes/changelogs/...`.

**Update after running smoke:**  The new `assertf` with descriptive
message immediately surfaced what `std.debug.assert` had hidden —
the pyramid panic was `assert failed at assert.zig:115:19: epa loop:
polytype full, edges_count=16 polytype.len=16` (line 3340 in
physics.zig).  Deep-overlap box-box pairs in the settling pyramid
consume all 16 polytope vertex slots without converging.  Fix:
replace the assert with an early `return epaResult(... min_index
...)`, same shape as the iter-cap exit a few lines below.  Worst
case is a slightly imprecise contact normal, smoothed away by the
position-correction pass within a few substeps.  With both fixes
(out-param init contract + EPA graceful bail) smoke is **100/100
PASS** — the wave-2 regression is fully closed.

**Latent issue noted (not introduced this turn):** `zig build
install` builds Debug by default in Zig 0.16; `preferred_optimize_mode`
in `standardOptimizeOption` is now what `--release` chooses, not
the default mode.  Production builds need `zig build --release=small
install`.  Has been like this since Zig 0.16 adoption; flagged for
a one-line fix next turn (just change build.zig to set the default
mode explicitly instead of relying on `preferred_optimize_mode`).

---



**Why.**  Smoke tests in Debug mode surfaced opaque wasm OOBs in 9
examples (png_demo, gallery, models3d, physics_demo, physics_pyramid,
first_person_camera, load_image_demo, shader_uniforms, text_layout)
after the Z4 wave 2 Vector3-flip.  Initial extern-struct UB fixes
(Camera3D/Transform/Ray/BoundingBox/Model/VrStereoConfig → plain
`struct` per new Rule 13) cleared cube3d but not the other 9.

**Root cause turned out to be framework-level, not type-level.**  The
old contract `fn initState(gpa, *Frame) !State` returned State by
value; the runtime did `state_ptr.* = try init_fn(...)` which copies
the State from initState's stack to heap.  Examples doing
`s.log = s.log_browser.logger()` captured `&s.log_browser` — a
pointer into the about-to-die stack frame.  After the copy, every
subsequent `log.info(...)` deref'd a dangling pointer.  Pre-Z4 the
bug was masked (RVO, smaller State sizes, ReleaseSmall's optimizer
sometimes elided the copy); the 16-byte Vec changed enough about
stack layout that it started firing reliably in Debug.

**Fix: out-param contract.**  `pub fn run`'s init signature is now
`fn (Allocator, *Frame, *State) !void`.  Framework allocates State,
hands the pointer in, init writes into it via `state.* = .{...}`.
Internal pointers (loggers, future self-referential caches) now
record the final heap address.

**Migration.**  Mechanical conversion of 99 example `initState`
bodies via `/tmp/migrate_init.py`.  Three sub-patterns handled:
typed `var s: State = .{...};`, untyped `var s = State{...};`, and
direct `return .{...};`.  Three hand-fixes for callsites that
passed `&state` where state was now `*State` (physics_demo,
physics_pyramid, ui_log_viewer).

**Impact.**  Smoke 76→**99 PASS / 1 FAIL** (was 9 fails, now 1 — and
the remaining one is `physics_pyramid` panicking with "reached
unreachable code" at frame #5, which is a real physics bug for next
turn, not a layout bug).

**Other deliverables this turn:**
- `Camera3D`/`Transform`/`Ray`/`RayCollision`/`BoundingBox`/`Model`/
  `VrStereoConfig`/`Camera2D` flipped `extern struct` → `struct`
  per new Rule 13.  `Mesh` kept extern (pointer-only fields are
  C-ABI-safe).
- Rule 13 added to `claude.md`: `extern struct` only at real FFI
  seams; `@Vector` is never C-ABI-compatible.
- `smoke-test` build defaults to Debug (was ReleaseSmall).  Separate
  output dir `zig-out/smoke/web/` so production install
  (`zig-out/web/`) stays clean.  `smoke.ts` honors `--web-dir`,
  dumps full err.stack + own-properties, brackets each frame call
  with frame-number-tagged exception wrapper.
- EPA crash fixed: when GJK short-circuits on near-coincident
  centers, seed the Minkowski simplex with 4 spread-direction
  support probes so EPA's polytope reads valid points.  `zig build
  test` 1398→1399.

**Audit gate:** `zig build test` 1399/1399 ✅.  `zig build
smoke-test` 99/100 (physics_pyramid only).

**Files touched:** `build.zig`, `src/zimr.zig` (run signature),
`src/types.zig` (8 extern→struct flips), `src/physics.zig` (GJK
seed fix), `src/runtime.zig`, `src/notes/claude.md` (Rule 13),
`webtests/smoke.ts`, `examples/*.zig` (99 examples, mechanical).

**Next.**  Investigate `physics_pyramid` unreachable at frame #5.
Tall-stack solver instability — possibly NaN propagation in
sequential-impulse, or an index overflow somewhere.

---


**The turn-243 Z4a/Z4b ordering was wrong, and the camera proved
it.**  "Compute surface first, against the current storage types"
forces conversion scaffolding (`v3ToZm`/`v3FromZm`/`v3Add` bridge
helpers) whose only reason to exist is that the type is
*temporarily* the wrong shape — an incoherent intermediate state.
`Camera3D.position`/`.target`/`.up` made it obvious: the camera is
internal compute state, there is no reason its fields are a
named-field struct, and "convert at every call site" is pure waste.

**Plan rewritten — Z4 is now type-by-type vertical migration.**  Go
one storage type at a time; for each, flip the type definition AND
fix every call site (compute and storage both) in one coherent
wave, gates green at the end.  No scaffolding — once the type *is*
`Vec`, compute sites use native `@Vector` operators / `zmath.*`
directly and storage sites just hold the value.  The decision-2 ★
end-state, made concrete: `Vector3`/`Vector2`/`Vector4` all become
`zmath.Vec` (`@Vector(4,f32)`) outright — `pub const Vector3 = Vec`,
the same type, the "3-ness" being which *function* you call (`dot3`
vs `dot4`), zmath's own model.  `Quaternion` → `Quat`.  Named-member
access (`.x/.y/.z`) is gone — `v[0]/v[1]/v[2]`.  `[3]f32`/`[2]f32`
appear *only* where space measurably matters (packed vertex
buffers — already raw `[N*3]f32`, not `[]Vector3`).  Verified safe:
nothing depends on `Vector3` being 12 bytes (no `@sizeOf`/
`@ptrCast`/packed embedding).  Wave order, smallest blast radius
first: `Camera3D` → scene/physics → drawing → remaining storage
sites → 2D ops → collapse conversion layer + delete `zimrmath.zig`.

**Wave 0 done — `math.zig` ergonomic constructors.**  Added `vec3(x,
y,z)` (direction, lane 3 = 0), `point3(x,y,z)` (point, lane 3 = 1),
`vec2(x,y)` (lanes 0,1) so the ~560 call sites that build vectors
read cleanly instead of `f32x4(x, y, z, 0)` with an easy-to-flip
trailing lane.  The array↔`Vec` packed-storage boundary already
exists in zmath (`loadArr2`/`loadArr3`/`loadArr4`, `vecToArr2/3/4`)
— no new conversion helpers needed.  These are *constructors*, not
operation-wrappers — no `v3Add`/`v3Scale`-style wrappers get
introduced (a wrapper around `+` earns nothing; if a packed-buffer
op ever proves a measured perf problem, `arrayAdd` etc. get added
then, proven by benchmark).  `vec3`/`point3`/`vec2` surface as
`z.*` via the autogen.

**Audit:** ALL GATES GREEN — install exit 0, `zig build test`
1426/1426 (+3 = constructor tests), math-test 130/130 (+3), smoke
100/100, fmt clean, globals 0/0/0.

**Files touched:** `src/notes/zmath-adoption-plan.md` (Z4 section +
decision-2 table/consequences/migration-order rewritten for the
type-by-type approach), `src/math.zig` (`vec3`/`point3`/`vec2`
constructors), `src/zimr.zig` (regenerated — constructors surface),
`docs.html`.

**Next — Z4 wave 1: `Camera3D`.**  Flip `position`/`target`/`up` to
`Vec`; fix `runtime.zig`'s camera code and the ~19 examples that
build a camera.  The turns 243-246 bridge helpers in
scene/physics/runtime/drawing collapse to nothing in waves 2-3 —
the bridge body *was* the conversion.

### Turn 246 — Z4a: runtime.zig migrated; style Rule 12; "all math through zmath"

**Style Rule 12 added** (`claude.md`) — don't read a variable in the
same aggregate literal that overwrites it.  Zig fills a literal in
place field-by-field (no complete temporary, unlike a C compound
literal), so `v = .{ .a = f(v), .b = g(v) }` lets `.b` see the
already-overwritten `.a`.  This is the generalized rule behind the
turn-245 sphere bug; the entry carries the simple before/after
example.

**`runtime.zig` Z4a migration — 36 `vector3*` calls, all in the
camera code.** `getCameraForward`, `cameraMoveForward`, `cameraYaw`,
`cameraPitch`, the world↔screen projection helpers — all migrated
off `zimrmath` onto `zmath`, via a set of thin `v3*` bridge helpers
(`v3Normalize`, `v3Cross`, `v3Distance`, `v3Angle`, `v3Negate`,
`v3RotateByAxisAngle`, `v3Transform`, `v3Unproject`, plus `v3Add`/
`v3Sub`/`v3Scale`) that convert the `Vector3` storage struct to/from
the `Vec` compute type at the boundary.  All 7 non-trivial bridges
verified equivalent to the old `zimrmath` implementations
empirically (7/7 pass) before relying on them.  `zimrmath`
dependency fully removed from `runtime.zig`.

**Course-correction mid-turn: ALL math goes through zmath — even
storage-to-storage `add`/`sub`/`scale`.**  The first pass routed the
20 add/sub/scale sites through `Vector3`'s own struct *methods*
(`cam.position.add(forward)`) — convenient, already there, no
`zimrmath` dependency.  But the owner's call: those bespoke struct
methods are exactly what the arc eliminates; "convenient" is not a
reason to keep a non-zmath math path.  Redone — added `v3Add`/
`v3Sub`/`v3Scale` bridges that go through the zmath compute type
(native `@Vector` `+`/`-`/`* @splat`).  Recorded as a decision-2
clause: if a storage-to-storage op ever proves a *measured* perf
problem, the fix is a dedicated `arrayAdd`/`arrayDot`/… in
`math.zig` — added then, proven by a benchmark, not speculatively.

**Audit:** ALL GATES GREEN — install exit 0, `zig build test`
1423/1423, math-test 127/127, smoke 100/100 (every camera-driving
example is a smoke target), fmt clean, globals 0/0/0.

**Files touched:** `src/runtime.zig` (36 calls migrated via `v3*`
bridges; `zimrmath` import removed; 2 stale comments updated),
`src/notes/claude.md` (style Rule 12), `src/notes/zmath-adoption-plan.md`
(decision 2 — all-math-through-zmath clause), `docs.html`.

**Next — Z4a's last leaf:** `drawing.zig` (38 `vector3*` calls + 1
`quaternionSlerp`).  Same bridge-helper pattern; watch for the
self-aliasing hazard (Rule 12) as the `vector3*` call sites move.

### Turn 245 — fixed a pre-existing sphere-rendering bug (self-aliasing struct literal)

**Bug report:** spheres in `physics_demo` rendered "small and broken."
A `models3d` standalone (static sphere next to cube/cylinder/capsule/
cone) confirmed it: every other primitive was perfect, only the
sphere was a tiny crumpled cluster of triangles at the *top* of its
(correctly-sized, correctly-positioned) bounding box — "triangles
clustered at the pole."

**Not a Z4a regression.** `drawSphereEx` is byte-identical to the
turn-225 snapshot — before the zmath arc even started — so this is
a *pre-existing* porting bug, not migration fallout.  Verified the
algorithm itself is correct by tracing raylib's exact logic in
Python: it produces a proper sphere (Y spanning -1 to +1).  But
tracing the *same logic with zimr's real `Vector3` struct type* gave
Y in [0.24, 1.0] — only the north-pole cap.  Same algorithm,
different result → the bug is in the Zig struct semantics, not the
math.

**Root cause — self-aliasing struct literal is not atomic in Zig.**
The incremental rotation `verts[n] = .{ .x = f(verts[n].x,
verts[n].z), .z = g(verts[n].x, verts[n].z) }` writes `.x` into the
result location *first*, then evaluates `.z`'s expression — which
now reads the already-overwritten `.x`.  C compound literals build a
complete temporary before assigning, which is why the line-by-line
port looked correct.  Confirmed with a minimal repro: `v = .{ .x =
v.x + v.z, .z = v.x - v.z }` yields the wrong `.z`.  The Y-rotation
lost magnitude every slice step, so the vertex band never descended
from the pole.

**Fix:** capture the old field values into locals before building
the new struct — for all three self-aliasing assignments in
`drawSphereEx` (the `verts[2]`/`verts[3]` Y-rotations in the slice
loop, the `verts[3]` Z-rotation in the ring advance).  Re-traced
with zimr's `Vector3`: Y range back to [-1.0, 1.0], a full sphere.
Scanned the rest of `drawing.zig` for the same pattern — the
sphere/capsule-family `const wN = .{ ... }` assignments read from
*other* variables (not self-aliasing), so they were already safe;
`drawSphereWires` uses per-vertex trig (different algorithm), also
safe.  `drawSphereEx` was the only victim.

**Regression test added** — `drawSphereEx: ring/slice generation
spans the full sphere` (inline in `drawing.zig`, next to the
function).  Replays the exact generation loop and asserts the
emitted vertices reach both poles (`y_min < -0.99`, `y_max > 0.99`).
Pre-fix this produced Y in ~[0.24, 1.0] and would have failed.

**Audit:** ALL GATES GREEN — install exit 0, `zig build test`
**1423/1423** (+1 = the new regression test), math-test 127/127,
smoke 100/100, fmt clean, globals 0/0/0.  Rebuilt the `models3d`
and `physics_demo` standalones with the fix.

**Files touched:** `src/drawing.zig` (`drawSphereEx` — 3 self-
aliasing assignments fixed + regression test added), `docs.html`.
Standalone bundles at `prebuilt/standalone/{models3d,physics_demo}.html`
(copied to outputs).

**Next — Z4a continues:** `runtime.zig` (37 `vector3*` calls), then
`drawing.zig` (38 — and worth watching for more of this
self-aliasing pattern as those `vector3*` calls migrate).

### Turn 244 — Z4a verification pass: a real precondition surfaced + asserted

A careful re-verification of turn 243's `scene.zig` + `physics.zig`
migration — and it earned its keep.

**A genuine precondition surfaced: `rotateByQuat` needs a unit
quaternion.** Re-running the equivalence probe at a tight tolerance
(`1e-5`, vs turn 243's looser check) showed `zmath.rotate`
*disagreeing* with the old `zimrmath.vector3RotateByQuaternion` —
not float noise, a real divergence.  Root cause: the two use
different formulas.  `zmath.rotate` is the standard
unit-quaternion form (exact only for `|q| = 1`); zimrmath's was the
un-normalized rotation-matrix form, which absorbed a non-unit `|q|`
differently.  **For unit quaternions they are identical to 6+
decimals** — re-verified with `quatFromAxisAngle` outputs (always
unit) and a rotate/conjugate round-trip.  Physics maintains unit
orientations (the integrator calls `quatNormalize` every step;
`quatFromAxisAngle` is always unit; `quatConjugate` preserves
unit-ness), so the migration is *correct* — but the precondition
was previously *implicit* and is now made explicit.

**Asserted, not just commented.** `rotateByQuat` now carries a
debug-only precondition check — `|q|²` within 1% of 1 — gated on
`std.debug.runtime_safety` so it compiles out of the shipped
ReleaseSmall wasm but fires in test/debug builds.  The 1% band is
wide enough for normal integration FP drift, tight enough to catch
a genuine "forgot to normalize" bug loudly at the call site instead
of letting it silently scale the simulation.  `scene.zig`'s
`rotateVector` got the same precondition documented (its caller
passes `SceneTransform.rotation`, unit by default).  All six Z4a
bridges re-verified equivalent under the documented unit-quaternion
precondition: 6/6 pass.

**`claude.md` — added rule 5b: re-read the whole file every 15
turns.**  Rule 5 keeps the *style guide* fresh every 3 turns; 5b
keeps everything else fresh (toolchain, per-turn rules, the
standalone-build instructions) — over a long arc it is easy to
drift from a documented convention that isn't exercised every turn.
Tracked the same way: "Read full claude.md on turn N."

**Standalone bundles built — via the canonical script.**  `claude.md`
and the README already document `scripts/build_standalone.py`; used
it (not a hand-rolled inliner) to produce `cube3d` and
`physics_demo` single-file HTML bundles.  Both verified clean (no
stray ES `export`, `zimrRun` present, wasm magic intact).  These
are the visual confirmation that the cube and the physics sim
survived the Z4a quaternion/vector migration.

**Audit:** ALL GATES GREEN — install exit 0, `zig build test`
1422/1422 (the new debug assert is live in the test build and every
`rotateByQuat` call passes it — confirms all callers really do pass
unit quaternions), math-test 127/127, smoke 100/100, fmt clean,
globals 0/0/0.

**Files touched:** `src/physics.zig` (`rotateByQuat` precondition
doc + debug assert), `src/scene.zig` (`rotateVector` precondition
doc), `src/notes/claude.md` (rule 5b), `docs.html`.  Standalone
bundles at `prebuilt/standalone/{cube3d,physics_demo}.html` (and
copied to outputs).

**Next — Z4a continues:** `runtime.zig` (37 `vector3*` calls),
then `drawing.zig` (38).

### Turn 243 — "zmath all the way down" direction set; Z4a begins (scene + physics)

**Direction decided (owner, turn 243).** The end-state: the system
uses **zmath everywhere**, with raw fixed-size arrays (`[N]f32`)
only where layout is genuinely forced — storage and transfer.  No
bespoke `extern struct` math types survive.  This supersedes the
three-clause rule's *end-state* (it answered "may this type
collapse?"; the real question was "what is the end-state type?").
Recorded as decision 2's ★ CURRENT RULE, with the per-type table:
`Vector3`→`[3]f32` storage, `Vector2`→`[2]f32`, `Quaternion`→
`zmath.Quat` outright (a quaternion *is* 4 floats — no size penalty,
storage = compute type, zero conversion), `Vector4`→`[4]f32`/`Vec`.
Migration order: **compute surface first, storage types second** —
migrating `vector3Normalize(v)` works whether `v` is a struct or an
array, so the compute surface moves against the current storage
types (proven Z3 rhythm), then the storage flip is field-access
syntax only.  `Z4` in the plan rewritten into `Z4a` (compute
surface) + `Z4b` (storage flip + delete `zimrmath.zig`).

**Z4a started — leaf-first by call count.**

**`scene.zig` (2 calls) — done.** `vector3Transform` → `zmath.mul`
(row-vector point transform, w=1); `vector3RotateByQuaternion` →
`zmath.rotate`.  `zmath_conv` kept only for the `vector3FromZm`
conversion helper (goes away in Z4b).

**`physics.zig` (25 calls) — done, and a real convention trap
caught.** 16× `vector3RotateByQuaternion`, 6× `quaternionFromAxisAngle`,
plus `quaternionMultiply`/`quaternionNormalize`.  Added four thin
`inline` bridge helpers (`rotateByQuat`, `quatFromAxisAngle`,
`quatMul`, `quatNormalize`) over the `zmath` API that convert the
`Vector3`/`Quaternion` storage structs at the boundary — keeps the
25 call sites readable and makes Z4b mechanical.  **The trap:**
empirical verification before migrating found `zmath.qmul` has the
*opposite operand order* — `zimrmath.quaternionMultiply(a, b)` ==
`zmath.qmul(b, a)` — exactly analogous to the matrix `mul`
reversal.  The `quatMul` bridge passes operands reversed, with the
fact documented.  (`quaternionFromAxisAngle`, `vector3RotateByQuaternion`,
`quaternionInvert` were verified to match directly — no reversal.)
`zimrmath.zig` dependency fully removed from `physics.zig`.

**Audit:** ALL GATES GREEN — install exit 0, `zig build test`
1422/1422 (physics correctness tests pass — the `qmul` reversal was
a genuine trap and the tests confirm it was handled right),
math-test 127/127, smoke 100/100, fmt clean, globals 0/0/0.

**Files touched:** `src/notes/zmath-adoption-plan.md` (decision 2 ★
CURRENT RULE + per-type table + migration order; Z4 rewritten as
Z4a/Z4b), `src/scene.zig` (2 calls migrated), `src/physics.zig`
(25 calls migrated via 4 bridge helpers; `zmath_conv` removed),
`docs.html`.

**Next — Z4a continues:** `runtime.zig` (37 `vector3*` calls) then
`drawing.zig` (38 `vector3*` + the bridges).  Both are pure
`vector3*` on storage structs — the physics bridge-helper pattern
applies directly, and `vector3Add`/`Sub`/`Scale` become native
`@Vector` operators (`+`/`-`/`* splat`) since zmath has no `add`/
`sub`/`scale` functions — the most "zmath" form possible.

### Turn 242 — Z4: the matrix shims deleted from zimrmath.zig

The matrix layer comes out.  `zimrmath.zig`: 2531 → 2182 lines
(−349).  What was deleted, what stayed, and the test fallout:

**Deleted from `zimrmath.zig`** — ~21 matrix functions in three
regions: the `matrixMul`..`matrixToFloatV` shim block (turn-234
shims over `math.zig`), their shim-test block, `matrixCompose` /
`matrixDecompose` + their test, and the `matrixToZm` / `matrixFromZm`
identity pair (the Z1 conversion layer — identity since the `Matrix`
collapse).  Each region replaced with a short note pointing at
`math.zig` as the matrix API.

**One real internal caller fixed.** `vector3Unproject` (a surviving
function) still called `matrixMul` / `matrixInvert` internally —
migrated to `zm.mul` (operand-reversed) / `zm.inverse`.  Four other
internal references were in test blocks for the surviving bridges
and just needed `matrixIdentity()` → `zm.identity()`.

**What stayed — the bridges and the compute surface.**
`vector2Transform`, `vector3Transform`, `quaternionFromMatrix`,
`quaternionToMatrix`, `quaternionTransform` are storage↔compute
bridges (storage struct in or out); they are not matrix shims and
remain.  So does the whole `Vector2/3/4` + `Quaternion` compute
surface.  `zimrmath.zig` is now *only* that.

**Test fallout — handled honestly, not patched over.**
- `src/tests/matrix_test.zig` — **deleted** (and dropped from
  `src/tests.zig`).  Its entire purpose was testing the
  `zimrmath.zig` matrix *shims*; with the shims gone it tested
  nothing real.  Verified first that its coverage genuinely lives
  elsewhere: `math.zig`'s own 127-test suite (`zig build math-test`)
  covers `mul`/`inverse`/`transpose`/builders, and
  `transform_order_test.zig` covers the zimr-specific
  composition-order semantics.  Not deleting blindly — confirming
  the safety net exists, then removing the redundant scaffold.
- `src/tests/transform_order_test.zig` — migrated to `zmath`
  (`math.zig`): builders → `translation`/`scaling`, `matrixMul(A,B)`
  → `zmath.mul(B,A)` with the operand reversal.  Kept its
  `zimrmath` import solely for `quaternionToMatrix` (a surviving
  bridge).  Its operand-order *semantics* are unchanged — it still
  pins T*R*S compose, root-outermost fold, and proj*view order.
- `src/tests/zm_conversion_test.zig` — **rewritten.** Dropped the
  now-meaningless `matrixToZm/matrixFromZm are the identity` test
  (those functions no longer exist).  Kept the 4 vector/quaternion
  round-trip tests and the 3 `vector3Transform` vs `zm.mul`
  cross-convention tests — all still testing real surviving code —
  with the matrix builders migrated to `math.zig` and the
  misleading `zmath`-for-`zimrmath.zig` alias renamed to `conv`.

**`gen_flat_exports.py`** — the 19 `zimrmath` matrix-shim `SKIP`
entries from turn 241 were removed: the functions they referenced
no longer exist, so the entries were dead config.  Regenerated
`zimr.zig`; the bridges remain flat-exported, the (now-deleted)
shims are simply absent.

**Audit:** ALL GATES GREEN — install exit 0, `zig build test`
**1422/1422** (down from 1449: −27 = the deleted `matrix_test.zig`
tests + the dropped identity test, all of which exercised deleted
code), math-test 127/127, smoke 100/100, fmt clean, globals 0/0/0.

**Files touched:** `src/zimrmath.zig` (−349 lines: matrix layer
deleted, `vector3Unproject` migrated), `src/tests/matrix_test.zig`
(deleted), `src/tests.zig` (matrix_test reference removed),
`src/tests/transform_order_test.zig` (migrated to `math.zig`),
`src/tests/zm_conversion_test.zig` (rewritten), `src/zimr.zig`
(regenerated), `scripts/gen_flat_exports.py` (dead `SKIP` entries
removed), `docs.html`.

**Next — Z4 wind-down, then the compute-surface phase.** `Matrix`
is fully `zmath.Mat`; the matrix API is `math.zig`-only.  What's
left of the zmath-adoption arc: relocate the surviving
`Vector2/3/4`+`Quaternion` storage structs to `types.zig` (decision
6 end-state), then the genuinely separate phase — migrating or
reconsidering the `Vector3`/`Quaternion` compute surface itself
(the `[3]f32`-storage question from the turn-241 decision-2 note
belongs here).

### Turn 241 — public matrix surface: raylib-named shims removed from `z.*`

Follow-through on turn 240's "do what zmath is doing" decision.
Turn 240 migrated the *examples* off the raylib-named matrix API
and confirmed the shims were caller-less; this turn removes the
raylib-named `matrix*` aliases from the **public flat surface**
itself, so `z.*` exposes only zmath's vocabulary.

**`gen_flat_exports.py` — `SKIP` list extended.** The autogen is
first-writer-wins with `math.zig` listed before `zimrmath.zig`, so
zmath-named exports (`mul`, `inverse`, `identity`, `translation`,
`rotationX/Y/Z`, `perspectiveFovRhGl`, `lookAtRh`, `matToArr`, …)
already came from `math.zig`.  But `zimrmath.zig`'s shims have
*different* names (`matrixMul`, `matrixInvert`, …) — not collisions,
so the autogen emitted them too, as parallel raylib-flavoured
aliases.  Added all 17 pure matrix shims plus the
`matrixToZm`/`matrixFromZm` identity pair to `SKIP`: they are
internal scaffolding, not API.  Every concept is already on the
flat surface under its zmath name, verified function-by-function
before adding the entries.

**What deliberately stays.** `quaternionFromMatrix`,
`quaternionToMatrix`, `quaternionTransform`, `vector2Transform`,
`vector3Transform` are *not* in `SKIP` — they are
storage↔compute **bridges** (`Matrix`/`Vector`/`Quaternion` storage
structs in or out), not raylib-flavoured duplicates of any
`math.zig` function.  Same logic turn 240 used to keep
`quaternionFromMatrix`: "do what zmath is doing" means drop the
*duplicates*, not the *bridges*.  They retire with the
Vector3/Quaternion compute-surface phase, not now.

**Result.** `src/zimr.zig` regenerated: 20 zmath-named matrix
exports on the public surface, **zero** raylib-named `matrix*`
shims.  No internal code and no example depended on the removed
`z.matrix*` aliases — they were dead names on the public API.

**Also recorded:** the "named-field access is overrated" input from
the previous turn is noted under decision 2 in
`zmath-adoption-plan.md` — it strengthens the case for `[3]f32`
storage but does not overturn decision 2, because clause 1 (the
16-vs-12-byte hazard) is independent of the names question.

**Audit:** ALL GATES GREEN — install exit 0, `zig build test`
1449/1449, math-test 127/127, smoke 100/100, fmt clean, globals
0/0/0.

**Files touched:** `scripts/gen_flat_exports.py` (`SKIP` extended
with 19 zimrmath matrix-shim entries), `src/zimr.zig` (regenerated),
`src/notes/zmath-adoption-plan.md` (decision 2 — names-access note),
`docs.html`.

**Next — Z4 proper, the physical deletion.** The matrix shims in
`zimrmath.zig` now have zero *code* callers (only the now-removed
re-exports referenced them).  But they cross-reference each other —
`matrixRotateXYZ` calls `matrixMul`, and the turn-234 shim test
block exercises ~all of them — so deletion is a *block* operation:
remove the ~22 matrix functions + their test block as a unit, while
leaving the `quaternion*`/`vector*` bridges and compute surface
intact.  After that `zimrmath.zig` is purely the Vector3/Quaternion
compute surface.

The open design question from turn 239 — should the public API
expose `z.matrixMul` (raylib-shaped) or `z.mul` (zmath-shaped) —
resolved by the principle **"when in doubt, do what zmath is
doing."**  The public surface exposes zmath's names and conventions;
the `zimrmath.zig` matrix shims were scaffolding and come down
rather than getting a permanent raylib-flavoured facade.

**`gen_flat_exports.py` — `pub inline fn` now surfaces.** The
decl-matching regex only caught `pub fn`, not `pub inline fn`. zmath
marks small constructors (`f32x4`, …) as `pub inline fn`, so they
were silently absent from the flat `z.*` surface — `z.f32x4` did not
exist. Fixed the regex (both the collector and the
already-declared-names scanner). `z.f32x4` and the other inline
zmath constructors now surface; the examples need `z.f32x4` to build
`Vec` arguments for `z.lookAtRh`.

**All examples migrated to the zmath matrix names.** ~20 call sites
across 6 files:
- `gltf_{model_refs,simple,textured}.zig` — `z.matrixRotateY` →
  `z.rotationY` (pure rename).
- `rlsw_side_by_side.zig` — `matrixTranslate`/`matrixRotateX/Y` →
  `translation`/`rotationX/Y`; and the MVP compose
  `z.matrixMul(projection, modelview)` → `z.mul(modelview,
  projection)` — the **operand reversal**, since `z.mul(A,B)` is
  math `B*A`.
- `pbr_demo.zig` / `split_screen.zig` — `matrixLookAt` →
  `z.lookAtRh` (Vector3 args wrapped in `z.f32x4(…, 1)` / `…, 0`),
  `matrixInvert` → `z.inverse`.

**The bridge that stays — `quaternionFromMatrix`.** First migrated
`quaternionFromMatrix` → `quatFromMat` as if it were a pure rename;
the build caught it — `z.quatFromMat` returns zmath's *compute*
`Quat` (`@Vector(4,f32)`), but `SceneTransform.rotation` is a
`Quaternion` *storage struct*. `zimrmath.quaternionFromMatrix(mat)
Quaternion` is a genuine storage↔compute **bridge** (`Matrix` in,
storage struct out), not a raylib-flavoured duplicate of any
`math.zig` function. Reverted: the examples keep
`z.quaternionFromMatrix`. "Do what zmath is doing" means drop the
*duplicates*, not the *bridges* — recorded in decision 5.

**This clears the Z4 runway.** A caller census now shows the
`zimrmath.zig` matrix shim layer has **only two functions with live
callers**: `quaternionFromMatrix` (4 — the bridge, stays) and
`vector3Transform` (6 — takes `Vector3`, the deferred compute
surface). Every other matrix shim — `matrixMul`, `matrixIdentity`,
`matrixInvert`, all builders, `matrixToZm`/`matrixFromZm`,
`quaternionToMatrix`, `quaternionTransform`, `vector2Transform`,
`matrixToFloatV` — has **zero callers** and can be deleted outright.

**Audit:** ALL GATES GREEN — install exit 0, `zig build test`
1449/1449, math-test 127/127, smoke 100/100 (every migrated example
is a smoke target — `rlsw_side_by_side`'s MVP debug-log path would
visibly diverge if the operand reversal were wrong), fmt clean,
globals 0/0/0.

**Files touched:** `scripts/gen_flat_exports.py` (`pub inline fn`
regex fix), `src/zimr.zig` (regenerated — `z.f32x4` etc. now
surface), `examples/gltf_model_refs.zig`, `examples/gltf_simple.zig`,
`examples/gltf_textured.zig`, `examples/rlsw_side_by_side.zig`,
`examples/pbr_demo.zig`, `examples/split_screen.zig`,
`src/notes/zmath-adoption-plan.md` (decision 5 extended), `docs.html`.

**Next — Z4 proper.** Delete the ~20 caller-less matrix shims from
`zimrmath.zig` (keep `quaternionFromMatrix` + `vector3Transform`
and the `vector*`/`quaternion*` compute surface). Then `SKIP` any
now-orphaned names in `gen_flat_exports.py` so the flat surface
tracks only what still exists, regen, and confirm gates. After that
`zimrmath.zig` is purely the Vector3/Quaternion compute surface —
ready for its own migration phase or relocation to `types.zig`.
