# Surface-view leak in the bridge - plan

**Status (2026-09-27): all decisions made - D1 the Map leak only, D2 release at present and at the next
acquire, D3 smoke validator + real-bridge gate. Awaiting Simon's explicit agreement with the whole list;
nothing is implemented, and nothing will be until Simon says go.**

The ask: `src/bridge.zig` mints a new `GPUTextureView` table entry every frame for the canvas and never
releases it. Fix it at the bridge, add a check that the table stays flat across frames, show all changed
code, run `zig build check` and the relevant smoke test, and leave the web build for a device check by
Simon. Change nothing else.

---

## 1. The leak, confirmed

### 1.1 The code path

| where | what it does |
|---|---|
| `src/bridge.zig:1027-1030` `jsSurfaceGetCurrentTexture` | `context.getCurrentTexture().createView()`, then `tblInsert(view)`: a NEW id every call |
| `src/bridge.zig:1031` `jsSurfacePresent` | a no-op ("presentation is implicit") |
| `src/bridge.zig:864-875` `tblInsert` / `tblGet` / `tblRelease` | the only way out of `g.wgpu.objects` is `tblRelease`; `next_id` only ever increments, so ids are never reused |
| `src/gpu_iface.zig:488-500` `WgpuBackend.beginFrame` | stores the id in `GpuFrame.surface_view` and returns it in `FrameContext` |
| `src/gpu_iface.zig:509-513` `WgpuBackend.endFrame` | finish, submit, `surfacePresent` - nothing releases the view |
| `src/gpu.zig:772-775` `GpuFrame.resetFrameState` | would reset the field to `.invalid`, but **it has no callers anywhere in the tree** (grep) |

Every consumer of the view sits between one `beginFrame` and its `endFrame`:

- `wgpu_app.zig:764-783` `ensureFrame` acquires once per frame (idempotent via `frame_begun`); `:818`
  `beginDrawing` and `:1134` `reopen2DPass` (after an offscreen pass) use it; `:909` `endDrawing` presents.
- `wgpu_app.zig:1021-1026` `clearBackground` presents mid-frame and then re-acquires through
  `beginDrawing` -> `ensureFrame` - so one rAF can hold **two** acquire/present pairs. Neither view is
  used after its own present.
- `draw3d.zig:6850/6961` (pbr3d `Renderer`), `wgpu_runner.zig:31-42` (legacy frame ownership), the
  launcher's child ticks (`wgpu_app.zig:4429-4464`, one frame, one present), and the four examples that
  call `Backend.beginFrame` directly (`cube_demo`, `depth_rendering`, `lambert_demo`, `wgpu_bringup`) all
  follow the same shape.

**No engine path uses a surface view after its present.** That is what makes releasing at present safe.

### 1.2 Measured on the real bridge

A throwaway probe (session scratchpad, not in the repo) runs `zig-out/standalone/hello_world.html`'s real
bridge JS - the c2js output of `src/bridge.zig`, built after the last edit to that file - in a node `vm` with
a mocked browser. It is the technique of `webtests/verify_imports.js`, plus an instrumented `Map` and reads
of `__H`. Part A drives the `wgpu` import namespace directly; Part B lets the page instantiate its REAL
wasm against the mocked GPU and pumps the bridge's own rAF tick.

| run | `g.wgpu.objects` | `__H` slots |
|---|---|---|
| A1: 600 x (acquire, present) | 1 -> 601, **+1.00/frame**; all 600 ids still in the Map | +4.00/frame |
| A2: CONTROL, 600 x (encoder, finish, submit) | 601 -> 601, **+0.00/frame** (the counter works) | +18.00/frame |
| A3: the boot tick alone, while stage 3 polls | flat | +1.00/frame |
| B: real hello_world wasm, 300 frames | 139 -> 439, **+1.00/frame** | **+214.00/frame** |

Part B attributes the growth exactly: of the 300 new Map keys, **300 are surface views and 0 are anything
else**, and all 349 views ever acquired (warm-up included) are still in the Map. The leak is precisely one
surface view per acquire, as the task said.

(Caveat for the `__H` column only: under the mock, `adapter.features.has("timestamp-query")` is truthy, so
the first frame takes the GPU-timing branch. The per-frame figure is for this mock and this example; a
device will differ somewhat. The Map column is exact either way.)

### 1.3 Why the smoke harness never saw it

- `webtests/runner.mjs` shims every import. **The bridge never runs under smoke**, so its Map does not
  exist there - the standing lesson "smoke supplies the very import the browser lacks".
- `webtests/wgpu_smoke.zig:404-442` (`res_types`) balances create/destroy pairs from the call log.
  `js_surface_get_current_texture` is not in it and has no destroy verb.
- And the ENGINE side is balanced anyway: one acquire and one present per frame. The leak is purely
  the bridge's bookkeeping, so no census of engine calls can ever show it.

---

## 2. A bigger leak next door: `__H`

This is outside the ask. It is here because it changes what the fix can promise.

**`ZimrBoot.tick` (`bridge.zig:3834-3895`), the loop that drives every zimr page, has no
`js_mark` / `js_reset`.** `Site.tick` (`bridge.zig:6971-6981`) brackets its frame; the zimr loop does not.
Two comments describe a per-frame reset that this loop does not have: `bridge.zig:4193-4198` ("every
handle minted during a frame is reclaimed by that frame's js_reset") and `Value.free`'s doc at
`bridge.zig:6279-6283`. A comment that disagrees with its code is a bug report someone already wrote.

So every handle a `wgpu` import mints during a frame stays in `__H` for the life of the page: +214 slots
a frame for hello_world (table above), about 46 million an hour at 60 fps. The retained objects include
per-frame GPU wrappers (encoders, passes, command buffers, the canvas texture and its view) and every
descriptor object.

**What that means for this fix, measured (Part B):**

- each surface view is held by **2 `__H` slots directly** - the `createView` result in
  `jsSurfaceGetCurrentTexture` and the `tblGet(color_view)` result in `jsEncoderBeginRenderPass`
  (`bridge.zig:1752`) -
- **and** is reachable through the render-pass descriptor objects `__H` also holds (`:1756-1775`).

So releasing the Map entry removes one of three retention paths. **The views stay un-collectible until
`__H` is fixed, whatever this change does locally.** The task's "keeps those objects from being garbage
collected" is true, but the Map is not the only thing keeping them.

**Why the Map fix is still the right thing to do first:** once the frame is bracketed, the Map becomes the
only holder of a surface view. Without this fix, views would still pile up at one per frame. The Map fix is
necessary for the end state, just not sufficient for GC today.

**Why the `__H` root fix does not belong in this change:** bracketing the tick reclaims every handle minted
inside it, including handles stored in `g` that must outlive the frame. At least these are minted lazily,
inside frames, and would dangle one frame later:

    g.wgpu.format_list 855   g.wgpu.canvas/context 901/917 (if first reached in a frame)   g.wgpu.resize_observer 959
    g.wgpu.text_encoder 1183 1202 1311 1490 2704 3265   g.userfile.queue/pending_name/input/save/save_url 3168-3369
    g.overlay.el 3475   g.overlay_ta.el 3659

That needs its own audit, its own gate and its own device round - see section 8.

---

## 3. Every way to stop the Map growing

| # | idea | for | against | verdict |
|---|---|---|---|---|
| R1 | release the view in `jsSurfacePresent` | tightest lifetime: zero surface views in the table between frames; present is `endFrame`'s last call; a use after present fails instead of drawing into a stale view | relies on every acquire being presented - an acquire whose frame never presents still leaks one; a released RESOLVE view is silently skipped by `jsEncoderBeginRenderPass` (`:1758-1763`) | good, not alone |
| R2 | release the previous view at the next acquire | bounded at 1 whatever the engine does; a stale handle keeps working until the next acquire | a view outlives its frame; a use after present stays silent; the last view is never released | good, not alone |
| **R3** | **R1 + R2**, one helper called from both | both properties: 0 between presented frames, never more than 1 | two call sites; stale-handle behaviour as in R1 (handled by the smoke validator, section 4) | **chosen (D2)** |
| R4 | one reserved id, overwritten each frame | nothing to release; flat by construction | breaks the table's rule that an id names one object forever (`bridge.zig:5798-5800`); a stale handle silently becomes the NEXT frame's view | reject |
| R5 | the engine destroys it (`wgpu.destroyTextureView` in `endFrame`) | explicit ownership, visible to the smoke census | the ask says fix it at the bridge; a canvas view belongs to the context, and WebGPU has no destroy for views, so engine ownership is a fiction; the smoke's `texture_view` census would go negative | reject |
| R6 | keep the view out of the Map; a sentinel id resolved inside `tblGet` | no table traffic | a branch in the hottest function of the bridge, and a second lookup path | reject |
| R7 | cache one view per canvas texture (reuse the id within a task) | helps `clearBackground`'s double acquire | the Map still grows one per frame | reject |
| R8 | call the dead `resetFrameState` from `endFrame` | the engine's copy of the handle goes `.invalid` after present | engine hygiene, not a fix; outside "change nothing else" | note for later |

On the stale handle under R1/R3, precisely: a released COLOR view makes `jsEncoderBeginRenderPass` return
pass 0 (`:1753-1755`), and the first call on pass 0 throws - loud. A released RESOLVE view is skipped
silently (`:1760`), so an MSAA frame would never reach the canvas - silent. Today no path does either
(section 1.1); the smoke validator in section 4 keeps it that way.

---

## 4. Every way to check it

| # | idea | sees the bridge? | verdict |
|---|---|---|---|
| C1 | smoke census: `(js_surface_get_current_texture, js_surface_present)` as a pair in `res_types` | no - engine discipline only | dropped by D2 = R3: it was needed only under R1, where an unpresented acquire IS the leak |
| **C2** | smoke validator in `runner.mjs`: mirror the bridge's rule (a surface handle retires at present and at the next acquire) and flag any color, resolve or MRT view that is retired, at `begin_render_pass` / `_mrt` | no | **chosen (D3)**: guards the one way R1/R3 can hurt a device, in every smoked example; same pattern as the attachment and bind-group validators already there |
| **C3** | real-bridge gate: `webtests/bridge_tables.mjs` boots the build's bridge JS (`runtimeJs` -> `zimr.js`, `build.zig:5452-5466`) in a node `vm` with a mocked browser, drives the `wgpu` namespace and asserts the Map is flat; `zig build bridge-check`, part of `check` | **yes - the only one that does** | **chosen (D3)**; precedent: `c2js-canary` already runs a hand-written `.mjs` host (`build.zig:2905-2922`) |
| C4 | C3 as a `runner.mjs` host API plus Zig logic compiled by c2js (the `wgpu_smoke.zig` pattern) | yes | the doctrine-pure form, roughly 3x the code for the same assertion, and it grows the file meant to stay "tiny and auditable" |
| C5 | extend `webtests/verify_imports.js` | yes | hand-run, needs a full page, not a gate (the Zig `verify_imports` tool replaced it in the build) |
| C6 | native Zig unit test of `bridge.zig` with a fake JS kernel | partly | a second implementation of JS semantics; reject |
| C7 | device recipe (DevTools one-liner) | yes, on a device | the device step, not a gate |
| C8 | bridge self-report (warn when the Map passes N) | yes, on a device only | per-frame cost, no CI; reject |

---

## 5. Decisions - asked one at a time

- **D1 - scope, given section 2. DECIDED (Simon, 2026-09-27): (a), the Map leak only.** The `__H` frame
  leak gets its own plan (section 8). Rejected: (b) freeing the surface path's own two handles, measured
  insufficient because the view is still held by `jsEncoderBeginRenderPass`'s slot and its descriptors;
  (c) the `__H` root fix in this change, too big and too risky here.
  Consequence to keep in mind: **this change does not make surface views collectible.** No check, reply or
  commit message may claim it does; the gate asserts the Map and only reports `__H`.
- **D2 - where the view is released. DECIDED (Simon, 2026-09-27): R3** - released in `jsSurfacePresent`,
  and any view still outstanding is released when the next one is minted, through one shared helper
  (Stage 1). Rejected: R2 alone (a view always lingers and a use after present stays silent); R1 alone (an
  acquire that never presents would still leak, and would need the C1 census to guard it). With R3, C1
  drops out of D3: an unpresented acquire can no longer grow the table.
- **D3 - the check. DECIDED (Simon, 2026-09-27): C2 + C3** - the `runner.mjs` use-after-release
  validator (Stage 2) and the real-bridge gate `zig build bridge-check`, part of `check` (Stage 3).
  Rejected: C3 alone (a future engine path using a released view would be found on a device); C2 alone
  (cannot see the table, so a regression of the fix itself would pass); C4 (the same assertion in about
  three times the code, with a mock browser grown into `runner.mjs`).

Answers and revisions go in the journal (section 9).

---

## 6. The plan (D1-D3 as decided)

### Stage 1 - the fix (`src/bridge.zig` only)

A new field in `Wgpu` (beside `context`), and the two surface verbs with one shared helper. A sketch; the
final text is shown in the reply after `zig fmt`:

```zig
        // The primary canvas's view for the frame in flight: minted by
        // js_surface_get_current_texture, released at js_surface_present or at the
        // next acquire (ZimrWgpu.releaseSurfaceView). 0 = none outstanding.
        surface_view_id: u32 = 0,
```

```zig
    /// Mint the view this frame renders into. A view still outstanding - an acquire
    /// whose frame was never presented - is released first, so the table never holds
    /// more than one surface view.
    fn jsSurfaceGetCurrentTexture(_: f64) f64 {
        releaseSurfaceView();
        const view: Value = g.wgpu.context.call("getCurrentTexture", .{}).call("createView", .{});
        const view_id: u32 = tblInsert(view);
        g.wgpu.surface_view_id = view_id;
        return @floatFromInt(view_id);
    }
    /// WebGPU presents the canvas by itself when the frame's task ends. What is left
    /// for the bridge is to drop the frame's view: nothing may use it after present.
    fn jsSurfacePresent(_: f64) void {
        releaseSurfaceView();
    }
    fn releaseSurfaceView() void {
        const has_outstanding_view: bool = g.wgpu.surface_view_id != 0;
        if (has_outstanding_view) {
            tblRelease(@floatFromInt(g.wgpu.surface_view_id));
            g.wgpu.surface_view_id = 0;
        }
    }
```

The submitted command buffer keeps its own reference to the view, so dropping the JS reference after
submit is safe. `clearBackground`'s present-then-reacquire releases the first view at its present and mints
the second one.

### Stage 2 - the smoke validator (`webtests/runner.mjs`)

- `js_surface_get_current_texture`: retire every live surface handle (mirroring the bridge's defensive
  release), then record the new one as live.
- `js_surface_present`: retire every live surface handle.
- `js_encoder_begin_render_pass` (`(encoder, colorView, r, g, b, a, loadOp, storeOp, depthView,
  resolveView)`): a retired color or resolve view emits `!ASSERT gpu-validation: ...` naming which, why a
  device fails (pass 0 and a throw; or a resolve silently skipped), and where the view was released.
- `js_encoder_begin_render_pass_mrt`: the same for each view in its `(views_ptr, views_len)` u32 array,
  read with the existing `readHandleArray`.

### Stage 3 - the real-bridge gate (`webtests/bridge_tables.mjs`, `build.zig`)

- Boot: a `vm` context with the Proxy browser mock; an instrumented `Map`; `WASM_BYTES` set to a placeholder
  so the bridge does not stop in bridge-hello mode; `WebAssembly.instantiate` captures the import object and
  never settles; run the bridge JS and call `start()` as a page does. If the imports are never captured the
  check **fails** - it must never pass vacuously.
- Find `g.wgpu.objects`: `js_get_surface()`, acquire one view, and take the Map that holds its id.
- **Control first** (non-vacuous): create 8 samplers, and the Map must grow by exactly 8; destroy them, and
  it must return.
- **The check:** 600 x (acquire, present) leave the Map's size unchanged, and none of the 600 ids is still in it.
- **The defensive path:** two acquires without a present leave exactly one surface view; a present leaves zero.
- **Informational, not asserted:** `__H` slots per frame over the loop, and how many surface views are still
  reachable from `__H` - printed so the section-8 follow-up starts from a number.
- `build.zig`: a `bridge-check` step running `node webtests/bridge_tables.mjs <runtimeJs artifact>`, and
  `check` depends on it. The bridge's C and JS are cached whenever a page was built; measure the cold cost
  and record it here.

### Stage 4 - verification (all of it in the reply)

1. **Red first:** `zig build bridge-check` against the unfixed bridge must FAIL at +1.00/frame. Only then
   Stage 1, and it must PASS.
2. **Plant for C2:** a temporary use after present (open and end one pass on `gpu_frame.surface_view`
   after `endFrame` in `App.endDrawing`) must turn `smoke-test -Dfocus=hello_world` red with the new message.
   Revert, and grep that the plant is gone.
3. Smoke the surface's consumers: `zig build smoke-test -Dfocus=hello_world,pipeline_msaa,pipeline_rendertarget,launcher`,
   plus one example that calls `clearBackground` mid-frame (pick it by grep). Together they cover a plain
   frame, an MSAA resolve into the canvas, RTT followed by `reopen2DPass`, present-and-reacquire, and child ticks.
4. `zig build check` (now including `bridge-check`); `zig build fix` first if lint or fmt complain.
5. Re-run the probe on a rebuilt hello_world standalone: section 1.2's table, before and after.

### Stage 5 - device check (Simon)

`zig build hello-world-standalone -Dmode=release`, open `zig-out/standalone/hello_world.html` in desktop
Chrome, and in DevTools run this twice, about ten seconds apart:

    __H.filter(x => x instanceof Map).map(m => m.size)

Before the fix, one of the sizes grows by about 600 in ten seconds at 60 fps. After it, none moves.
`__H.length` WILL keep growing - that is section 2, expected until its own fix. Then a visual pass on
`pipeline_msaa` and `pipeline_rendertarget`, since the change alters when the canvas view is released.

### Files

- Changed: `src/bridge.zig`, `webtests/runner.mjs`, `webtests/bridge_tables.mjs` (new), `build.zig`.
  **`build.zig` already has uncommitted edits in the working tree (45 lines, not from this work)**: add the
  step surgically, and do not reformat or overwrite around it.
- Not changed: `gpu.zig`, `gpu_iface.zig`, `wgpu.zig`, `wgpu_app.zig`, the examples, `resetFrameState`.
  `src/web/readme.html` lists no test steps (re-grep at implementation). `files.md` /
  `tools/file_descriptions.zig` have edits in flight too; the new webtests file joins the atlas at the next
  `zig build files-md`.

---

## 7. Risks

- **A stale surface handle now fails on a device** (a thrown pass call, or a silently skipped MSAA
  resolve). No path does this today; C2 makes any future one fail in the sandbox first.
- **Mock drift:** the gate boots the real bridge against a Proxy browser. If the boot sequence gains a
  requirement the mock cannot meet, the gate must fail with "imports never captured", not pass.
- **A second hand-written harness** beside `runner.mjs` - accepted in D3 over C4's doctrine-pure form.
- Line endings: git warns that `build.zig` will be converted LF -> CRLF. Keep the file's existing endings.

---

## 8. Follow-up, as its own plan: the `__H` frame leak

Per D1 this is separate work: `src/notes/bridge_handle_scope_plan.md`, to be written by its own session
(offered as a spin-off task on 2026-09-27, with this section's evidence in its prompt).

`ZimrBoot.tick` has no handle scope, so a zimr page grows `__H` by about 200 slots a frame and retains
every per-frame GPU wrapper it touches (section 2). A starting point:

- bracket stage 4 (`bridge.zig:3869-3888`) with `js_mark`/`js_reset`, like `Site.tick`;
- first audit every `g.*` Value minted inside a frame (the list in section 2 is a floor, not the whole set)
  and move each one either before the mark or into a JS container that owns the object rather than the handle;
- gate it with the Stage-3 harness asserting `__H` flat across real frames (Part B's shape), which is also
  when "surface views are collectible" first becomes checkable.

---

## 9. Journal

- **2026-09-27** - Studied the path (section 1.1); measured on the real bridge (section 1.2); found and
  measured the `__H` frame leak and that each view has three retention paths (section 2). Plan v1 written.
  D1 asked.
- **2026-09-27** - D1 answered: the Map leak only. Section 5 records it and the no-GC-claim consequence;
  section 8 hands the `__H` leak to its own plan (spin-off task offered). D2 asked.
- **2026-09-27** - D2 answered: R3, release at present and at the next acquire. C1 dropped from the
  check options as a consequence. D3 asked.
- **2026-09-27** - D3 answered: C2 + C3. Sections 4-7 now read as decided. Every decision listed back to
  Simon for explicit agreement; implementation waits for his go.
