# Shader pipeline — state of the code, May 2026

A snapshot tour of where the Zig-shader pipeline arc stands today,
followed by what the codebase will look like once the plan
(`zig-shader-pipeline-plan.md` S0 → S1.7) is fully landed.  Read this
when picking the arc back up after a long pause, or when onboarding
a new session that needs to know what's already done and what's not.

Companion to:
- `zig-shader-pipeline-plan.md` — the spec and status board
- `tutorials/zig-shader-tutorial.md` — the how-to-author-a-shader guide
- `shader-style.md` — codified dos and don'ts

---

## 1. Where we are right now

### 1.1 The pipeline itself — done and stable

The five-stage pipeline runs end-to-end in `tools/build.zig` +
`build.zig`:

```
mandelbrot_fs.zig                  (Zig source)
    │ zig build-obj
    │   -target spirv32-vulkan -mcpu vulkan_v1_2
    │   -ofmt=spirv -O ReleaseFast -fno-llvm -fno-lld
    ▼
mandelbrot_fs.spv                  (raw SPIR-V)
    │ tools/zig-out/bin/spirv-opt -O --skip-validation
    ▼
mandelbrot_fs.opt.spv              (inlined, dead-stripped SPIR-V)
    │ tools/zig-out/bin/spirv-val
    │   (build-time sanity check; bails the build if the SPIR-V is malformed)
    │ tools/zig-out/bin/spirv-cross --version 300 --es
    ▼
mandelbrot_fs.glsl                 (GLSL ES 3.0, WebGL2-ready)
    │ @embedFile in host Zig code, sometimes through shader_post.rewriteMatUniforms
    ▼
shader bytes baked into the wasm
```

`ShaderPipeline.addShader` (`build.zig` line 1359) drives one shader
through all four tool invocations and returns a `LazyPath` to the
final `.glsl`.  `ShaderPipeline.addShaderImport` further wires it as
an `@embedFile`-able import on a module.

### 1.2 Infrastructure modules — done

| File | Lines | Role |
|---|---|---|
| `src/shadermath.zig` | 409 | GPU-side math module — `Vec`, `Vec2`, `Vec3`, `Mat`, scalar helpers (`clamp01`, `mix`, `fract`, `smoothstep`, `step`, `square`, `atan2`, `pow`, `log2`), generic vector ops (`dot`, `length`, `distance`, `normalize`), `mulMatVec` / `mulMatPoint` for the matrix workaround, `sw` swizzles, and the `location` / `binding` inline-asm decoration helpers.  API mirrors `math.zig` for shared concepts (the parity rule from §0.3 of the plan). |
| `src/shader_post.zig` | 49 | One function: `rewriteMatUniforms`, a comptime text rewrite that fixes `uniform vec4 N[4];` → `uniform mat4 N;` in spirv-cross output.  Workaround for Zig 0.16's SPIR-V backend having no `OpTypeMatrix`. |
| `src/uniform_buffer.zig` | 145 | `UniformBuffer(T)` — the typed GL UBO wrapper.  `create` / `attach` / `push` / `destroy` lifecycle.  Comptime asserts the struct is `extern` and `@sizeOf(T) % 16 == 0` (std140 trailing-pad rule). |

### 1.3 Build integration — done

`build.zig` knows how to:
- **Auto-discover** any `_vs.zig` / `_fs.zig` under `src/`, `examples/`,
  or `tests/` via `collectShaderFiles` (line 422 area).
- **Engine-shader loop**: every shader in `src/shaders/` becomes a
  `<name>.glsl` import on `zimr_mod` and `zimr_mod_smoke`.  Drop a
  new file in; no `build.zig` edit needed.
- **Example loop**: each example with a `_fs.zig` / `_vs.zig`
  sibling gets the same auto-wiring on its standalone build.
- **ZLS shadow modules**: every shader source is registered as
  `shader_zls:<path>` with `shadermath` in its imports.
  Go-to-def into `zm.X` lands in `src/shadermath.zig` from any
  `_vs.zig` / `_fs.zig` file.
- **Lint integration**: `zimrlint` (built via `tools/build.zig`)
  has two shader-specific rules (`shader-inline-fn`, `shader-no-atan`)
  that auto-fire on `_vs.zig` / `_fs.zig` files.

### 1.4 Shaders migrated to the pipeline

**Engine shaders** (`src/shaders/`):

| File | Status |
|---|---|
| `default_vs.zig` | ✅ Visually verified with cube3d |
| `shadow_vs.zig` | ⏸ Built clean, awaiting visual verify (reload `models3d` + shadow-casting example) |
| `shadow_fs.zig` | ⏸ Built clean, awaiting visual verify |
| `skybox_vs.zig` | ⏸ Built clean, awaiting visual verify with the `skybox` example |

**Example shaders** (co-located with examples/):

| File | Status |
|---|---|
| `mandelbrot_fs.zig` | ✅ Verified — the PoC; UBO host wiring matches |
| `shader_uniforms_fs.zig` | ✅ Verified — UBO via the pipeline |
| `tests/fixture_fs.zig` | ✅ End-to-end fixture exercised every build |

### 1.5 What's NOT migrated yet — still inline GLSL strings

In `src/rlgl.zig`:

- `DEFAULT_VERTEX_SHADER` (line 1981) — **trick case**: looks
  inline at the call site but is actually `@embedFile("default_vs.glsl")`
  wrapped in `rewriteMatUniforms`.  Migrated.
- `DEFAULT_VERTEX_SHADER_SKINNED` (line 2014) — **truly inline**;
  blocked on extending `rewriteMatUniforms` to handle arrays of
  mat4 (`bone_matrices[60]` flows through SPIR-V as `vec4[240]`,
  needs a different rewrite shape than single mat4).
- `DEFAULT_FRAGMENT_SHADER` (line 2049) — **truly inline**; no
  blocker known, just hasn't been done.  The FS pairs with
  `default_vs` so naming continuity (camelCase `fragTexCoord` /
  `fragColor`) is already in place; migration is mostly mechanical.

Examples with inline GLSL: `examples/instancing.zig` (folds into
S1.5 batch 1 per the plan), plus 2 others that still hold an
inline `loadShaderFromMemory` call.

### 1.6 Patterns discovered during S1.1-S1.4 — codified in `shader-style.md`

Eleven gotchas worth knowing without re-deriving (full appendix in
`zig-shader-pipeline-plan.md` §4):

1. `-fno-llvm -fno-lld` mandatory — default LLVM segfaults on SPIR-V targets.
2. `callconv(.spirv_fragment)` / `.spirv_vertex` triggers `OpEntryPoint`.
3. `addrspace(.input)` / `.output` / `.uniform` / `.constant` tag interface variables.
4. No `bool` storage — emits as `u1` → spirv-cross emits `uint8_t` → WebGL2 rejects.  Use `u32` flags.
5. Wrapping arithmetic (`+%`, `-%`, `*%`) — otherwise Zig emits overflow checks as `OpIAddCarry` struct packs.
6. `-O ReleaseFast` — avoids debug safety checks.
7. `std.gpu` in 0.16 has builtins but NOT decoration helpers; declare `location` / `binding` locally via inline asm.
8. Use `spirv-opt -O` (preset), not granular flags.  The preset orders dead-branch-elim → merge-return → inline → dead-strip correctly.
9. Inline-asm operand names leak as SPIR-V debug names.  Use `target` as the placeholder, not `ptr`.
10. No `pub inline fn` in shader DSL helpers — breaks structured-control-flow markers.  Use plain `pub fn` and let `spirv-opt -O` inline.
11. Uniform without UBO is a dead-reference fail.  Wrap in `extern struct` + `addrspace(.uniform)` + `binding(...)`.  (See `zig-shader-pipeline-plan.md` §0.4 for the disassembly trace that proved this.)

### 1.7 What blocks what — dependency status

```
S0 ──────────✅─────┐
                    │
S1.1 (tools) ───✅──┤
                    │
S1.2 (infra) ────✅─┤
                    │
S1.3 (mandelbrot)─✅┤
                    │
S1.4 (shader_uniforms) ─✅─┐
S1.4.5 step 1 (.constant) ─✅─ unblocks engine matrix uniforms
                            │
                            ├──► S1.5 batch 1 (no-texture engine shaders) ⏸ in flight
                            │      • default_vs ✅
                            │      • shadow_vs/fs, skybox_vs — built, need browser verify
                            │      • pbr_vs — not started
                            │      • default_vs_skinned — blocked on mat4-array rewrite
                            │      • DEFAULT_FRAGMENT_SHADER — not started
                            │
                            ▼
                          S1.4.5b (sampler inline-asm DSL) ⏸ not started
                            │
                            ▼
                          S1.5 batch 2 (texture engine shaders) ⏸ waiting
                            │
                            ▼
                          S1.7 (typed UBO wrappers via std.zig.Ast) ⏸ not started — no blocker; could be done in parallel

S1.6 (style guide + lint) ─⏸ partial: doc exists, 2 lint rules landed, more rules can join opportunistically
```

### 1.8 Adjacent finding (not in the plan)

The prebuilt-SPIRV-binaries workflow shipped this turn (the
`tools/spirv-prebuilt-linux-x86_64/` dir + `use-prebuilt-spirv.sh`
script) **does not actually short-circuit `zig build test`**.
The script places binaries in `tools/zig-out/bin/` but Zig
invalidates them on the next build because the cache stamps
don't match.  Cold `zig build test` still pays ~10 min for the
SPIRV-Tools rebuild.

The right fix is "Option C" from the prebuilt brainstorm:
teach `tools/build.zig` to detect the prebuilt dir and
`installBinFile` the binaries instead of recompiling.  ~30 lines.
Filed as a follow-up; current PLAN.md end-of-plan block notes it.

---

## 2. Where we'll be when the plan completes (post-S1.7)

### 2.1 Authoring a shader — the developer experience

Drop `examples/my_example.zig` + `examples/my_example_fs.zig` (and
optionally a `_vs.zig`) into the repo.  Run `zig build`.  Done.
Pipeline auto-wires it.  ZLS sees `@import("shadermath")` and
gives you completion + go-to-def into `src/shadermath.zig`.
`zig fmt` formats the file.  `zimrlint` runs the shader rules
on it.  If you typo a uniform name, the Zig compiler tells you
at edit time, not the GPU driver at runtime.

For UBO uniforms (S1.7), the typed wrapper closes the host/shader
struct duplication:

```zig
// Today:
const Uniforms = extern struct {
    center: Vec2, zoom: f32, _pad0: f32 = 0,
    resolution: Vec2, max_iter: f32, _pad1: f32 = 0,
};                                // host file
extern const u: Uniforms          // shader file (must keep in sync by hand)
    addrspace(.uniform);

// Post-S1.7:
const Uniforms = z.SharedUniforms("mandelbrot_fs"); // parses shader source
// the host gets a typed struct with verified std140 layout
// — typo / wrong-type bug class eliminated at compile time
```

The exact spelling will land with S1.7; the principle is
single-source-of-truth for the UBO shape, with a `std.zig.Ast`
parse extracting the layout from the shader source at comptime.

### 2.2 What disappears

- The three inline-GLSL-string constants in `src/rlgl.zig`.
- Manual host-mirror structs for UBO uniforms.
- Silent "shader fell through to default" failures — `spirv-val`
  in the build pipeline catches malformed shaders before they
  ship.
- Two-language context-switching when reading the engine —
  rlgl uses Zig types everywhere, not GLSL string fragments.

### 2.3 What stays the same

- Runtime: still raylib-style GL bindings via `gl.*` extern functions.
- GLSL ES 3.0 as the wire format to WebGL2 — the shader source is
  Zig but what reaches the browser is still GLSL.
- Existing examples that hand-roll a fragment shader keep working
  (the inline-string path isn't removed, just preferred against).
- Hard-fork of SPIRV-Tools — no upstream tracking, no .zon deps,
  no surprise breakages.  When something inside breaks we fix it
  in-tree.

### 2.4 Whole-codebase invariants after S1.7

- **One language**: Zig everywhere, including shaders.
- **Two math modules with mirrored APIs** — `math.zig` (CPU SIMD,
  row-major) and `shadermath.zig` (GPU, column-major in
  GLSL terms).  Adding a helper on one side is a prompt to
  consider adding it on the other; the parity is a soft rule, not
  enforced.
- **All shaders go through `spirv-val`** at build time — the
  "shader compile failed silently in the browser" bug class is
  gone.
- **UBOs everywhere for uniforms** — no individual-uniform
  `glUniform*` paths in new code.  Existing loose-uniform code
  (e.g. `default_vs`'s `mvp` via `addrspace(.constant)`) stays
  for the cases where a single matrix is genuinely simpler than
  a UBO, but the default is UBOs.
- **Auto-discovery** — adding shaders never requires a `build.zig`
  edit.

### 2.5 Open follow-ups beyond S1.7

Not in scope for the migration arc:

- **WGSL output**: a one-line `--target` change in spirv-cross is
  the natural path to WebGPU.  Since we're already on UBOs (which
  match WebGPU's uniform model), the shader side is mostly free.
  The host-side WebGPU backend is the bigger lift.
- **Cross-compile SPIRV tools to Windows**: today Simon builds
  them natively on Windows; the prebuilt-Linux-only convention is
  Linux-sandbox only.  A `windows-x86_64` directory in the same
  pattern would mirror the workflow on Windows for hermetic-build
  shops that want it.
- **Comptime GLSL validator**: belt-and-suspenders.  Parse the
  GLSL output at comptime and assert structural properties before
  it hits `spirv-val`.
- **Native Zig SPIRV-Cross replacement**: 20-45 turn project.
  Revisit only if the vendored C++ becomes painful to maintain
  (so far it hasn't — the hard fork means we never get surprised
  by upstream).
- **Multi-UBO designs**: split per-frame, per-pass, per-material,
  per-draw uniforms into different binding-frequency UBOs.  Worth
  doing if profiling shows single-UBO update cost matters.

### 2.6 The arc's payoff

The headline business value: **the "silent shader compile failure"
class of bugs is gone**.  This was the bug that triggered the arc
in the first place — mandelbrot on the phone fell through to the
default shader and rendered pink, with no error visible until
manual investigation.  Post-arc, that bug shape can't exist: every
shader is type-checked at build time, validated by `spirv-val` at
build time, and any varying / uniform name mismatch is a Zig
compile error long before WebGL sees the bytes.

The secondary value: **one tool, one language, one set of
abstractions for the whole rendering pipeline**.  No more "is this
a GLSL bug or a Zig bug" decisions at 11pm.

---

## 3. Reading order if you're picking this up cold

1. This file (you're here).
2. `zig-shader-pipeline-plan.md` — status board (§5) is the
   authoritative list of done/pending steps.
3. `tutorials/zig-shader-tutorial.md` — how to write a shader.
4. `shader-style.md` — the dos and don'ts in reference form.
5. `examples/mandelbrot_fs.zig` + `examples/mandelbrot.zig` — the
   canonical worked example, including the host UBO wiring.
6. `src/shadermath.zig` — when you need a helper that isn't there
   yet.  Mirror it from `math.zig` if the concept exists CPU-side.
7. `tools/build.zig` `ShaderPipeline` (line 1344+) — when you
   need to understand or extend the build wiring.
