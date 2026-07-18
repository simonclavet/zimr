# thin-frame plan

**Status:** active sub-project, decided turn 161.
**Predecessor:** the raylib port arc (`raylib-ports.md`) is **paused**
for the duration of this refactor — pick it back up after the
thin-frame work lands.
**Cadence:** big-bang execution.  Expect the tree to be red
across many turns.  We commit to red on purpose because the
alternative — interleaving "keep building" with "redesign the
framework" — would mix two different kinds of thinking and
both would suffer.

---

## 1. Goals

zimr is **opinionated as a library**, **thin as a framework**.

- The library side stays opinionated: shapes, textures, models,
  shaders, easings, audio, codecs, gestures, scene graph, ECS,
  imgui port, rlsw, physics.  None of these change shape.  The
  module surface (`z.shapes.*`, `z.textures.*`, `z.audio.*` …)
  remains identical.
- The framework side becomes minimal: Frame is a pure data
  struct of host-provided bridges.  Init and update are the
  only callbacks.  Everything else is the user's bytes, owned
  by them, never touched by the runtime after handoff.

## 2. Principles

These rules are committed.  Disagreement with one of them
means revisiting this doc, not silently violating it.

1. **Host-bridge data lives on Frame.**  Things produced by the
   JS↔wasm boundary that no Zig code can construct in
   isolation: `gl`, `input`, `window`, `time`, `audio_device`.
   These are borrowed references; the runtime owns the
   underlying state and mutates it freely.  User code reads
   from them but never stashes their references in State.

2. **User-owned data lives in State.**  Anything the user can
   construct themselves — arenas, RNGs, loggers, gesture
   FSMs, loaders, font atlases, shape textures, asset handles
   — goes in the user's State struct.  Once handed off in
   init, the runtime never reads or writes it.  The user is
   responsible for every byte they own, including resetting
   their scratch arena every frame and ticking their gestures
   FSM at the top of every update.

3. **The user's `gpa` is theirs.**  Init receives a child
   allocator that the runtime explicitly stops using after the
   handoff.  The runtime keeps its own internal `runtime_gpa`
   for input-event buffers, gesture-state backstore, the rlgl
   batch buffer inside `GlState`, dispatch scratch, etc.  Two
   distinct allocators, even if both happen to wrap
   `std.heap.wasm_allocator` underneath.

4. **Frame is a pure data struct.**  No methods.  No
   `subFrame`.  No defaults.  Five fields.  Operations are
   free functions in their module (`z.gl.*`, `z.textures.*`,
   `z.camera.*`, `z.shaders.*`) taking `f.gl` (and any other
   state) as explicit args.

5. **No invisible work between user calls.**  The runtime
   never silently allocates, draws, flushes, ticks, or
   pumps anything on the user's behalf during update.  Every
   per-frame action visible in the user's update body.

6. **Verbosest framework wins.**  When a feature seems
   convenient, the principle is: would it hide work that the
   user needs to see?  If yes, omit.  If no, omit anyway
   unless several examples will *measurably* be clearer with
   it.  We err strongly on the side of "make the user type
   it out."  BaseState convenience bundles are not provided.

## 3. The new Frame shape

```zig
pub const Frame = struct {
    gl: *rlgl.GlState,
    input: *input.InputState,
    window: *const core.WindowState,
    time: *const core.TimeState,
    audio_device: *audio_device.AudioDeviceState,
};
```

Five fields, zero methods.  No constructors visible to user
code (the runtime stamps fresh values each tick from
`&app.runtime.*`, same as today).

## 4. The new callback contract

```zig
pub fn initState(gpa: std.mem.Allocator, f: *z.Frame) !State;
pub fn update(f: *z.Frame, state: *State) void;
```

- `gpa` is the user's child allocator.  Stash it in State if
  late allocations are needed; the runtime won't be there to
  provide one.
- Init reads `f.window` for canvas dims, calls
  `z.FontCache.initDefault(gpa, f.gl)` etc. for assets it
  wants to set up, returns the populated State.
- Update receives a fresh Frame snapshot each tick.  The
  user's responsibility is to:
  1. Reset their scratch arena (if they hold one).
  2. Tick their gestures FSM (if they hold one).
  3. Call `z.gl.beginDrawing(f.gl)`.
  4. Issue draws.
  5. Call `z.gl.endDrawing(f.gl)`.
- `init` and `update` are the only callbacks.  No
  `subFrame`, no per-pane override mechanism.  Multi-app
  setups are user code (see §11 on `gallery.zig`).

## 5. What moves from Frame to user-owned

Eleven things move.  All become explicit fields in the user's
State struct.

| Field | Replacement |
| --- | --- |
| `f.gpa` | First arg of `initState`.  Stash in State if needed later. |
| `f.scratch` | `std.heap.ArenaAllocator` in State.  Reset at top of update. |
| `f.loader` | `z.Loader` in State.  `z.Loader.init(gpa)`. |
| `f.clock` | **Deleted entirely.**  Read `f.time.delta_time_time` / `f.time.time` directly. |
| `f.rng` | `std.Random.DefaultPrng` or `z.Rng` in State. |
| `f.log` | `z.Logger` in State. |
| `f.gestures` | `z.gestures.GesturesState` in State.  Tick manually at top of update. |
| `f.shapes_texture` | `z.ShapesTextureState` in State. |
| `f.font_cache` | `z.FontCache` in State. |
| `f.skybox_cache` | `z.SkyboxCache` in State (only `skybox.zig` example uses it). |
| `Frame.subFrame` / `SubFrameOverrides` | **Deleted.**  Sub-apps each carry their own State. |

## 6. Constructor signatures (target)

These are what the user writes in `initState`.  Some are
straight `std` types; the zimr ones are new public
constructors.

```zig
// Allocators / general
const scratch = std.heap.ArenaAllocator.init(gpa);   // .deinit() on cleanup
const rng     = std.Random.DefaultPrng.init(0xseed); // pure data

// zimr utilities
const log     = try z.Logger.init(gpa, "prefix");    // confirm API at impl time
const loader  = z.Loader.init(gpa);                  // confirm API at impl time
const gest    = z.gestures.GesturesState{};          // zero-init OK

// zimr asset state
const shapes_tex = try z.ShapesTextureState.initDefault(gpa, f.gl);
const font_cache = try z.FontCache.initDefault(gpa, f.gl);
const skybox     = z.SkyboxCache{};                  // lazy, init on first use
```

**Verify during execution:** the exact signatures of the
zimr constructors above.  The plan commits to "constructors
exist that take what they need explicitly"; the precise
arg lists for `Logger`, `Loader`, `ShapesTextureState`,
`FontCache` get nailed down when those files are edited.

## 7. What gets deleted (Frame surface)

All 14 Frame methods, and the override machinery:

```
Frame.clear
Frame.clearBackground
Frame.beginMode2D / endMode2D
Frame.beginMode3D / endMode3D
Frame.beginTextureMode / endTextureMode
Frame.beginShaderMode / endShaderMode
Frame.beginBlendMode / endBlendMode
Frame.beginScissorMode / endScissorMode
Frame.subFrame
Frame.SubFrameOverrides
```

And the auto-tick / auto-init machinery in `App` /
`runtime_assembly`:

```
- auto-allocation of Loader/Logger/Rng/Clock/Gestures/
  ShapesTextureState/FontCache/SkyboxCache in `App.init`
- auto-tick of `gestures.update(input, time)` in dispatch
- auto-call of `endDrawing(gl)` after user's update returns
- auto-reset of the scratch arena
```

## 8. Free-fn namespace (target)

A consolidated `z.gl` namespace holds the low-level
bridge ops that previously were Frame methods or scattered
across `z.rlgl_gpu`.  Mode changes that have a natural
module home (textures, camera, shaders) stay there.

```
// Cycle primitives
z.gl.beginDrawing(f.gl)
z.gl.endDrawing(f.gl)
z.gl.clear(f.gl, color)

// State changes (formerly Frame methods)
z.gl.beginBlendMode(f.gl, mode)
z.gl.endBlendMode(f.gl)
z.gl.beginScissorMode(f.gl, rect)
z.gl.endScissorMode(f.gl)

// Mode changes (stay in module home)
z.textures.beginTextureMode(f.gl, target)
z.textures.endTextureMode(f.gl)
z.camera.beginMode2D(f.gl, cam)
z.camera.endMode2D(f.gl)
z.camera.beginMode3D(f.gl, cam)
z.camera.endMode3D(f.gl)
z.shaders.beginShaderMode(f.gl, shader)
z.shaders.endShaderMode(f.gl)

// Existing rlgl primitives — rename
z.rlgl_gpu.*  →  z.gl.*
```

## 9. Concrete before/after

Sanity check that the design lands clean.

**Before:**

```zig
const State = struct {
    pos: z.types.Vector2 = .{ .x = 400, .y = 225 },
};

fn initState(f: *z.Frame) !State { return .{}; }

fn update(f: *z.Frame, state: *State) void {
    f.clear(z.colors.Color.raywhite);
    if (z.input.isKeyDown(f.input, .right)) {
        const dt: f32 = @floatCast(f.clock.frameTime());
        state.pos.x += 200.0 * dt;
    }
    z.shapes.drawCircleV(f.gl, f.shapes_texture, state.pos, 20, z.colors.Color.red);
}
```

**After:**

```zig
const State = struct {
    scratch: std.heap.ArenaAllocator,
    shapes_texture: z.ShapesTextureState,
    pos: z.types.Vector2 = .{ .x = 400, .y = 225 },
};

fn initState(gpa: std.mem.Allocator, f: *z.Frame) !State {
    return .{
        .scratch = std.heap.ArenaAllocator.init(gpa),
        .shapes_texture = try z.ShapesTextureState.initDefault(gpa, f.gl),
    };
}

fn update(f: *z.Frame, state: *State) void {
    _ = state.scratch.reset(.retain_capacity);

    z.gl.beginDrawing(f.gl);
    z.gl.clear(f.gl, z.colors.Color.raywhite);

    if (z.input.isKeyDown(f.input, .right)) {
        const dt: f32 = @floatCast(f.time.delta_time_time);
        state.pos.x += 200.0 * dt;
    }
    z.shapes.drawCircleV(f.gl, &state.shapes_texture, state.pos, 20, z.colors.Color.red);

    z.gl.endDrawing(f.gl);
}
```

Diff: +5 lines.  Visible: scratch lifecycle, draw cycle,
state ownership, dt source.  Hidden: nothing.

## 10. Per-file inventory (preliminary)

Framework files (touched in Phase 1):

| File | What changes |
| --- | --- |
| `src/zimr.zig` | Frame struct, App dispatch, init/update signatures, deletion of 14 methods + SubFrameOverrides + subFrame. Add `pub const gl = @import("gl.zig")` namespace. |
| `src/runtime.zig` | Drop auto-init of user-owned types in App.init.  Drop auto-tick of gestures.  Drop auto-endDrawing. |
| `src/runtime_assembly.zig` | Same logic as runtime.zig. |
| `src/gl.zig` (NEW) | Houses `beginDrawing`, `endDrawing`, `clear`, `beginBlendMode`, `endBlendMode`, `beginScissorMode`, `endScissorMode`, plus the contents currently under `rlgl_gpu`. |
| `src/drawing.zig` | Move `beginTextureMode`/`endTextureMode` from Frame methods (currently delegated) to `textures` namespace.  Same for camera/shaders. |
| `src/sound.zig` | Confirm `audio_device` constructor signature stays workable; no major change expected. |
| `src/tests.zig` | If any tests construct Frame mocks, update their shape. |

Asset/utility files (touched in Phase 1 or 2):

| File | What changes |
| --- | --- |
| `src/drawing.zig` (text + shapes) | Confirm `ShapesTextureState.initDefault(gpa, gl)` and `FontCache.initDefault(gpa, gl)` constructors exist with these signatures.  Today they're auto-built inside `App` — extract the logic into public constructors. |
| `src/codecs.zig` | If it has any Frame dependency (likely no), update. |
| `src/scene.zig` | Check. |
| `src/entities.zig` | Check. |
| `src/physics.zig` | No Frame dependency expected. |
| `src/web.zig` | No Frame dependency expected. |
| `src/ui.zig` | ImGui port uses Frame somehow; audit. |

Examples (touched across Phases 2-5): all 71.

Build / docs / tests:

| File | What changes |
| --- | --- |
| `build.zig` | Through Phase 2-5: shrink the `examples` array as we go, expand it as we migrate.  At Phase 5 end, every name back. |
| `src/web/manifest.json` | Gallery entries don't change shape — the manifest sees example *names*, not internals. |
| `src/notes/claude.md` | Style guide adds the new principles + the init/update shape + the verbosest rule. |
| `src/notes/PLAN.md` | Mark thin-frame active; mark raylib-ports paused. |
| `src/notes/CHANGELOG.md` | Per-turn diary. |
| `scripts/build_cheatsheet.py` | Cheatsheet regen — update only if there's a Frame-methods section to remove. |
| `README.md` | All 12 inline example snippets rewritten to the new shape. |
| `webtests/` | Smoke-test harness — verify it constructs Frames in a way that still works.  Likely the runtime does the work and the harness just runs binaries; smoke should be invariant. |

## 11. Example migration order

71 example files.  Grouped into phases by complexity and by
what new constructors they exercise.  Each phase: register
that phase's examples in `build.zig`, leave the rest
unregistered (build-excluded → no compile pressure).  Smoke
passes on the registered subset only.

**Phase 2 — minimal foundation (≈10 examples).**
Targets: scratch arena, raw `f.time`, basic drawing, no
gestures, no audio, no font/shapes texture.

```
basic                  bouncing_ball         collision_area
colors_palette         input_keys            input_mouse
input_mouse_wheel      lines_bezier          math_angle_rotation
triangle_gradient      vector_angle
```

Validates: Frame shape, init signature, `z.gl.*` namespace,
`f.time` direct access, scratch lifecycle.

**Phase 3 — assets, text, RTT (≈13 examples).**
Targets: shapes_texture user-owned, font_cache user-owned,
RTT, simple state machines.

```
math_sine_cosine        writing_anim            easings_ball
easings_box             easings_rectangles      easings_testbed
keys                    lines_drawing           input_multitouch
input_virtual_controls  life                    window_demo
text_layout
```

Validates: `z.ShapesTextureState.initDefault`,
`z.FontCache.initDefault`, RTT scope free-fns.

**Phase 4 — gestures, async load, audio (≈10 examples).**
Targets: user-owned gestures FSM, user-owned Loader, audio
device construction.

```
gestures_demo           gestures_testbed        touch_paint
audio_basic             audio_stream_synth      composer_drum
music_streaming         load_image_demo         png_demo
procgen_noise
```

Validates: `state.gestures.update(f.input, f.time)` pattern,
`z.Loader.init`, audio device usage in user space.

**Phase 5 — 3D, complex (≈14 examples).**
Targets: 3D camera modes, models, skinning, shaders.

```
cube3d                  billboards              models3d
first_person_camera     instancing              skybox
wireframe               dynamic_mesh            gltf_simple
gltf_textured           gltf_model_refs         skinned_mesh
rtt                     shader
shader_uniforms         mrt_demo
```

Validates: `z.camera.beginMode3D` free fn, mode-stack
mechanics under user control.

**Phase 6 — niche / multi-app / mocks (≈10+ examples).**
Targets: catch the rest.

```
particles               camera2d                gallery
ecs_solar_system        ecs_boids               imgui_demo
recursive_hud           physics_demo            physics_pyramid
rlsw_side_by_side       image_editor            texture_readback
text_on_texture         image_text
```

Includes the **gallery rewrite** (§14).  Includes any
example I miss above — final sweep through `examples/` to
confirm zero stragglers.

## 12. Test infrastructure changes

Searches to run during Phase 1:

```bash
# Where are Frames constructed in tests?
grep -nE "Frame\{|Frame = \{|: Frame ?=" src/

# Where are mock InputStates / TimeStates / WindowStates etc. constructed?
grep -nE "InputState\{|WindowState\{|TimeState\{" src/

# Where does the smoke-test harness build a Frame?
grep -rn "Frame" webtests/ scripts/
```

Expected scope: a handful of test fns in `runtime.zig`
construct mock `InputState`s and call internal fns; these
either don't see `Frame` at all (test the underlying
substate directly) or need their mocks updated.  The smoke
harness almost certainly does not see Frame from JS — it
runs example binaries that the runtime drives.  Confirm
during Phase 1 and document any surprises here.

## 13. Documentation deltas

| File | Change |
| --- | --- |
| `src/notes/claude.md` | Add a new "Principles" section near the top: the five principles above, framed as "rules every example follows."  Update the example-pattern recipe to the new init/update shape.  Note the "Frame has zero methods" rule explicitly. |
| `README.md` | All 12+ inline example snippets rewritten.  README's "what is zimr" paragraph updates to say "thin framework, opinionated library." |
| `cheatsheet.html` | Auto-regen via `scripts/build_cheatsheet.py` after the source changes.  Verify the regen still works (needs `/tmp/imgui-master/`). |
| `src/notes/PLAN.md` | Mark thin-frame active; mark raylib-ports paused. |
| `src/notes/raylib-ports.md` | Header note: "Paused for thin-frame refactor; resumes after Phase 6 of `thin-frame-plan.md`." |
| `src/notes/CHANGELOG.md` | Per-turn entries as usual. |

## 14. gallery.zig rewrite

`gallery.zig` is the multi-app demo.  Today it builds child
Frames via `subFrame(overrides)` to give each pane its own
logger/clock/rng.

After this refactor, the architecture is:

```zig
const SubAppA = struct {
    state: AStateType,
    update_fn: *const fn (*z.Frame, *AStateType) void,
};

const State = struct {
    gpa: std.mem.Allocator,
    scratch: std.heap.ArenaAllocator,
    shapes_texture: z.ShapesTextureState,
    font_cache: z.FontCache,
    pane_a_state: APaneState,
    pane_b_state: BPaneState,
    pane_c_state: CPaneState,
    pane_d_state: DPaneState,
};

fn update(f: *z.Frame, state: *State) void {
    _ = state.scratch.reset(.retain_capacity);

    // Each pane gets the full Frame.  Scissor + viewport for layout.
    z.gl.beginDrawing(f.gl);
    z.gl.clear(f.gl, z.colors.Color.black);

    drawPane(f, &state.pane_a_state, paneA_update, paneRect(0));
    drawPane(f, &state.pane_b_state, paneB_update, paneRect(1));
    drawPane(f, &state.pane_c_state, paneC_update, paneRect(2));
    drawPane(f, &state.pane_d_state, paneD_update, paneRect(3));

    z.gl.endDrawing(f.gl);
}

fn drawPane(f: *z.Frame, sub: anytype, updateFn: anytype, rect: z.types.Rectangle) void {
    z.gl.beginScissorMode(f.gl, rect);
    defer z.gl.endScissorMode(f.gl);
    updateFn(f, sub);
}
```

Each pane sees the full Frame.  Each pane has its own state.
The "share font_cache across panes" trick from today's gallery
is *opt-in* — if a pane wants to share, it takes a `*FontCache`
arg; if it wants its own, it builds one in pane init.  Default
posture is the cheaper-share, because the gallery itself is
about demonstrating composition, not about audit-purity.

Loggers / RNG seeds / loaders that the panes need become
fields inside each pane's state, owned per-pane.  No global
subFrame override machinery.

## 15. Phase plan (turn-by-turn)

Approximate.  Reality may compress or expand.

**Turn 162 — Phase 1: framework + Phase 2 examples.**
- Plan doc (turn 161, already this one).
- Reshape Frame.
- New init/update signatures.
- Delete 14 Frame methods + subFrame.
- Build `src/gl.zig` namespace.
- Stop auto-init / auto-tick / auto-endDrawing in `App`.
- Add public constructors for `ShapesTextureState`,
  `FontCache`, `Loader`, etc.
- Migrate Phase 2's 11 examples.
- Shrink `build.zig`'s example array to those 11.
- Update tests in `src/`.
- Gates: test green on migrated subset; smoke = 11 PASS;
  others not registered.

**Turn 163 — Phase 3 examples.**
- Migrate the 13 examples in Phase 3.
- Re-add them to `build.zig`.
- Gates: smoke = 24 PASS.

**Turn 164 — Phase 4 examples.**
- Migrate 10 (gestures + audio + assets).
- Smoke = 34 PASS.

**Turn 165 — Phase 5 examples.**
- Migrate 16 (3D + shaders).
- Smoke = 50 PASS.

**Turn 166 — Phase 6 examples + gallery rewrite.**
- Migrate the remaining ~14 + the gallery rewrite.
- Smoke = 71 PASS (full coverage restored).
- Final sweep through `examples/` to catch any stragglers.

**Turn 167 — Docs + cheatsheet + style guide + raylib-ports resume.**
- Rewrite README's example snippets.
- Update `claude.md` with the new principles.
- Regenerate `cheatsheet.html` (needs `/tmp/imgui-master/`).
- Update `PLAN.md`: mark thin-frame complete, raylib-ports
  active again.
- Ship.
- Resume raylib port arc at Batch 4 the following turn.

Total: ~6 turns of red→green.  No interleaving with raylib
ports.  The raylib port arc's next batch (Batch 4: window/
camera) is queued for turn 168+.

## 16. Verify during execution

Things this plan commits to but hasn't verified at write-time.
Each must be checked when the relevant file is opened.

- [ ] `Logger` current API and whether `Logger.init(gpa, prefix)` matches.
- [ ] `Loader` current API.
- [ ] `Rng` current API — is there a `z.Rng` type, or do we lean on `std.Random.DefaultPrng` directly?
- [ ] `ShapesTextureState` — does an `initDefault(gpa, gl)` constructor exist today, or do we need to extract it from `App.init`?
- [ ] `FontCache` — same question.
- [ ] How `gestures.update` is currently invoked by dispatch; does it return a status, or is it pure mutate?
- [ ] How smoke-test harness constructs Frames (probably opaque — confirm).
- [ ] Whether any test in `src/tests/` directly builds a Frame literal — most use module-level state and bypass Frame.
- [ ] Exact shape of `App.init` — what gets auto-initialised today that we need to stop auto-initing.
- [ ] Whether `z.rlgl_gpu` is a `pub const = rlgl` alias or has its own selection of fns.  Determines whether the `z.gl` consolidation is a rename or a curation.
- [ ] Whether `audio_device.AudioDeviceState` is OK to construct user-side, or whether browser autoplay policy forces it to come from a user-gesture context.  If the latter, audio examples may need a "click to start" gate before construction.

Resolution of these does not block the plan; they get
settled inside the relevant turn.

## 17. Done criteria

- All 71 examples build + smoke-pass under the new shape.
- All Frame methods deleted.
- Zero references to `f.gpa`, `f.scratch`, `f.clock`,
  `f.rng`, `f.log`, `f.loader`, `f.gestures`,
  `f.shapes_texture`, `f.font_cache`, `f.skybox_cache`
  anywhere in the tree.
- `src/notes/claude.md`'s principles section reflects the
  new rules.
- `README.md`'s example snippets are correct.
- `PLAN.md` marks thin-frame complete and raylib-ports
  active.
- Six gates clean: test, install, smoke, globals, dag, fmt.
