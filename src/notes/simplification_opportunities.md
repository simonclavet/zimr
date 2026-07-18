# Simplification / de-duplication opportunities

Running notes gathered while making every example leak-free (managed memory,
explicit ownership). These are NOT bugs — the code works — but they're places
where the design forces avoidable per-example boilerplate or duplicates a
system that already exists elsewhere.

## 1. Two parallel shader-resource systems (the big one)

There are two ways an example wires up shader resources, and they have very
different ownership stories:

- **Typed path — `shader.Resources(Schema)` / `z.shader.loadShaderVF`.**
  Schema-driven. Auto-creates the UBO buffer + bind-group layout + bind group,
  and has a real `deinit` that frees them. The pipeline is deduplicated in
  `pipeline_cache`. Used by: bloom, postprocess, shaders_vertex_displacement,
  vertex_texture_test. These convert to `.managed` almost for free (one
  `shader.deinit()` + `rt.deinit()` and you're done).

- **Low-level path — the `z.material.*` helpers** (`bindGroupLayout`,
  `bindGroup`, `uniformBuffer`, `storageTexture`) + raw `z.wgpu.createSampler`.
  These only CREATE; they return raw handles with no owner and (until this
  hunt) no matching teardown. Used by: pipeline_sampler, pipeline_array,
  pipeline_mipmap, pipeline_storage. Every one of these examples hand-rolls the
  same "bgl + bg + ubo + sampler (+ storage texture) (+ compute-fill pass)"
  dance AND must hand-roll the matching destroy for each handle. This is where
  essentially all the remaining leaks live.

  **Opportunity:** either (a) migrate these examples onto the typed
  `loadShaderVF`/`Resources` path (they predate it), or (b) give the low-level
  material path an owned bundle — e.g. a `material.Bound` struct holding the
  bgl + bg + buffers with a `deinit` — so the example tracks ONE owner instead
  of 6-10 loose handles. (a) also deletes the duplication outright.

## 2. Missing `deinit`s on owned material types (partially fixed)

The material types were creation-only. Added during the hunt:
- `material.Pipeline.deinit` — frees handle + layout + module. Managed
  `z.Pipeline` examples (forward_kinematics, pipeline_constants, wgpu_bringup)
  were doing this by hand; they can now call `.deinit()`.
- `material.StorageTexture.deinit` — frees texture + view.

Still no owner/teardown for the loose bgl/bg/sampler handles the helpers mint
(see #1b).

## 3. Engine-owned lazy resources not freed at shutdown

`fullscreen_vbo` (the engine's fullscreen-quad VBO, created lazily the first
time an app blits a render texture) was never freed in `runnerShutdown` — it
showed as a lone `buffer=1` residual for every RTT example (postprocess,
bloom). Fixed by freeing it next to the depth target in `runnerShutdown`.

Worth auditing the rest of the App's lazily-created engine handles the same way
(anything created on first-use and stored on `App`): confirm each has a
shutdown release. The depth target + fullscreen_vbo are handled; others?

## 4. `FluidDiscs` build-only handles (fixed)

`FluidDiscs.init` created a vs/fs module + pipeline layout and neither stored
nor destroyed them ("live for the program's lifetime"). Now released right
after pipeline creation, matching `compute_host` and `Cube3D`. Any struct that
builds ONE pipeline should follow this build-only-release pattern rather than
retaining or leaking the source handles.

## 5. Near-duplicate example scaffolding: fluid_gpu vs fluid_sort

Both build the same skeleton: a `z.Compute(fk)` pipe, a `z.FluidDiscs`
renderer, a `z.UiHost`, a spawn/reset path over a `[]Vec2` scratch, and the
same knob set (k_far/k_near/rest_density/gravity/visc). fluid_gpu adds the
t1178 diagnostic machinery (a hand-rolled compute + a mirror renderer). The
shared skeleton could be a small "fluid demo host" the two examples
parameterize, rather than ~800 duplicated lines each. Low priority (they're
diagnostic sandboxes), but noted.

## 6. `Handrolled` in fluid_gpu

The t1178 hand-rolled compute path (`Handrolled`) reproduces, by hand, exactly
what `z.Compute` already does (buffers + bind group + compute pipeline +
dispatch). It exists specifically to A/B against the transpiler, so the
duplication is intentional — but if t1178 is settled, it (plus the mirror
discs/buffer) is a chunk of fluid_gpu that could be deleted.

## 7. Mip-view ownership inconsistency (footgun)

`createTextureViewMip` views behave differently from `createTextureView`
views under the leak census:

- A **full** `createTextureView` view must be explicitly `destroyTextureView`'d
  (e.g. `StorageTexture.deinit` frees both its view and texture, and that
  balances).
- A **per-level** `createTextureViewMip` view must NOT be explicitly destroyed
  — destroying the parent mipmapped texture already releases its per-level
  views, so an explicit `destroyTextureView` double-frees (shows as
  `texture_view` going negative by one-per-level-per-lifecycle in the census).

pipeline_mipmap relies on this: it frees the per-level compute bind group but
leaves the mip view to be released with `tex`. This asymmetry is surprising and
easy to get wrong. Worth reconciling: either make `createTextureViewMip` views
independently owned (so the same explicit-destroy rule applies everywhere), or
document/assert the texture-owned rule at the API. Both `createTextureViewMip`
and `createTextureView` currently `bumpHandle(.texture_view, +1)`; the census
only stays balanced for mip views because the JS texture-destroy path releases
them — which means the +1 bump for a mip view is effectively reconciled by the
parent texture's destroy, not by a matching `destroyTextureView`.

## 8. launcher: a host, not a leaf (leak-check status)

launcher is the one remaining `.arena` example, and it's a different kind of
thing — a host that shows one of 24 child apps full-screen. Notably its
ownership is ALREADY explicit and already leak-checked per child:

- `Launcher.add`/`addDeferred` allocate each child its own State slot AND its
  own leak-checking `DebugAllocator` (`rec.dbg`).
- `Launcher.deinit` walks the records: for each alive child it calls the
  child's own `vt.deinit(rec.dbg.allocator(), ...)`, then `rec.dbg.deinit()`
  (which reports any CPU leak in that child), then frees the slot + record.
- The Launcher's own resources (the record list + state slots) are freed there
  too.

So "where is memory used" is already answered: the Launcher owns its records +
slots; each child owns its resources under its own checked allocator. Flipping
launcher itself to `.managed` doesn't test the Launcher in isolation — because
the GPU handle census is global, it would test whichever child is active
(index 0 = ex_helmet_sw) end-to-end, and only pass once THAT child (ideally all
24) is GPU-leak-free. launcher is therefore best converted last, after its
children, and is also the one build with a known cold-OOM risk in the sandbox
(warm the child modules first). Treat it as the capstone of a
"make the flagship children leak-free" pass, not a standalone leaf.

**UPDATE (done):** all 24 flagship children were already `.managed`, so
launcher was flipped to `.managed` too and passes the leak gate (the headless
run exercises child index 0 = helmet_sw end-to-end + the Launcher's own record/
slot management; all balanced after shutdown). Every example in the tree is now
managed + leak-checked — zero `.arena` opt-outs remain. The cold-OOM risk did
not materialize on the current compiler (86s build).
