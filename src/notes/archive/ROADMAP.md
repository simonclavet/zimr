# zimr -- ROADMAP (open + deferred work)

The single current list of what is NOT done across zimr, harvested from the
detailed plans before they were condensed/archived. Each item points to its
source plan (in this dir or `archive/`) for full context. Intentionally terse:
it exists so nothing unfinished is lost when the verbose plans shrink.

Last consolidated: 2026-06-16 (rasteriser arc RESOLVED -- see claude.md; this is
the docs cleanup pass). The rasteriser question is closed (keep both paths, by
design) and has NO open items here.

## Compute (GPU compute system)
- [ ] [ACTIVE] kompute / compute_host ergonomics pass -- Step 1 core landed;
      finish the device error-scope plumbing if still deferred, then the later
      steps. [src: compute_improvements_plan]
- [ ] Fold `kompute.zig` + `compute_host.zig` into the module DAG (deferred from
      the STRUCTURE_PLAN S2 flatten -- they are named-module roots like
      shader_interface, so folding means re-rooting a module). [src:
      STRUCTURE_PLAN; compute_improvements_plan]
- [ ] Kernel FUSION (#2): fuse the multi-kernel SPH passes to cut dispatch
      overhead. [src: compute_atomics_plan]
- [ ] Shared-memory TILING (#3): the big rewrite -- needs a spatial sort first;
      acceptance bar is matching the hand-written WGSL SPH. [src:
      compute_atomics_plan]
- [ ] `k.Buffer(T)` clean synthesis deferred (wanted `@Type`, removed in Zig
      0.17 -- needs a different synthesis path). [src: sph_compute_plan]

## Math
- [ ] Reserved-math P4: migrate the remaining body-level `zm.X` uses to named
      imports (a few files left, incl. physics), then enable the `R_core` linter
      rule banning any remaining body-level `zm.X`. [src: RESERVED_MATH_PLAN]
- (optional / someday) single-type math unification; SDF playground + SDF text
  expansion; Camera3D-in-a-UBO; a Cornell-box flagship. [src: math_unification]

## 3D pipeline
- [ ] RECONCILE `3D_PIPELINE_PLAN`'s build-order checkboxes against the code. Its
      "remaining" marks (retained Mesh/Model, instancing, skybox, glTF) predate
      work that has since landed -- glTF examples, `drawMeshInstanced`,
      `drawSkybox`, and the retained-mesh API all exist now. Confirm what is
      truly left, then trim/archive the plan. [src: 3D_PIPELINE_PLAN -- kept
      current until reconciled]

## Shader pipeline + spv2wgsl
- [ ] `zimr_build` Phase 3b: cross-platform prebuilt shader-compiler binaries +
      a standalone. [src: shader-pipeline-external]
- [ ] Typed-shader follow-ups: WGSL output via a `--target` flag; cross-compiled
      prebuilt binaries; a comptime GLSL validator; multi-UBO frequency
      separation. [src: typesafe_zig_shaders]
- [ ] spv2wgsl coverage gaps: remaining raw-corpus fails are I/O accessed inside
      a HELPER (not the entry point); ~13 tint_corpus raw cases still bail.
      [src: spv2wgsl_hardening]
- [ ] spv2wgsl: forward-ref phi (a phi naming a value defined later) is deferred.
      [src: spv2wgsl_ir_rewrite]

## WebGPU ergonomics + 2D
- [ ] Remaining 2D shapes on wgpu: ellipse, thick line (-> quad), triangle,
      polygon (N5c). [src: wgpu_new_beginnings]
- [ ] Input contract on the wgpu bridge (N5d, deferred). [src: wgpu_new_beginnings]
- [ ] Make host<->shader std140 UBO layout mismatches a COMPILE error (Simon's
      standing ask). [src: finishing_webgpu]
- [ ] Prefix convention + an atomic rename pass; engine-VS native-importability
      (codegen surgery; two unblock paths identified). [src:
      finishing_new_gpu_foundations]

## Ports / examples
- [ ] RECONCILE the example port queue before archiving the port plans:
      PORT_PLAN + GL_RETIREMENT_PLAN list each GL example as ported, superseded
      (documented), or deferred-to-a-named-arc -- confirm the deferred ones are
      tracked so none are dropped. [src: PORT_PLAN; GL_RETIREMENT_PLAN -- kept
      current until reconciled]

## Bridge (TS/JS retirement -- DONE; tail items)
- [ ] tests.zig inclusion in the bridge build (deferred to cleanup); a couple of
      bridge buffer-read gaps noted in phase 3d. [src: ZIG_BRIDGE_PLAN]

## Build / process
- [ ] Wire the `sw_*` build steps into one aggregate `zig build sw-all` test so
      they run together. [src: PORT_PLAN]
- [ ] Regenerate `files.md` (the file atlas; generated 2026-06-11, now stale) via
      `scripts/gen_files_md.py`.

## Backlog (planned, not built)
- [ ] `plot.zig` -- a single-file plotting library for zimr (spec written, not yet
      implemented; `src/plot.zig` does not exist). [src: plot-plan -- kept]
