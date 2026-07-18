# api-flatten plan — zimr public surface

> Drafted Turn 202.  Status as of Turn 203:
> - **F1** ✅ shipped Turn 202 — 1131 flat aliases at `z.X`
> - **F2** ✅ shipped Turn 203 — 2166 call-site rewrites; dotted
>   form still works for the 7 deep paths (`z.runtime.effects.X.Y`)
>   and as a soft-cutover safety net
> - **F2.5** ✅ shipped Turn 203 — collision rename arc
>   (entities/scene/physics/gpu renamed in source; back-compat type
>   aliases dropped).  No SKIP list survives.
> - **F3** ✅ shipped Turn 203 — sub-namespace dotted exports
>   (`shapes`, `text`, `textures`, `models`, `camera`, `gestures`,
>   `shaders`, `core`, `input`, `effects`, `allocator`) converted to
>   PRIVATE file-scope `const` bindings.  External `z.shapes.X` etc.
>   no longer resolves.  Whole-module aliases (`drawing`, `runtime`,
>   `gpu`, `rlgl`, `rlsw`, etc.) kept for deep paths + unflat
>   modules.
>
> **API-FLATTEN ARC COMPLETE** — 1135 flat aliases at the public
> surface; no cross-namespace name collisions; one canonical name
> per concept; sub-namespace dotted access is now a compile error.

## Goal

End state: every public symbol in zimr is reached as `z.theName`,
not `z.namespace.theName`.  Internal source organization (the
`pub const shapes = struct {...}` blocks inside `drawing.zig`)
stays unchanged — only what `zimr.zig` re-exports changes.

## Guiding principle: **favor reader and grepper always**

Every design call in this plan is decided by asking which option
better serves the person reading the code or grep-jumping through
it.  Concretely:

- **Greppable**: every public name is a unique exact-string token.
  `grep z.drawText` finds all callers of one specific function.
  `pub usingnamespace ns;` is rejected for the same reason — it
  hides where names come from.  Each alias gets an explicit
  `pub const drawText = text.draw;` line.
- **Readable in isolation**: a function name read on its own should
  identify what kind of thing it does.  `step` fails (which
  subsystem?  physics, scene, ecs?); `physicsStep` passes.
  `init` fails; `ecsInit` passes.  `drawRectangle` passes by
  itself.  Math primitives at the base of the algebra
  (`lerp`, `clamp`, `dot`) are universally understood and earn
  the short name — they're the exception where the standalone
  reader has enough context from the symbol alone.
- **One canonical name per thing**.  No parallel aliases in the
  final state — by F3 the dotted form is gone.  During F1→F2 the
  dotted form still works ONLY as a migration aid; it disappears
  at F3.

## Migration philosophy (per Simon's call)

**Soft cutover.**  At each step both forms work.  Only the FINAL
turn removes the dotted-namespace exports.  This means:

- No mid-migration breakage.  At any point during the arc, the
  smoke suite passes and every example compiles.
- Examples migrate at their own pace (one-time sed pass per
  namespace).
- The only "breaking" turn is the final one that deletes
  `pub const text = ...` etc., and by that point nothing references
  the dotted form anyway.

**Naming.**  Per "favor reader and grepper always": every public
name becomes findable by exact-string grep in one file
(`zimr.zig`), and reads correctly in isolation without needing
namespace context.

Most function names already carry a verb + noun and just drop their
namespace prefix.  Where the function name was bare (relying on the
namespace for meaning), the namespace name gets baked into the flat
name.  Both halves stay greppable.

**Flatten map** (full set — every namespace flattens, no exceptions):

| Namespace | Treatment                                                      |
|-----------|----------------------------------------------------------------|
| shapes    | drop namespace: `drawRectangle`, `drawCircle`, ...             |
| text      | rename bare names: `draw`→`drawText`, `measure`→`measureText`, `deinit`→`deinitFontCache`; everything else drops ns |
| textures  | drop namespace: `loadTexture`, `drawTexture`, `imageDrawPixel`, ... |
| models    | drop namespace: `loadModel`, `drawModel`, `genMeshCube`, ...   |
| shaders   | drop namespace: `loadShader`, `beginShaderMode`, ...           |
| camera    | drop namespace: `updateCamera`, `getWorldToScreen`, ...        |
| gestures  | drop namespace: `updateGestures`, `getGestureDetected`, ...    |
| core      | drop namespace: `getScreenWidth`, `getRenderHeight`, `getTime`, ... |
| input     | drop namespace: `getMousePosition`, `isKeyPressed`, ...        |
| gl        | drop namespace + rename: `clear`→`clearBackground`, `viewport`→`setViewport` |
| types     | drop namespace: `Color`, `Rectangle`, `Vector2`, `Image`, ...  |
| easings   | drop namespace: `easeLinearIn`, `easeQuadOut`, ... (already prefixed) |
| ui        | drop namespace: `UiContext`, `Ui`, `MouseCursor`, `KeyChord`, ... |
| effects   | rename: `init`→`effectsInit`, `deinit`→`effectsDeinit` (sub-namespaces stay nested AS TYPES, e.g. `z.Loader`, `z.Clock`, `z.Rng`) |
| entities  | rename to `ecs` prefix: `init`→`ecsInit`, `update`→`ecsUpdate`, `create`→`ecsCreate`, `destroy`→`ecsDestroy`, `query`→`ecsQuery` |
| physics   | prefix bare names: `step`→`physicsStep`, `init`→`physicsInit`, `applyForce`→`physicsApplyForce` |
| scene     | prefix bare names: `step`→`sceneStep`, `update`→`sceneUpdate`, `addNode`→`sceneAddNode` |
| render    | prefix bare names: `draw`→`renderDraw`, `present`→`renderPresent` |
| zimrmath  | drop namespace — math primitives keep their short names: `lerp`, `clamp`, `normalize`, `dot`, `cross`, `smoothstep`, `wrap`, `fract`, `luminance`, `floatEquals`.  Type-prefixed fns drop namespace as-is: `vector2Lerp`, `vector3Normalize`, `matrixMultiply`, `quaternionSlerp`.  **Math primitives are the base of the algebra; they win the short name.**  Other public symbols that would clash (none found in current code) would adapt by adding their own subsystem prefix. |
| rlgl      | drop namespace (already prefixed `rl*`): `rlPushMatrix`, `rlMatrixMode`, `rlLoadIdentity`, ... |
| rlsw      | drop namespace (already prefixed `rlsw*`)                      |
| gl_iface  | merge into gl flat surface (already prefixed `gl*`)            |
| gpu       | drop namespace (mostly prefixed `gpu*`); manually prefix anything bare |

**The standalone-reader test.**  When in doubt: would a stranger
seeing the name in isolation know what category it belongs to?
- `drawRectangle` — yes, clearly a draw call
- `lerp`, `clamp`, `normalize`, `cross` — yes; these are
  universally-understood math primitives.  They live at the base
  of the algebra and earn the short name.  If a non-math symbol
  later tries to claim one of these names, it adapts (adds its own
  subsystem prefix), not the math primitive.
- `step` — fails: could be physics, scene, animation, ecs.  Needs
  prefix → `physicsStep`, `sceneStep`.
- `init` — fails: could be anything.  Needs prefix → `ecsInit`,
  `physicsInit`, `effectsInit`.
- `easeLinearIn` — passes, clearly an easing.
- `clearBackground` — passes.
- `clear` — fails (too generic) — renamed to `clearBackground`.

The asymmetry is intentional: base-layer primitives (math) keep
short names because they appear in long expressions where every
extra character costs readability; subsystem-level entry points
take longer names because they're called sparingly and need to
identify the subsystem to the reader.

## Phase F1 — add flat re-exports (1 turn)

Goal: every namespace member is reachable both ways
(`z.text.draw` AND `z.drawText`) after this turn.  No call site
changes.  Pure addition.

**Mechanics.**  `pub usingnamespace` is removed from Zig and is
also wrong for this purpose — it hides where aliases come from,
which fights the reader+grepper principle.  Use an explicit
generator: a python script walks each `pub const ns = struct {...}`
block and emits one `pub const X = ns.X;` line per `pub fn X` /
`pub const X = ...` found inside, applying the rename table for
bare names.

```zig
// In src/zimr.zig:
pub const drawRectangle    = shapes.drawRectangle;
pub const drawRectangleRec = shapes.drawRectangleRec;
pub const drawCircle       = shapes.drawCircle;
// ... ~500 more
pub const drawText         = text.draw;       // renamed
pub const measureText      = text.measure;    // renamed
pub const Color            = types.Color;
pub const Rectangle        = types.Rectangle;
// ... ~50 more types
```

Every alias is explicit and greppable — `grep drawText src/zimr.zig`
finds where it's defined; `grep z.drawText examples/` finds where
it's used.  No silently-imported names.

**Generator script.**  Write `scripts/gen_flat_exports.py` that:
1. Walks each `pub const ns = struct { ... }` in `drawing.zig` /
   `runtime.zig` / `types.zig` / etc.
2. Emits one `pub const X = ns.X;` line per `pub fn X` /
   `pub const X = ...` found inside.
3. Applies the rename table (`text.draw` → `drawText` etc.).
4. Writes the result into `src/zimr.zig` between marker comments
   `// === AUTOGEN flat re-exports — start ===` / `// === end ===`.

Re-running the script after adding new functions to a module
regenerates the aliases.  Idempotent.  The marker comments make
it obvious which lines are autogen vs hand-written.

**Verification.**  After F1:
- `zig build install --release=small` — clean compile
- `zig build smoke-test --release=small` — 100/100 PASS
- Both old + new forms work in a spot-check example
- Re-export count matches the total pub fns in flattened namespaces +
  types (sanity check vs the python script's emitted count)

## Phase F2 — migrate call sites (1-2 turns)

Goal: nothing in `examples/` or `src/` or `webtests/` references
the dotted form anymore.  Done by namespace, in heaviest-first
order so the biggest wins land first.

Per-namespace sed pass (heaviest namespaces first; ~2,000 sites
total):

```bash
# Trivial — namespace just drops out:
sed -i 's/z\.shapes\./z./g'   examples/*.zig
sed -i 's/z\.textures\./z./g' examples/*.zig
sed -i 's/z\.input\./z./g'    examples/*.zig
# ... etc.

# Renamed — namespace strip + name change:
sed -i 's/z\.text\.draw\b/z.drawText/g'           examples/*.zig
sed -i 's/z\.text\.measure\b/z.measureText/g'     examples/*.zig
sed -i 's/z\.text\.deinit\b/z.deinitFontCache/g'  examples/*.zig
sed -i 's/z\.gl\.clear\b/z.clearBackground/g'     examples/*.zig
sed -i 's/z\.ecs\.init\b/z.ecsInit/g'             examples/*.zig
sed -i 's/z\.ecs\.update\b/z.ecsUpdate/g'         examples/*.zig
# ... full rename table from F1
```

**Per turn:**
- Run sed for 2-3 namespaces
- `zig build install --release=small`
- `zig build smoke-test --release=small`
- Spot-check 5 random examples by eye for readable output
- Commit

Old dotted form still works (re-exports from F1 still in place),
so this is purely cosmetic until F3.

**Budget:** maybe 1 turn if the sed cooperates; 2 turns if there
are edge cases (e.g. `z.text` appears inside a string literal or
comment that needs to stay).

## Phase F3 — remove the namespace exports (1 turn)

Goal: `zimr.zig` no longer exposes the dotted namespaces; only
flat re-exports remain.

**Mechanics.**

```diff
-pub const shapes   = @import("drawing.zig").shapes;
-pub const textures = @import("drawing.zig").textures;
-pub const text     = @import("drawing.zig").text;
-pub const models   = @import("drawing.zig").models;
-pub const camera   = @import("runtime.zig").camera;
-pub const gestures = @import("runtime.zig").gestures;
-pub const core     = @import("runtime.zig").core;
-pub const input    = @import("runtime.zig").input;
-pub const gl       = @import("gl.zig");
-pub const types    = @import("types.zig");
-pub const easings  = @import("easings.zig");
-pub const ui       = @import("ui.zig");
-pub const ecs      = @import("entities.zig");
-pub const physics  = @import("physics.zig");
-pub const scene    = @import("scene.zig");
-pub const rlgl     = @import("rlgl.zig");
+// (all of those reachable via flat re-exports below)
```

Keep:
- `pub const run` — top-level entry point
- `pub const Frame`, `pub const Config`, `pub const App` — entry types

**Verification.**  Smoke 100/100 + tests stable + grep returns zero
hits for `z\.\(text\|shapes\|textures\|...\)\.` in examples/.

If F2 was complete, F3 is a no-op for callers — they're all already
on the flat form.  Smoke fails only if F2 missed a callsite (rare;
sed plus a smoke pass catches almost all).

## Turn breakdown — F1+F2+F3 only (no F4 consolidation)

| Phase | What                                | Turns | Cumulative |
|-------|-------------------------------------|-------|------------|
| F1    | add flat re-exports (compat layer)  | 1     | 1          |
| F2.1  | migrate trivial namespaces (sed)    | 1     | 2          |
| F2.2  | migrate edge cases (manual fixes)   | 0-1   | 2-3        |
| F3    | remove dotted namespaces            | 1     | 3-4        |

**Total: 3-4 turns** for the full flatten with zero breakage.

## Phase F4 — options-arg consolidation (5 turns, OPTIONAL post-flatten)

Once the flat surface is in place, the variant-explosion families
(12 `drawRectangle*`, 7 `drawCircle*`, etc.) become candidates
for collapse into single options-arg functions.  This IS a
breaking change — old variant names go away.

Per Simon's preference (no parallel forms), F4 should be a hard
cutover per family.  But it's separable from F1-F3 and can be
deferred indefinitely.  Likely better done AFTER imgui-parity
closes — by then we have empirical usage data on which variants
are common.

| Turn | Family       | Variants → 1 |
|------|--------------|---------------|
| F4.1 | drawRectangle | 12 → 1       |
| F4.2 | drawCircle    | 7 → 1        |
| F4.3 | drawLine      | 6 → 1        |
| F4.4 | drawTexture   | 6 → 1        |
| F4.5 | drawText      | 5 → 1        |

**Skip families** with semantically-distinct variants:
- `genMesh*` (each is a different generation algorithm)
- `checkCollision*` (pair-of-shapes is essential)
- `drawSpline*` (different spline algorithms)

## Sequencing question for Simon

Three options:

1. **F1-F3 now, before resuming imgui-parity.**  3-4 turns of
   non-feature work, then imgui-parity's remaining ~18 turns all
   use the flat API from day one.  Total: 21-22 turns.

2. **Finish imgui-parity first, then F1-F3.**  Costs extra
   migration surface — every new imgui-parity demo this arc adds
   ~20 dotted-namespace call sites that F2 will sweep.  Adds ~360
   more sites to F2's scope (still sed-able).  Total: 18 + 3-4 =
   21-22 turns.

3. **F1 now (1 turn), F2 + F3 after imgui-parity.**  Flat
   re-exports exist from day one; imgui-parity demos can use them
   immediately for new code.  F2+F3 sweep at the end catches all
   call sites including new imgui-parity ones.  Total: 1 + 18 +
   2-3 = 21-22 turns either way.

Net work is the same (~22 turns).  The real choice is when to
context-switch.  My recommendation: **option 3**.  F1 is small
and mechanical, gets the flat surface available immediately, and
doesn't disrupt the imgui-parity arc.  F2/F3 land cleanly at
arc-close when there's a natural pause.

## Risks + mitigations

| Risk | Mitigation |
|------|------------|
| Sed pattern catches something inside a string literal or comment | Run `git diff` per namespace; spot-check; the only currently-active string-literal-with-namespace-name is the `##combo_X` window-key pattern in src/ which won't match `z\.X\.` anyway |
| Rename collision between two flattened modules | The collision audit (Turn 202) showed 2 real collisions (`init`, `deinit`).  Both covered by the rename table.  Add to the table any new collisions found during F1 generation. |
| Auto-generated alias list goes stale after adding new pub fns | Re-run the generator script; it's idempotent within the marker comments |
| Existing zips and standalones still reference dotted form | They're standalone — they bundle the zimr at build time.  Re-build invalidates the bundle; users with old zips keep working until they rebuild.  Document in CHANGELOG. |
| Type names clash with stdlib (e.g. `z.Color` is fine, but `z.Reader` would collide if we ever add one) | Type names that clash with std (Reader, Writer, Allocator) get a `zimr` prefix.  None in the current type set clash. |

## Verification checklist (final F3 turn)

- [ ] `grep -r "z\\.shapes\\." examples/ src/ webtests/` returns 0
- [ ] `grep -r "z\\.textures\\." examples/ src/ webtests/` returns 0
- [ ] `grep -r "z\\.text\\." examples/ src/ webtests/` returns 0
- [ ] ... (one per flattened namespace)
- [ ] `zig build install --release=small` clean
- [ ] `zig build smoke-test --release=small` 100/100 PASS
- [ ] `zig build test` no new failures
- [ ] CHANGELOG entry describing the migration
- [ ] CHEATSHEET regenerated against the new surface
