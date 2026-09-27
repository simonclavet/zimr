# vulkan port plan v2 - zimr on Windows through Vulkan, running the Zig compiler's own SPIR-V

**Status: DRAFT (Sep 27).**
* **Nothing is implemented.**
* All eight decisions in section 10 are made. The plan becomes final when Simon confirms all of
  them together.
* **Even a final plan is not permission to implement.** That needs Simon's explicit go-ahead.

Written fresh: the earlier native plan in this directory was deliberately NOT read, so the two can
be compared.

**The goal, stated so it can fail.** `zig build <example>-windows` produces one Windows `.exe` from
the SAME example source, the SAME engine code above `src/wgpu.zig`, and the SAME `.spv` bytes the
web build hands to `spv2wgsl` - no WGSL on native, no translator, no third-party library, nothing
but the Zig compiler at build time and the GPU driver's `vulkan-1.dll` at run time. On Simon's
laptop (AMD Radeon 780M + NVIDIA RTX 5060 Laptop) each example draws what Chrome draws, the Vulkan
validation layer stays silent, and the GPU-handle census returns to zero at exit. The web build keeps
its behaviour and stays the platform every feature lands on first.

---

## 0. The whole plan on one screen

* **The seam already exists.** Every GPU call goes through 60 wrappers in `src/wgpu.zig`, each of
  them `if (comptime !is_wasm) return <stub>; js_x(...)`. On the web, `src/bridge.zig` (Zig compiled
  to JavaScript) implements the `js_x` calls. The Vulkan backend is a second implementation of the
  same 60 calls, with the same u32 handles and the same descriptor blobs: **a native twin of
  bridge.zig**. Nothing above `wgpu.zig` changes for the GPU.
* **The frame loop already exists.** The wasm's `main` calls `App.run`, which returns. The browser
  then calls the exported `update(dt)` once per animation frame and pushes input through
  `input_push_*`. Natively `App.run` does not return: it opens a window and loops, calling the same
  `update` and the same input functions. No example changes.
* **The graphics shaders are already Vulkan SPIR-V.** Every shader is already
  `zig build-obj -target spirv32-vulkan`. All 79 cached graphics modules pass an audit of the Vulkan
  rules (section 1.4). Three small gaps are handled by a ~100-line load-time legalization in the
  native host:
  * `DepthReplacing` on the 2 depth-writing shaders. Zig cannot express it.
  * `NonWritable` on the 2 vertex shaders that read storage buffers.
  * `PointSize` for point lists. Vulkan 1.4's maintenance5 covers this.
* **The compute kernels are not Vulkan SPIR-V yet, and the fix belongs in the source.**
  * kompute's atomics and workgroup barriers are dummy `noinline` helpers; spv2wgsl swaps them for
    WGSL built-ins by name.
  * kompute's buffers carry no binding numbers.
  * A probe showed inline-asm `OpAtomicIAdd/Load/Store` plus `std.spirv.workgroupBarrier()` compile
    to real atomics and barriers under the current compiler. So the fix is kompute emitting real
    SPIR-V (the migration its own comment describes) and spv2wgsl translating those ops. This is a
    web-path change, verified on a phone first.
* **The Vulkan is the simplest correct subset.** Vulkan 1.3 core:
  * dynamic rendering (no render-pass or framebuffer objects), synchronization2 and one queue;
  * one timeline semaphore numbering every submit;
  * every image in `GENERAL` layout, with one full memory barrier between passes;
  * one memory allocation per resource;
  * uploads through staging copies placed ahead of the next submit, so `writeBuffer` keeps WebGPU's
    queue-timeline meaning;
  * hand-written bindings for the ~95 functions used, loaded from `vulkan-1.dll` at run time.

  Performance comes after correctness, and only against a measurement.
* **Windows is a thin layer.**
  * One window, per-monitor DPI, and a single-threaded message pump.
  * The pump translates Win32 messages into the same `input_push_*` calls the browser makes, in the
    engine's own units and numbering.
  * The ~30 OS functions are hand-declared. This Zig's std has neither `DynLib` for Windows nor any
    user32 binding.
* **"Native" stops meaning "no GPU".** 216 `isWasm()` gate lines in 10 files conflate "not a
  browser" with "no GPU". For example, `text2d` turns font loading into a no-op natively. Each gate
  is reclassified against three comptime facts: is a browser, has a GPU, has a window.
* **About 6 500 new lines** in six new flat files in `src/` (`vk.zig`, `wgpu_vulkan.zig`,
  `spv_vulkan.zig`, `win32.zig`, `native_services.zig`, `native_loop.zig`), plus bounded engine
  edits:
  * the host switches in `wgpu.zig` and `web.zig`;
  * the gate reclassification;
  * `App.run`'s native branch;
  * kompute's bindings, atomics and barriers;
  * a backend-neutral name for the embedded shader artifact.
* **Nine stages (section 6).** Each adds one thing and has one number that says pass or fail. The
  first stage feeds every cached graphics `.spv` to both GPUs before any engine code is touched.

---

## 1. What the study found

Every number below was measured this session, on this machine and this tree. The four study reports
(mach's Vulkan backend, mach's Windows core, zimr's host imports, zimr's shader chain) are in this
session's transcript; what matters is summarized here with file:line references.

### 1.1 The machine

| what | measured |
|---|---|
| Vulkan loader | `C:\Windows\System32\vulkan-1.dll`, 1.4.321 |
| GPU 0 | AMD Radeon 780M (integrated), driver 25.20.42.09 (LLPC), Vulkan 1.4.329 |
| GPU 1 | NVIDIA GeForce RTX 5060 Laptop (discrete), driver 596.13, Vulkan 1.4.329 |
| surface formats | BOTH offer `R8G8B8A8_UNORM` and `B8G8R8A8_UNORM` (+ sRGB, A2B10G10R10) on a win32 surface |
| present modes | both: FIFO, FIFO_RELAXED, IMMEDIATE, FIFO_LATEST_READY; NVIDIA also MAILBOX |
| Vulkan SDK | **not installed**: no validation layer, no `spirv-val`, no `VULKAN_SDK` |
| Zig | `0.17.0-dev.2122` on PATH; `0.17.0-dev.2313` in `C:\dev`; the tree's last recorded bump is 2307 |
| std on Windows | `std.DynLib` is `@compileError("unsupported platform")`; `std/os/windows/kernel32.zig` is 27 lines; no user32 |

**Hybrid laptop.**
* Device selection must prefer the discrete GPU and allow an override.
* Presenting from the NVIDIA GPU to a display driven by the AMD one must be checked with
  `vkGetPhysicalDeviceSurfaceSupportKHR`, not assumed.

**OS calls.** Every OS call is hand-declared, the way `tools/fs_space.zig` already hand-declares
`GetDiskFreeSpaceExA`.

### 1.2 zimr's GPU seam: `src/wgpu.zig` and the frame protocol

* **60 host calls with one shape.**
  * Handles are an `enum(u32)` per kind, where 0 means invalid.
  * Arguments are u32/u64/f32/pointer+length.
  * Bind-group layouts, bind groups and render pipelines arrive as byte blobs built by `src/gpu.zig`
    (layouts are 5 u32 per entry, although the comment says 4).
  * Callers, examples included, build the blobs themselves. So the typed descriptor is gone before a
    call reaches `wgpu.zig`.
* **The gate is one line, repeated.** `const is_wasm = builtin.target.cpu.arch.isWasm();` (`:45`),
  and every wrapper opens with `if (comptime !is_wasm) return .invalid;` or an equivalent default.
* **The census is host-independent.** Every create/destroy wrapper bumps `live_handles` per
  `HandleKind` (`:613-669`), so the same leak gate works for Vulkan unchanged.
* **The frame.**
  * `gpu_iface.WgpuBackend.beginFrame` (`src/gpu_iface.zig:488-500`) is `getCurrentTextureView` +
    `createCommandEncoder` + `ensureDepth`.
  * `endFrame` (`:509-513`) is `finish` + `queueSubmit` + `surfacePresent`.
  * **There are more submits than one per frame.** `compute_host` submits its own batch and
    recording encoders (`src/compute_host.zig:1071-1139, 1324-1364, 1510-1520`) and `material.zig`
    submits one (`:467-474`).
  * `compute_host` states the rule the backend must keep: *"a `writeBuffer` issued mid-recording
    lands before the WHOLE recording executes"*. That is WebGPU's queue timeline. Recordings also
    copy params between dispatches on the GPU.
* **The entry points** are in `src/wgpu_app.zig`:
  * `App.run` (`:550`) builds the device, queue, surface, caches and `State`, then returns.
  * `export fn update(dt)` (`:4667`) builds a `Frame`, runs the app and advances input. It ignores
    `dt` and recomputes it from `nowMs`.
  * The input exports are at `:4716-4785`.
  * `App.run` refuses native outright (`error.WgpuRequiresWasm`) and allocates from
    `std.heap.wasm_allocator`.
* **Two app shapes.**
  * Ticked apps go through `src/wgpu_runner.zig`, whose `main` calls `zimr_app.run`.
  * 17 examples have their own `main`, and 43 set `manages_own_frame`.
  * Both shapes reach `App.run`, so letting `App.run` own the native loop covers both.
* **One color format.** The bridge forces the canvas to `rgba8unorm` with opaque alpha
  (`src/bridge.zig:909`, `:3128`), so the cached 2D pipeline is valid for both the swapchain and
  RGBA8 render textures. Both GPUs here offer `R8G8B8A8_UNORM` swapchains.
* **Depth** is always cleared to 1.0 and stored (`bridge.zig:1781-1783`). **Blend** is five modes
  with exact factors (`:2405-2440`, table in 5.4.7).
* **The vocabulary is small and all core WebGPU.**
  * Textures: 11 formats; 2D only, with sample count, mip levels and array layers.
  * Views: whole, mip range, or 2D-array.
  * Samplers: filters plus one address mode.
  * Pipelines: 8 vertex formats, 5 topologies, 3 cull modes, 9 depth modes, 5 blend modes.
  * The ABI is lossy in ways that make a backend simpler: textures always sample as float; storage
    textures are always write-only rgba8; samplers set U/V only; vertex/index buffer `size` is
    ignored (whole buffer).

### 1.3 zimr's other host imports

Measured from the import sections of all 314 built gallery wasms (`zig-out/web`):

| namespace | declared | provided by bridge.zig | imported by at least one app |
|---|---|---|---|
| `wgpu` | 60 | 60 | 59 (`js_adapter_info` unused) |
| `dom` | 91 (`src/web.zig`) | 59 | 56 |
| `audio` | 23 | 23 | 18, by 7 apps |
| `jobs` | 6 | 6 | 6, by 18 apps |
| `wasi_snapshot_preview1` | implicit | 30 | 27 (irrelevant natively: compiled natively, std uses the OS) |

* **Import counts.** Apps import 42 to 107 functions each (median 73; the launcher has the most).
  41 `wgpu` calls plus `dom.js_log` and `dom.js_crypto_random_fill` cover the large majority.
* **Exports the browser calls.** 12 functions: `_initialize`, `update`, and the `input_push_*`
  family. The `runner*` exports are for the smoke and leak harness only.
* **Everything asynchronous is a poll.** Readback, OGG decode, jobs, WebSocket, WebRTC, user files
  and timestamps all work this way. There is no callback into the wasm, which suits a native loop
  exactly.
* **Natively, an `extern "dom"` (or `"wgpu"`, `"audio"`, `"jobs"`) declaration becomes a link
  dependency on a library of that name.** On wasm the same declaration is an import module. So on
  native no extern may ever be analyzed. The wgpu wrappers achieve that with comptime-dead branches.
  **`web.dom` gates only 4 of its 69 wrappers**; callers gate the other 61. Examples are only ever
  type-checked as wasm (`build.zig:557-566`). The native build is therefore the first time example
  code is compiled for a native target: expect a few call sites to need gating, e.g.
  `examples/state_persistence` calls `z.web.dom.persistence_*` directly.
* **Things the native host must match** (from the inventory):
  * **Input numbering.** `KeyboardKey` is raylib's numbering (escape 256, arrows 262-265, F1 290);
    `MouseButton` is left 0, right 1, middle 2.
  * **Input order.** Mouse move is pushed before the button, because `press_position` is
    snapshotted on the rising edge.
  * **Sizes.** Surface sizes are packed 16:16, so each dimension must stay at most 65535.
  * **Text input.** `input_push_char` is never called by the bridge: web text entry goes through DOM
    overlay `<input>`s. On native, `ui.zig`'s host path (`:27526-27706`) no-ops the overlays and
    reads the char queue, so `WM_CHAR` -> `input_push_char` is the whole job.
* **Two web bugs were found in passing and flagged as separate tasks** (not this plan's work):
  * The bridge passes DOM `keyCode` and DOM `button` numbers straight into the engine, so Escape,
    the arrows, punctuation and the right/middle buttons arrive wrong on the web.
  * The bridge mints a new surface-view handle every frame and never releases it.

### 1.4 The SPIR-V the Zig compiler emits, audited

**Method.** A Python reader (scratchpad, not committed) walked all 93 `.spv` in `.zig-cache`
(79 `shader.spv`, 14 `compute.spv`), built this morning by the 2122 compiler. The shader-chain study
independently walked the same corpus deeper.

| rule | graphics (79 modules: 27 VS + 52 FS entries) | compute (14 modules, 192 entries) |
|---|---|---|
| SPIR-V version / memory model | 1.5, Logical GLSL450 | same |
| capabilities | `Shader` + `Linkage` (2122 only, see probe 1) | same |
| scalar widths, extended instructions | f32 and i32 only; `GLSL.std.450` | same |
| resources carry DescriptorSet + Binding | **all** (86/86 UniformConstant, 65/65 Uniform, 3/3 StorageBuffer) | **none**: `P` and every `kbuf_*` (14 Uniform, 67 StorageBuffer) |
| Input/Output carry Location or BuiltIn | all (269/269) | - |
| `Block` / member `Offset` / `ArrayStride` | all 103 blocks, 149 members, 119 arrays | same |
| entry-point interface lists its globals (SPIR-V >= 1.4 rule) | yes | yes, per entry |
| structured control flow | 3 512 selection merges, 206 loop merges; merge-less branches are all loop breaks | same |
| atomics and barriers | - | **0 `OpAtomic*`, 0 `OpControlBarrier`**: dummy `noinline` helpers that spv2wgsl replaces by name |
| pointers into functions | none | **39 calls pass StorageBuffer pointers and 12 parameters are StorageBuffer pointers**, all inside those helpers; invalid without `VariablePointers` |
| `FragDepth` written without `DepthReplacing` | **2** (`depth_write_fs`, `hybrid_raymarch_fs`) | - |
| vertex-stage storage buffers without `NonWritable` | **2** (`points_vs`, `fluid_discs_vs`) | - |
| `point_list` drawn with no `PointSize` written | yes (`gpu.zig:170`, `point_rendering`) | - |
| images | 28 x sampled 2D, format Unknown, separate sampler, `OpSampledImage` | - |
| spec constants, integer varyings without `Flat` | none | none |
| `ArrayStride` on pointer types | 74 Uniform + 29 StorageBuffer pointer types (unusual, check with the validator) | - |
| host layout vs SPIR-V `Offset` | `shader.wireOf` matches exactly (fog_fs 0/16/32/48/64; julia_fs 0, 8, 12, 16, ...) | `Params` is an `extern struct` |

**The probes** (scratchpad), because a table is not a verdict:

1. **`Linkage` comes only from the old compiler.** A trivial fragment shader and
   `tests/fixture_fs.zig` emit `Shader + Linkage` under 2122 and **`Shader` alone under 2313**.
   No module under either compiler carries a `LinkageAttributes` decoration. So a guard that
   refuses `Linkage` is enough.
2. **`DepthReplacing` cannot be expressed in this Zig.**
   * `SpirvFragmentOptions` has only `pixel_centered_integer` and `depth_assumption`
     (`std/lang.zig:530`). `depth_assumption` emits `DepthGreater`/`Less`/`Unchanged`, never
     `DepthReplacing`.
   * Inline asm is refused: `error: cannot set execution mode in assembly`.
   * WGSL infers the mode, which is why the web path never noticed it was missing.
3. **`build-exe` works for SPIR-V** and emits the same module as `build-obj`.
4. **`@atomicRmw` is still unimplemented for SPIR-V** in both 2122 and 2313:
   `error: TODO (SPIR-V): implement AIR tag atomic_rmw`.
5. **Inline-asm atomics do work.** `inline fn`s wrapping `OpAtomicIAdd`/`OpAtomicLoad`/
   `OpAtomicStore`, plus `std.spirv.workgroupBarrier()`, compile under 2313. The result has real
   `OpAtomic*` and `OpControlBarrier` instructions, **zero pointer-typed function parameters**, and
   only the `Shader` capability.

**Verdict.**
* **The graphics SPIR-V is already Vulkan SPIR-V** apart from three named gaps, each closed by a
  legalization of a few instructions (5.5).
* **The compute SPIR-V is not**, and the right fix is at the source (probe 5 proves it can be
  written today).
* The audit is not `spirv-val`: it checks the rules I know about, not all of them. So stage S0 puts
  every graphics module through BOTH drivers, and through the validation layer once one is
  installed.

### 1.5 The shader chain today

* **Graphics** (`src/shader_codegen.zig`), per shader, in four steps:
  1. A generated bootstrap exe writes `<name>_externs.zig` from the `_io.zig` schema.
  2. `zig build-obj -target spirv32-vulkan -mcpu vulkan_v1_2 -fno-llvm -fno-lld -O ReleaseFast
     -ofmt=spirv` (`:405-468`) produces `shader.spv`.
  3. `spv2wgsl --strict` converts it to WGSL.
  4. The bootstrap exe re-checks the WGSL bindings against the schema (`--check-wgsl`).

  The checked WGSL is exposed as an anonymous import named `"<name>.wgsl"` (`build.zig:1000`), and
  consumers write `@embedFile("fog_fs.wgsl")`. **The `.spv` is a Run output that nothing
  exposes**: `ShaderOutput` has only `externs` and `wgsl` (`:193-200`).
* **Compute** (`addCompute`, `:548-624`):
  * The same flags produce `compute.spv`.
  * spv2wgsl then runs once per entry (`--entry`), with no strict mode or schema check.
  * Each entry is exposed as `"<entry>_wgsl"`, e.g. `@embedFile("double_it_wgsl")`, or via
    `name ++ "_wgsl"` in multi-kernel hosts.
  * The result is 13 kernel modules (`zn_unary` 65 entries, `zn_binary` 40, `zn_mlp` 35, ...), 192
    entries in all, becoming 227 per-entry WGSL modules.
* **Runtime use.**
  * `loadShader` calls `wgpu.createShaderModuleWgsl`, then builds the pipeline with entry `"entry"`
    (the generated wrapper's name).
  * `compute_host.initGpu` takes `KernelWgsl{ name, wgsl }`. It derives each kernel's used fields
    by scanning the WGSL body (`usedFields`) and the binding numbers by scanning the WGSL headers
    (`parseBindings`).
* **Bindings.**
  * Graphics decorations are in the SPIR-V via `ExternOptions.decoration`: VS uniforms in group 0,
    samplers in group 1, FS uniforms in group 2. `shader_interface.uniformGroupForSchema` is the one
    authority.
  * Compute is undecorated on purpose. spv2wgsl auto-numbers in SPIR-V variable order, and the host
    reads the numbers back (`spv2wgsl.zig:1876-1879`).
* **The spv2wgsl passes a Vulkan path needs equivalents of:**
  * the atomic and barrier intercepts;
  * compute binding numbers;
  * forcing vertex storage to `read`.

  **Passes it does not need:** control-flow reconstruction, OpPhi lowering, SCCP, runtime-sizing of
  storage arrays (an Adreno workaround), NaN helpers.
* **Where the WGSL path diverges from the SPIR-V's meaning:**
  * `OpUndef` becomes `T()`, and function variables are zero-filled.
  * Workgroup memory is zero-initialized, and buffer access is bounds-checked.
  * `OpSMod` becomes `%`, which is wrong for mixed signs, and `FUnord*` becomes ordered comparisons.

  **Native can therefore be MORE exact than the web.** A pixel difference is not automatically a
  native bug.
* **Not every shader is Zig.** Hand-written WGSL with no SPIR-V source exists in 8 examples:
  `fluid_gpu`, `forward_kinematics`, `pipeline_array`, `pipeline_constants` (uses WGSL `override`),
  `pipeline_mipmap`, `pipeline_sampler`, `pipeline_storage`, `shader_inspection`. It also exists in
  `src/wgpu_smoke_test.zig`. These stay web-only until their shaders are written in Zig.
* **Counts.** 50 engine shaders plus 29 example-local shaders make up the 79 graphics modules.
* **Alignment.** `vkCreateShaderModule` needs 4-byte-aligned code, and `@embedFile` data has
  alignment 1. The legalization step copies into an owned `[]u32` anyway, which settles it.

### 1.6 mach's Vulkan backend (`src/sysgpu/vulkan.zig`, 3 706 lines)

* **It targets Vulkan 1.1 with the classic API.**
  * `VkRenderPass`es are cached by formats and ops, and a NEW `VkFramebuffer` is made on every
    `beginRenderPass`.
  * Barriers are sync1, with binary semaphores and a new fence per flush.
  * There is no pipeline cache, and no dynamic rendering, synchronization2 or timeline semaphores.
* **Its bindings come from vulkan-zig** (generated from `vk.xml`, two dependencies). It loads
  `vulkan-1.dll` with `std.DynLib`, which our Zig no longer has for Windows.
* **The upload trick is the right one, and we take it.**
  * `writeBuffer` memcpys into a mapped 64 MiB page and records a copy into a hidden encoder.
  * `Queue.submit` splices that encoder in FRONT of the user's command buffers.
  * So `submit(A); writeBuffer; submit(B)` executes as `[A, copy, B]`, which is WebGPU's ordering
    exactly.
* **The Y-flip is a negative viewport height** (`.y = height, .height = -height`), with no shader
  change and no front-face swap. That is consistent under Vulkan's area rule, and we take it too.
  Its `setViewport` (`y = extent.height - y`) is wrong for anything but full or centred viewports.
* **Synchronization is a 347-line per-encoder state tracker** built on "home layouts". It has real
  gaps:
  * render-pass attachments and render-pass bind groups are never tracked;
  * a storage-texture write followed by a read gets no memory barrier when the layout does not
    change.

  Correct fine-grained tracking is a project of its own. **Start with a barrier that cannot be
  wrong, and measure what it costs.**
* **Memory and descriptors.** It makes one `vkAllocateMemory` per resource, with no sub-allocation
  (its `gpu_allocator.zig` serves only D3D12). It makes one descriptor pool per bind group. Both
  work.
* **Swapchain bugs not to repeat:**
  * formats and present modes are never queried;
  * one render-finished semaphore is reused every frame;
  * images are transitioned before they are acquired;
  * `OUT_OF_DATE` handling **discards pending uploads**;
  * present support is never checked;
  * `SUBOPTIMAL` is ignored.
* **It passes raw SPIR-V to the driver verbatim.** Its own WGSL-to-SPIR-V generator gets struct
  offsets wrong. We are better placed: Zig computes the layout.
* **Its Windows default is D3D12.** Vulkan needs `-Dsysgpu_backend=vulkan`, so its
  Vulkan-on-Windows path is its least exercised one.

### 1.7 mach's Windows platform (`src/core/Windows.zig`, 746 lines)

* **Threading.**
  * One thread pumps messages, renders and presents. The app's logic runs on a second thread that
    the app itself starts.
  * Events cross in a mutex-guarded list.
  * There is no frame timer; pacing comes only from present.
* **Bindings.** 25 Win32 functions are called (22 user32 + 3 kernel32), from a hand-trimmed copy of
  zigwin32 output. About 40 declarations would cover a minimal layer in ~200 lines.
* **DPI.**
  * Awareness is set only by an embedded manifest (`PerMonitorV2`; Zig's `Compile.win32_manifest`).
  * Sizing uses `GetDpiForWindow` and `AdjustWindowRectExForDpi`.
  * `WM_DPICHANGED`'s suggested rectangle is **ignored**, and the initial size is not DPI-scaled.
* **Keys are identified by scancode** (plus the extended bit), through a 0x15D-entry table. That
  makes them physical keys, like DOM `code`. It filters AltGr's fake left-Ctrl by peeking the next
  message. It reads modifiers with `GetKeyState`.
* **Bugs not to repeat:**
  * `GWL_EXSTYLE` read where `GWL_STYLE` belongs, so window sizes are wrong;
  * X buttons decoded from the held-state bits instead of `HIWORD(wParam)`;
  * no `WM_MOUSEHWHEEL`, and no `SetCapture`;
  * mouse positions left in pixels;
  * `@enumFromInt` into an exhaustive virtual-key enum, which is UB on an unmapped key;
  * a second window panics; `WM_DESTROY` panics;
  * a minimized window creates a 0x0 swapchain;
  * nothing is drawn during a drag-resize (no `WM_ENTERSIZEMOVE` handling);
  * errors exit silently with code 0.
* **HWNDs are handles, not aligned pointers.** Its D3D12 code documents an `@alignCast` panic on
  one.
* **Estimate for a minimal correct layer:** 700-930 lines.
* **Mach pins Zig `0.16.0-dev.3142`**, which our compiler cannot build. We take its ideas, not its
  code.

### 1.8 What the study changed

* **Shaders.** The plan started from "Zig SPIR-V probably needs a legalization pass". The
  measurements split that in two:
  * **graphics needs almost none**;
  * **compute needs a real change**, and it belongs in kompute, not in a native rewriter.
* **Retirement.** It started from per-frame fences. mach showed how much bookkeeping hangs off
  frames, and how much of it was buggy. **A timeline semaphore that numbers every submit** makes
  retirement independent of frames, which a windowless compute run also needs.
* **Synchronization.** It started from "copy mach's barrier tracker". The tracker's own gaps argue
  for **one full barrier per pass boundary**, optimized later against numbers.
* **Gates.** It started from "only `wgpu.zig` is gated". The host study showed the gates are
  engine-wide (216 lines) and that `isWasm()` is used to mean three different things.
* **Input.** It started from "copy what the bridge sends". The bridge's numbering turned out to be
  wrong, so **native sends the engine's own numbering**, and the web gets its own fix.

---

## 2. Principles

* **P1 - Web first.**
  * Every engine feature lands on WebGPU first and is verified on a device; the Vulkan host follows.
  * A call the Vulkan host cannot do yet fails with a named assert
    (`"vulkan host: <call> not implemented"`), never with a silent wrong frame.
* **P2 - One engine.** Above the host layer, nothing branches on the platform except through three
  comptime facts:
  * `is_browser`
  * `has_gpu`
  * `has_window`
* **P3 - One SPIR-V.**
  * The `.spv` the build compiles is the `.spv` both platforms consume.
  * Native never sees WGSL, and the web never sees a native-only shader.
  * Where the SPIR-V is incomplete (kompute), it is fixed at the source for both.
* **P4 - Only the Zig compiler.**
  * No SDK, no generator and no C library at build time.
  * At run time: the GPU driver's Vulkan loader, plus the validation layer if one is installed.
* **P5 - Correct first, then measured.**
  * Keep big-hammer barriers, `GENERAL` layouts and one allocation per resource until a number says
    otherwise.
  * An optimization lands only with its before/after number, and with the validation layer silent.
* **P6 - An omission cannot compile.** A host that lacks one of the calls is a COMPILE error, via a
  comptime interface check, not a runtime surprise. This is the lesson of the 20 audio externs the
  smoke runner stubbed and the bridge never implemented.
* **P7 - The build says no.** The Vulkan SPIR-V rules zimr knows about run as a check over every
  module the build produces, in the Linux sandbox and without a GPU.
* **P8 - The door stays open.**
  * The Vulkan host knows nothing about Win32 except "give me a `VkSurfaceKHR`".
  * The window layer knows nothing about Vulkan except that one call.
* **P9 - The engine's numbers, not the browser's.** Native input arrives in the engine's own units
  (CSS pixels) and numbering (raylib keys and buttons).

---

## 3. Every option, per decision

The brainstorm, including what I expect to reject, with the verdict and why.

### 3.1 Where the native backend attaches

| option | verdict |
|---|---|
| **A. The raw host calls in `wgpu.zig` (u32 handles, blobs): a second bridge** | **CHOSEN.** The ABI is already specified and already implemented twice (bridge.zig, runner.mjs), and it carries everything. Blob decoding costs microseconds. Nothing above changes. |
| B. A typed seam (the backend receives `TextureDesc`, `RenderPipelineDescriptor`, ...) | Rejected. Callers encode blobs before calling `wgpu.zig`, examples included, so this means changing every pipeline and bind-group call site in the tree. |
| C. The `gpu_iface` trait (`WgpuBackend.beginFrame`, ...) | Rejected: too high. Pipeline creation, compute and materials call `wgpu.*` directly. |
| D. Link a native WebGPU (Dawn, wgpu-native) and pass SPIR-V through | Rejected. It is the most portable answer (Windows, Linux, macOS, Android, iOS at once) and the biggest third-party dependency the tree could take: C++ or Rust, the opposite of P4. Recorded because it is the honest alternative. |
| E. mach sysgpu as a dependency | Rejected. Pinned to an older Zig, WGSL-centred, and its Vulkan path is its least used. We take its ideas (1.6). |

### 3.2 Which graphics API

| option | verdict |
|---|---|
| **Vulkan** | **CHOSEN** (Simon's call, and the right one). Takes SPIR-V natively; runs on Windows, Linux and Android; runs on Apple through MoltenVK. |
| D3D12 | Rejected. Windows only, and needs DXIL, which means dxc or spirv-cross. |
| OpenGL 4.6 + `GL_ARB_gl_spirv` | Rejected. Not on macOS, uneven driver support, and it is the API zimr already deleted. |
| Metal | Later, for Apple only, and only if MoltenVK disappoints (section 7). |

### 3.3 How the shaders reach the driver

| option | verdict |
|---|---|
| **Embed the build's `.spv`; legalize at load time in the Vulkan host** (`DepthReplacing`, `NonWritable`, refuse `Linkage`) | **CHOSEN.** One artifact, two consumers. The fix-up is ~100 lines of word shuffling in a pure function the tests can run. |
| Legalize in a build step and embed a `.vk.spv` | Viable. Adds an artifact and a step per shader; worth it only if the fix-up grows. |
| Translate WGSL back to SPIR-V (naga/Tint) | Rejected by Simon, and absurd: the WGSL is made FROM this SPIR-V. |

### 3.4 Compute atomics, barriers and bindings

| option | verdict |
|---|---|
| **Fix kompute at the source.** GPU helpers emit inline-asm `OpAtomic*` and `std.spirv.workgroupBarrier()` (probe 5). Bindings are declared explicitly. spv2wgsl gains `OpAtomic*`/`OpControlBarrier` arms in place of its call-name intercept. | **CHOSEN.** One SPIR-V that means what it says on both platforms. It is exactly the "MIGRATION" kompute's comment (`src/kompute.zig:48-50`) anticipates. It changes the web path, so the web goes first and is verified on Adreno. |
| Rewrite the helper calls into atomics in the native legalizer | Rejected. The pointer arguments flow through `ptr<Function, ptr<StorageBuffer>>` variables. Undoing that is a data-flow pass, and it would leave the web and native consuming different programs. |
| Wait for Zig's SPIR-V backend to implement `@atomicRmw` | Rejected as a dependency. When Zig lands it, the inline asm becomes the builtin and nothing else changes. |

### 3.5 Vulkan version and the render-pass model

| option | verdict |
|---|---|
| **1.3 core: dynamic rendering + synchronization2 + timeline semaphores (+ maintenance5 where present)** | **CHOSEN.** Both GPUs here are 1.4. No `VkRenderPass`, no `VkFramebuffer`, no caches of either, and a WebGPU pass descriptor maps field for field onto `VkRenderingInfo`. MoltenVK and recent Android devices expose the same features. |
| 1.1 classic render passes (mach) | Rejected. Two object caches and their invalidation rules, to reproduce what dynamic rendering says in one struct. Only old Android needs it, and that can wait. |

### 3.6 Synchronization

| option | verdict |
|---|---|
| **Every image lives in `GENERAL`. One full memory barrier (`ALL_COMMANDS`, `MEMORY_WRITE` -> `MEMORY_READ \| MEMORY_WRITE`) before every pass, copy and dispatch. Layout transitions only for swapchain images.** | **CHOSEN.** It cannot be wrong for any hazard zimr can express. Khronos moved this way itself: `VK_KHR_unified_image_layouts` (2025) makes `GENERAL` the optimal layout on drivers that support it. The cost gets measured in S7. |
| A minimal tracker: per-texture `current_layout`, transitions at pass begin and end (the earlier plan's design) | The known fallback if S7 asks. The engine's offscreen-first frame ordering (every texture sampled in pass N was written in a pass that already ENDED) makes it correct without mach's generality. But it needs per-mip layouts for the bloom and mipmap chains, which render into mip i+1 while sampling mip i of the same image. `GENERAL` makes that case trivially legal. |
| Per-resource state tracking (mach's home layouts) | Rejected. Its generality is not needed (see the row above), and its gaps are the test list for anyone who tries. |

### 3.7 `writeBuffer` / `writeTexture`

| option | verdict |
|---|---|
| **Staging chunks + copies in an upload command buffer submitted ahead of the next submit** | **CHOSEN** (mach's trick, which is also Dawn's). It keeps the queue-timeline rule zimr depends on. |
| `vkCmdUpdateBuffer` for buffers (up to 64 KiB inline) + staging for textures | Rejected: two mechanisms where one suffices. |
| Host-visible buffers + memcpy | Rejected: wrong the moment a buffer is written between two submits, which `compute_host` does. |

### 3.8 Memory

| option | verdict |
|---|---|
| **One `vkAllocateMemory` per buffer/image, with a named assert at 80% of `maxMemoryAllocationCount`** | **CHOSEN** for v1 (mach does exactly this). |
| A block sub-allocator per memory type | Later, if the assert fires on the launcher or S7 measures the cost. |
| VMA | Rejected: a C++ dependency. |

### 3.9 Bindings

| option | verdict |
|---|---|
| **Hand-written `src/vk.zig`: only what is used (~95 functions), loaded through `vkGetInstanceProcAddr` from `vulkan-1.dll`** | **CHOSEN.** No SDK, no generator; every declaration is one the backend calls. |
| vulkan-zig, or a generator over `vk.xml` | Rejected: a dependency, or a new tool, for ~95 functions. |

### 3.10 Windows windowing

| option | verdict |
|---|---|
| **Hand-written Win32 layer, single thread** (pump inside the frame loop) | **CHOSEN.** About 30 `user32`/`kernel32` functions. |
| GLFW / SDL | Rejected: C dependencies. |
| A separate window thread, so drag-resize does not freeze the frame | Later, and only if the simpler `WM_ENTERSIZEMOVE` + timer (S8) is not enough. |

### 3.11 Who owns the loop

| option | verdict |
|---|---|
| **`App.run` owns it natively** (opens the window, loops, returns on close) | **CHOSEN.** Zero changes to the runners or the 17 own-`main` examples. |
| A separate native `main` that imports the app and drives `update` | Rejected. The own-`main` examples are their own exe root, so this needs a second root per app shape. |

### 3.12 The `isWasm()` gates

| option | verdict |
|---|---|
| **Three comptime facts (`is_browser`, `has_gpu`, `has_window`) in one leaf file; each of the 216 gate lines rewritten to the fact it means** | **CHOSEN.** A gate then says what it tests, and `text2d` loads fonts natively again. The 7 in `zimrmath.zig` are target-architecture (SIMD) choices and stay. |
| Keep `isWasm()` and add `or native_gpu` where needed | Rejected. It keeps the conflation, and every future gate has to rediscover it. |

### 3.13 Frames in flight

| option | verdict |
|---|---|
| **2, throttled on the timeline semaphore at acquire** | **CHOSEN**, as a comptime constant (1 for debugging). Because retirement is keyed to submit numbers, the only per-frame state is the acquire semaphore. |

### 3.14 Testing without a human looking

| option | verdict |
|---|---|
| **An offscreen "surface": the host renders into an RGBA8 image instead of a swapchain, and can read it back** | **CHOSEN.** It gives a native smoke run, pixel comparisons against the software rasterizer and Chrome, and a windowless mode for compute. |
| `VK_EXT_headless_surface` | Rejected: Mesa only. |
| Mesa lavapipe (CPU Vulkan) in the Linux sandbox | A door, not a choice. It would let the sandbox RUN the native build and check its pixels without a GPU (section 7). |

---

## 4. The layers

```
examples + engine (unchanged above wgpu.zig: WgpuGl, Renderer2D, draw3d, ui, compute_host, ...)
        |
src/host.zig          three comptime facts: is_browser, has_gpu, has_window (+ which host)
        |
src/wgpu.zig          typed wrappers + handle census; ONE comptime host switch
        +-- web      extern "wgpu" js_*  ->  src/bridge.zig (Zig -> C -> JS)  ->  WebGPU
        +-- vulkan   src/wgpu_vulkan.zig (the same calls)  ->  src/vk.zig  ->  vulkan-1.dll
        +-- none     today's stubs, in one place (host tests, test-fast)
src/web.zig           the same switch per namespace (dom, audio, jobs, ws, rtc, userfile)
        +-- web      extern "dom" ...  ->  bridge.zig
        +-- native   src/native_services.zig (log, time, persistence, cursor, clipboard, crypto; stubs)
        +-- none     today's defaults

App.run (wgpu_app.zig)
        +-- web      set up, register update, RETURN (the browser drives update + input_push_*)
        +-- native   src/native_loop.zig: open window, set up, LOOP { pump -> input_push_*; update }
                              |
                     src/win32.zig (window, DPI, messages; hand-declared user32/kernel32)
```

---

## 5. The design

### 5.1 The host facts and switches

* **`src/host.zig`** (new leaf, imports only `builtin` and `build_options`) declares the facts:
  ```zig
  pub const Kind = enum { web, native, none };
  pub const kind: Kind = build_options.host;   // web on wasm; native for -windows apps; none for tests
  pub const is_browser = kind == .web;
  pub const has_gpu = kind != .none;
  pub const has_window = kind != .none;        // offscreen native still "has" the window API
  ```
  The option lives in the `build_options` module that the zimr module already imports
  (`memwatch.zig`, `profiler.zig`). The default is `web` on wasm and `none` elsewhere, so every
  existing host test and `test-fast` root is unchanged.
* **`wgpu.zig` selects its host once:**
  ```zig
  const gpu_host = switch (host.kind) {
      .web => web_host,                              // the existing extern decls, under neutral names
      .native => @import("wgpu_vulkan.zig"),
      .none => null_host,                            // today's stubs, verbatim, in one place
  };
  ```
  * Every wrapper calls `gpu_host.<call>(...)`, and the sixty `if (comptime !is_wasm)` lines
    disappear into `null_host`.
  * The neutral names (`create_buffer`, `queue_write_buffer`, ...) are aliases of the `js_*`
    externs on the web side. So bridge.zig and the import names stay exactly as they are.
* **A comptime interface check** asserts that `wgpu_vulkan` declares every call `web_host` declares,
  with the same parameter and return types (calling convention aside). A missing call fails the
  native build with its name (P6).
* **`web.zig`'s namespaces get the same treatment:** `dom`, `audio`, `jobs`, `ws`, `rtc`, `userfile`,
  `fetch`. `src/native_services.zig` supplies real natives where cheap (section 5.7) and today's
  defaults elsewhere. Gating all 69 `dom` wrappers removes the "callers must gate" rule entirely.
* **The gate reclassification.** Each of the 216 `isWasm()` lines is rewritten to the fact it
  means, file by file:
  * `wgpu.zig` 61 and `web.zig` 67 become the switches.
  * `runtime.zig` 37, `ui.zig` 20, `sound.zig` 13, `text2d.zig` 6, `wgpu_app.zig` 2, `memwatch.zig` 2
    (`@wasmMemorySize` stays browser-only) and `draw3d.zig` 1 are rewritten one by one.
  * `zimrmath.zig` 7 (SIMD) stay.
  * **Proof:** the web build's WGSL and JS are byte-identical before and after, and the host tests
    pass unchanged.
* **The Vulkan host is a leaf.** It imports `std`, `vk.zig`, a surface callback from the
  window layer, and **`src/gpu_abi.zig`**. It never imports `wgpu.zig` or `gpu.zig`: that would
  close an import cycle, and the `import-cycle` lint forbids it.
* **`gpu_abi.zig`** is new and std-only. It holds what both sides of the ABI must agree on: the enum
  numbering, the usage-flag layouts, and the blob formats with a Zig decoder.
  * `wgpu.zig` re-exports the enums, so the public API is unchanged.
  * `gpu.zig` keeps encoding.
  * A round-trip test pins the encoder against the decoder, including the real 5-u32
    bind-group-layout entry.
  * bridge.zig keeps its own reader, because it reads the wasm's memory through a JS DataView.
* **The one module global.** The browser keeps its device and tables in bridge-side globals. The
  Vulkan host needs the same, since its calls take a u32 and nothing else. It is ONE
  `var host: ?*Host` in `wgpu_vulkan.zig`, with a `lint:off module-var` saying why: the same category
  as `active_app` and the handle census. (Decision D5.)

### 5.2 The native loop (`App.run` on native)

```
App.run(cfg, State, init_fn, update_fn):
    allocators: SafeAllocator (debug) / smp_allocator (release), wrapped in the same two counters
    window = win32.open(cfg.window)           // title, logical size x DPI scale, shown
    device = wgpu.initDevice()                // Vulkan host: instance, device, surface from the window
    ... today's setup, unchanged (caches, GpuFrame, gl, init_fn) ...
    loop:
        win32.pump(&app)                      // PeekMessage until empty; each message becomes the
                                              //   SAME input call the export makes
        if (window.closed) break
        if (window.minimized) { Sleep(16); continue }   // like a hidden tab: no frames
        update(dt)                            // the SAME function the browser calls
    the runnerDeinit + runnerShutdown sequence   // the census must read zero
    host shutdown: vkDeviceWaitIdle, destroy all, report anything the layer still sees alive
```

* The `export fn update` and `input_push_*` stay exactly as they are. Natively they are called
  directly (an `export` in a Windows exe is harmless).
* FIFO present blocks at the display rate, the way `requestAnimationFrame` does.

### 5.3 The Vulkan host: device, surface, submits

#### 5.3.1 Loader and bindings (`src/vk.zig`)

* **Loading.**
  * **The window layer finds the loader.** `win32.zig` does `LoadLibraryW(L"vulkan-1.dll")` +
    `GetProcAddress("vkGetInstanceProcAddr")` and hands the one function pointer to the host.
  * Instance and device dispatch tables are then filled by name through it. They are fields of the
    host struct, not globals.
  * **`vk.zig` never names an OS.** On Linux the loader is `std.DynLib.open("libvulkan.so.1")`;
    `std.DynLib` works there even without libc (`ElfDynLib`), though it has no Windows arm in this
    Zig. So a second platform changes only the window layer.
* **Types** are declared by hand, for exactly the calls used (list in 5.9).
* **Errors.** A failing `VkResult` becomes a Zig error at the call site, and the call site names
  what it was doing.

#### 5.3.2 Instance, device, queue

* **Instance.** API version 1.3, with `VK_KHR_surface` and the platform surface extension
  (`VK_KHR_win32_surface`). `VK_EXT_debug_utils` is added when the validation layer is present.
* **Validation.**
  * `VK_LAYER_KHRONOS_validation` is ON by default in `-Dmode=debug` and `release` when the layer
    is installed. That mirrors the web, where Dawn always validates.
  * `ZIMR_VK_VALIDATE=0` turns it off, for S7's timing runs; `=1` forces it on in `ship`, for
    diagnosing a shipped build. (The earlier plan made it opt-in only, which risks forgetting it.)
  * A debug-utils messenger sends messages to `std.log`. Errors become a zimr assert, which in
    `release` keeps running, like zimr's other asserts.
* **Object names.** Every zimr label (`"kompute_params"`, `"gpu_frame_depth"`, ...) goes on the
  Vulkan object via `vkSetDebugUtilsObjectNameEXT`. So a validation message names the zimr object,
  the way Dawn's messages do on the web.
* **Device choice.**
  * Discrete, then integrated, then anything else.
  * `ZIMR_GPU=<index or name substring>` overrides it.
  * The choice is logged, and `adapterInfo` returns it (`"vulkan: NVIDIA GeForce RTX 5060 Laptop
    GPU (596.13)"`).
* **Features are enabled explicitly.** (mach checked features it never enabled.)
  * `dynamicRendering`, `synchronization2` and `timelineSemaphore`: required.
  * `robustBufferAccess`: WebGPU bounds-checks every buffer access, so this keeps the two
    platforms' out-of-bounds behaviour alike.
  * `maintenance5` when present: `PointSize` defaults to 1.0. Without it, the legalizer writes the
    size.
* **One queue**, from a family with graphics + compute AND present support for the surface.

#### 5.3.3 Handles

* There is one pool per `HandleKind`, plus pools for encoders, passes, command buffers and buffer
  reads.
* Each pool is a slice of slots with a free list. A handle is the slot index + 1.
* A slot holds the Vulkan object and the few facts later calls need: a texture's format, extent and
  samples; a buffer's size and memory; a pipeline's layout.
* A generation byte turns a stale handle into a named assert in debug builds.

#### 5.3.4 The surface: swapchain or offscreen

* **The swapchain.** `getSurface` returns the one surface; with a window it is a swapchain:
  * format `R8G8B8A8_UNORM`, checked against the surface's list (without it, S8's present blit);
  * sRGB-nonlinear color space, FIFO, `minImageCount + 1` images;
  * extent from `currentExtent`; opaque alpha.
* **Sizes and format.**
  * `getSurfaceSize` is the swapchain extent.
  * `getSurfaceCssSize` is the client size divided by the DPI scale (`GetDpiForWindow / 96`), which
    is the browser's CSS pixels.
  * `getSurfaceFormat` is `.rgba8_unorm`.
* **Stable view handles.** Each swapchain image's view gets its handle once, at first creation.
  * Recreation refreshes those slots IN PLACE: same handles, new backing (the earlier plan's design,
    mirroring how the bridge reconfigures the canvas invisibly).
  * Slots are added only if the image count grows.
  * So "the current texture view" is one of N stable handles, not one new handle per frame as in
    the bridge today.
* **Offscreen mode** serves the headless smoke run and windowless compute.
  * The "swapchain" is one RGBA8 image of a requested size.
  * Acquire returns its view, and present only closes the frame.
  * A host-internal readback copies the image out for pixel checks.
* **Recreation.**
  * It happens on `OUT_OF_DATE`, `SUBOPTIMAL`, or a size change seen at acquire time (a dirty flag
    set by `WM_SIZE`).
  * It waits for the device first, passes the old swapchain as `oldSwapchain` (mach's handoff), and
    does NOT discard pending uploads (mach's bug).
* A zero-size (minimized) window renders nothing.

#### 5.3.5 Submits, the timeline, frames

**One timeline semaphore numbers every `vkQueueSubmit2`.** Anything that must outlive the GPU's use
of it carries the number of the last submit that may use it, and is released when the semaphore's
counter reaches that number. This one mechanism retires staging memory, deferred destroys and
readbacks, with or without a window.

```
host state:  submitted: u64, completed: u64 (polled), open_encoders: u32,
             uploads: ?VkCommandBuffer (lazily begun), pending_destroys, retire list,
             acquired: ?image, acquire_waited: bool,
             acquire_sem[frames_in_flight], present_sem[per swapchain image],
             present_serial[frames_in_flight]

createCommandEncoder:  open_encoders += 1; allocate + begin a command buffer

queueSubmit(cmd):
    batch = [uploads if any (ended with a full barrier)] ++ [cmd]
    waits = acquired and not acquire_waited ? [acquire_sem @ ALL_COMMANDS] : []
    vkQueueSubmit2(batch, waits, signal timeline = ++submitted)
    open_encoders -= 1
    the staging chunks and command buffers used here retire at `submitted`
    if open_encoders == 0: pending_destroys retire at `submitted`

getCurrentTextureView:
    wait timeline >= present_serial[frame]            // at most N frames ahead
    retire everything with serial <= completed
    (re)create the swapchain if dirty
    vkAcquireNextImageKHR(signal acquire_sem[frame])
    record UNDEFINED -> GENERAL for that image into `uploads`
    return that image's stable view handle

surfacePresent:
    a small command buffer: GENERAL -> PRESENT_SRC_KHR
    vkQueueSubmit2([uploads?, it], wait acquire if not yet waited,
                   signal present_sem[image] + timeline = ++submitted)
    vkQueuePresentKHR(wait present_sem[image])
    present_serial[frame] = submitted;  frame = (frame + 1) % N
```

**Why `open_encoders`.** WebGPU lets a bind group or pipeline be released while a recorded but
unsubmitted command buffer still uses it; the JS object simply lives on. Deferring destroys until no
encoder that could still reference them is open keeps that meaning without tracking references.

**Why `present_sem` is per image.** Reusing one render-finished semaphore every frame (mach) races
with a present that has not yet consumed its wait.

#### 5.3.6 Uploads

* **The write calls.** `queueWriteBuffer` and `queueWriteTexture` (plus `Level` and `Region`) copy
  the caller's bytes into a staging chunk: 4 MiB, persistently mapped, host-visible + coherent. A
  larger upload gets its own chunk, sized to fit.
* **The copies.** Each write records `vkCmdCopyBuffer` or `vkCmdCopyBufferToImage` into `uploads`.
  Texture rows use `bufferRowLength = bytes_per_row / texel size`, and the mip level and region
  come from the call.
* **Ordering.** The copies run ahead of the next submit. So a write lands after everything submitted
  before it and before everything submitted after it. `compute_host`'s recordings and the
  renderer's per-frame rings rely on exactly that.

#### 5.3.7 Barriers and layouts

* **New images** are transitioned `UNDEFINED -> GENERAL` once, in `uploads`.
* **Before every render pass, compute pass, dispatch and copy**, one `vkCmdPipelineBarrier2` with a
  single `VkMemoryBarrier2`: `ALL_COMMANDS/MEMORY_WRITE -> ALL_COMMANDS/MEMORY_READ|MEMORY_WRITE`.
  * Descriptor, attachment and copy layouts are all `GENERAL`.
  * WebGPU makes each dispatch's writes visible to the next dispatch in the same pass, and the
    barrier before every dispatch gives exactly that.
* **Swapchain images** are the only other transitions (5.3.5).

### 5.4 The Vulkan host: resources, passes, pipelines

#### 5.4.1 Render passes

`beginRenderPass` / `beginRenderPassMrt` map onto `vkCmdBeginRendering`:

* **Color attachments.** The view(s) in `GENERAL`. `loadOp` is CLEAR (with the pass's color) or
  LOAD, and `storeOp` is STORE or DONT_CARE. MSAA resolves with `resolveMode = AVERAGE` into the
  resolve view.
* **Depth.** CLEAR to 1.0 and STORE, exactly as the bridge does.
* **Render area and viewport** come from the first attachment. The **viewport is
  `{ x 0, y H, w W, h -H, depth 0..1 }`**: WebGPU's Y-up NDC, mach's flip. The scissor starts full,
  and `setScissorRect` maps to `vkCmdSetScissor` with the same top-left origin.
* **Inside a pass.**
  * `setPipeline` binds the pipeline and marks every bind-group slot dirty.
  * `setBindGroup` records the set.
  * **`vkCmdBindDescriptorSets` runs at draw time, against the bound pipeline's layout.** mach bound
    immediately and required `setPipeline` first.
  * Vertex and index buffers bind directly, and draws are direct.

#### 5.4.2 Bind groups

* **Layouts.** A bind-group layout blob becomes a `VkDescriptorSetLayout`:
  * uniform -> `UNIFORM_BUFFER`;
  * storage (read-only or read-write) -> `STORAGE_BUFFER`;
  * sampler -> `SAMPLER`;
  * texture -> `SAMPLED_IMAGE`;
  * storage texture -> `STORAGE_IMAGE`.

  Stage flags come from the visibility. An empty layout becomes a 0-binding set layout, which is what
  the engine's `empty_bgl` placeholders need.
* **Bind groups.** A bind group becomes one set from a shared pool (`FREE_DESCRIPTOR_SET_BIT`, with
  a new pool page when one fills). The set is written once with `vkUpdateDescriptorSets`, since
  WebGPU bind groups are immutable. A buffer size of 0 means `VK_WHOLE_SIZE`.
* **Pipeline layouts.** `VkPipelineLayout` over the set layouts, with no push constants.
  * zimr's groups are 0, 1 and 2 (`shader_interface.uniformGroupForSchema`, plus pins such as
    `decal_fs`'s).
  * Every Vulkan device binds at least 4 sets (`maxBoundDescriptorSets`), so the WebGPU group
    number IS the Vulkan set number, with no remapping.
  * An assert at device creation checks that the limit really is at least 4.

#### 5.4.3 Pipelines

* **Render pipelines** take everything from the blob:
  * vertex input (binding = slot), topology, cull mode, front face CCW, `rasterizationSamples`;
  * depth test/compare/write from the depth mode;
  * blend on target 0, and none on the MRT extras;
  * color and depth formats through `VkPipelineRenderingCreateInfo`;
  * dynamic viewport and scissor;
  * the entry name from the blob (`"entry"` for generated shaders).
* **Constants.** The blob's `constants` (WGSL `override`s) must be empty on Vulkan, and a non-empty
  list asserts. No Zig shader has specialization constants; only the hand-written WGSL
  `pipeline_constants` example uses overrides.
* **Compute pipelines** are one stage with the kernel's entry name.
* **No pipeline cache in v1.** A `VkPipelineCache` saved to disk is an S7 measurement.

#### 5.4.4 Copies and readback

* **Copies.** `copyBufferToBuffer` maps to `vkCmdCopyBuffer`, and `copyTextureToBuffer` to
  `vkCmdCopyImageToBuffer`. WebGPU's 256-byte row pitch becomes the `bufferRowLength`.
* **Map-read memory.** A buffer created with `map_read` lives in host-visible, host-cached memory
  that stays mapped.
* **The three read calls.**
  * `bufferReadStart` records the last submitted number.
  * `bufferReadPoll` returns `completed >= that`.
  * `bufferReadInto` copies from the mapping, invalidating first if the memory is not coherent.
* This is the same "latest completed snapshot" the web gives, usually one frame old.

#### 5.4.5 Deferred destroys

* Every `destroy*` moves its Vulkan object(s) onto `pending_destroys`, and they retire as in 5.3.5.
* The handle slot is freed immediately, so the census does not wait for the GPU.
* At shutdown the host waits for the device and drains everything. If the validation layer is
  present, its object tracker then reports anything still alive: a second, independent leak census.

#### 5.4.6 Errors

* Every failing `VkResult` is a named assert with the call and the zimr label.
* `DEVICE_LOST` logs the adapter and the last submit number, then exits.
* Out-of-memory names the resource and its size.

#### 5.4.7 Mapping tables

| zimr | Vulkan |
|---|---|
| `rgba8_unorm` / `_srgb` | `R8G8B8A8_UNORM` / `_SRGB` |
| `bgra8_unorm` / `_srgb` | `B8G8R8A8_UNORM` / `_SRGB` |
| `rgba16_float`, `rgba32_float` | `R16G16B16A16_SFLOAT`, `R32G32B32A32_SFLOAT` |
| `r8_unorm`, `rg8_unorm` | `R8_UNORM`, `R8G8_UNORM` |
| `depth16_unorm` | `D16_UNORM` |
| `depth24_plus` | `D32_SFLOAT` (what Dawn and mach choose; AMD has no `D24` depth attachment) |
| `depth32_float` | `D32_SFLOAT` |
| vertex `float32 .. float32x4` | `R32_SFLOAT .. R32G32B32A32_SFLOAT` |
| vertex `uint32`, `uint32x2` | `R32_UINT`, `R32G32_UINT` |
| vertex `uint8x4`, `uint8x4_unorm` | `R8G8B8A8_UINT`, `R8G8B8A8_UNORM` |
| topology | `POINT_LIST`, `LINE_LIST`, `LINE_STRIP`, `TRIANGLE_LIST`, `TRIANGLE_STRIP` |
| cull `none/front/back` | `NONE/FRONT_BIT/BACK_BIT`; front face `COUNTER_CLOCKWISE` |
| depth `none` | test off (or `ALWAYS`, no write, when an attachment exists) |
| depth `less`, `less_equal`, `greater`, `greater_equal`, `equal`, `always` | the same compare op, write on |
| depth `less_no_write`, `less_equal_no_write` | `LESS` / `LESS_OR_EQUAL`, write off |
| sampler filter / mip filter | `NEAREST`/`LINEAR`, `MIPMAP_MODE_NEAREST`/`LINEAR`, `maxLod` unclamped |
| address `clamp_to_edge/repeat/mirror_repeat` | `CLAMP_TO_EDGE/REPEAT/MIRRORED_REPEAT` on u, v, w |

Blend, from `bridge.zig:2405-2440` (op ADD throughout):

| mode | color src, dst | alpha src, dst |
|---|---|---|
| 0 none | blending off | - |
| 1 alpha | `SRC_ALPHA`, `ONE_MINUS_SRC_ALPHA` | `ONE`, `ONE_MINUS_SRC_ALPHA` |
| 2 additive | `SRC_ALPHA`, `ONE` | `ONE`, `ONE` |
| 3 multiply | `DST_COLOR`, `ZERO` | `DST_ALPHA`, `ZERO` |
| 4 premultiplied | `ONE`, `ONE_MINUS_SRC_ALPHA` | `ONE`, `ONE_MINUS_SRC_ALPHA` |

### 5.5 SPIR-V on Vulkan

* **Delivery.**
  * `ShaderOutput` gains `spv: LazyPath`, the Run output that already exists.
  * The embedded artifact gets a backend-neutral import name, `"<name>.shader"` for graphics and
    `"<entry>_shader"` for compute: WGSL on web builds, SPIR-V on native builds (D4, decided).
  * `wgpu.createShaderModule(device, code, label)` becomes the one call; each host knows what its
    bytes are.
  * `createShaderModuleWgsl` remains as the explicit raw-WGSL API. The Vulkan host refuses it by
    name: "hand-written WGSL is web-only; write the shader in Zig". That covers the 8 WGSL examples.
* **Compute on native.** A kompute module is ONE `.spv` holding all its entries. Each per-entry
  import name resolves to that module's bytes, and the host creates one `VkShaderModule` per module
  (deduplicated by pointer) and one pipeline per entry.
* **`src/spv_vulkan.zig`** is std-only and pure.
  * **`legalize(gpa, words) ![]u32`** returns an owned, aligned copy with the gaps closed:
    * inserts `OpExecutionMode %entry DepthReplacing` for each fragment entry whose interface writes
      `FragDepth`;
    * decorates `NonWritable` on StorageBuffer variables that only vertex entries reference;
    * without maintenance5, adds and writes a `PointSize` output (the fallback);
    * refuses `Capability Linkage`, naming the module.
  * **`reflect(words, entry) Reflection`** returns the entry point's interface: each global's name,
    storage class, set and binding. This replaces `compute_host`'s WGSL scans on native.
    * The used fields ARE the entry point's interface list (SPIR-V >= 1.4 lists exactly the globals
      each entry uses).
    * The binding numbers are the decorations.
  * **`check(words) []Violation`** is section 1.4 as code:
    * every resource decorated and every interface variable located;
    * blocks explicitly laid out;
    * only allowed capabilities;
    * merge instructions where required;
    * no storage-buffer pointers into functions, no forbidden storage classes or pointer ops;
    * no uses of the kompute helper names.
* **A gate over the corpus.** A test walks every `.spv` the build produced and runs `check` - in the
  Linux sandbox, with no GPU. It is the native twin of spv2wgsl's build-time refusals.
* **kompute, fixed at the source** (Decision D3, web first):
  * **Explicit bindings.** `Globals.bind` and `g.uniform()` emit
    `.decoration = .{ .descriptor = .{ .set = 0, .binding = N } }`, with the Params uniform at 0 and
    the `Buffers` fields at 1..N in declaration order.
    * spv2wgsl already honours explicit decorations.
    * `compute_host` takes the numbers from comptime instead of parsing text. The WGSL scan stays
      only as a cross-check.
  * **Real atomics.** The GPU branches of `atomicAdd/Load/Store` become `inline fn`s wrapping
    `OpAtomicIAdd` / `OpAtomicLoad` / `OpAtomicStore`, with Device scope and relaxed semantics
    (WebGPU's atomics are relaxed). The `noinline` dummy helpers are deleted.
  * **Real barriers.** `zworkgroupBarrier` becomes `std.spirv.workgroupBarrier()`, i.e.
    `OpControlBarrier(Workgroup, Workgroup, AcquireRelease | WorkgroupMemory)`: the WGSL
    `workgroupBarrier()`.
  * **spv2wgsl** gets `OpAtomic*` and `OpControlBarrier` arms. The "binding is atomic" marking moves
    from the helper's call name to the pointer root of an `OpAtomic*`. The emitted WGSL stays the
    same shape: `array<atomic<u32>>` on the tainted binding, `atomicAdd(&x[i], v)`,
    `workgroupBarrier()`.
  * **Proof.**
    * The WGSL diff before/after is limited to binding numbers.
    * `fluid_gpu`, `fluid_sort` and the zimrnum sweep pass on Simon's phone (Adreno) before native
      builds on this.
    * The CPU twins are untouched: the CPU branch of each helper is unchanged.

### 5.6 The Win32 layer (`src/win32.zig`)

* **Process.**
  * Console subsystem in debug and release, so logs and panics print to the terminal. Windows
    subsystem in `ship`.
  * DPI awareness from BOTH an embedded manifest (`Compile.win32_manifest`, `PerMonitorV2` + UTF-8
    code page) and `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)` at startup.
* **Window.**
  * Register the class once.
  * Create with `WS_OVERLAPPEDWINDOW`. The client size is `cfg.window.width x height` logical
    pixels times the DPI scale, via `AdjustWindowRectExForDpi` with **`GWL_STYLE`** (mach used the
    EX style).
  * The title comes from `cfg.window.title`, converted UTF-8 -> UTF-16.
  * Per-window state lives behind `GWLP_USERDATA`, set in `WM_NCCREATE`. That means no globals and
    no "init complete" gate that drops early messages.
  * `WM_DPICHANGED` applies the suggested rectangle.
* **Messages, translated to the browser's calls in the engine's units:** CSS pixels (client pixels
  / DPI scale), raylib key and button numbering.

| Win32 | zimr |
|---|---|
| `WM_MOUSEMOVE` | `input_push_mouse_move(x, y)` |
| `WM_[LRM]BUTTONDOWN/UP` | mouse move FIRST, then `input_push_mouse_button_down/up`: left 0, right 1, middle 2; `SetCapture` on down, `ReleaseCapture` on the last up |
| `WM_XBUTTONDOWN/UP` | `HIWORD(wParam)`: XBUTTON1 -> `side` (3), XBUTTON2 -> `extra` (4) |
| `WM_MOUSEWHEEL`, `WM_MOUSEHWHEEL` | `input_push_mouse_wheel(dx, dy)`, delta / 120: "notches, up positive" as the engine expects |
| `WM_KEYDOWN/UP`, `WM_SYSKEYDOWN/UP` | `input_push_key_down(key, repeat)` / `_up`; key from the SCANCODE + extended bit through one table to `KeyboardKey` (layout-independent, like DOM `code`); AltGr's fake left-Ctrl filtered; PrintScreen synthesized (Windows only sends its up); `MapVirtualKeyW` fallback for scancode 0; VK codes compared as integers, never `@enumFromInt` |
| `WM_CHAR` | `input_push_char(codepoint)`: UTF-16 surrogates joined; control characters dropped (keys carry them) |
| `WM_SIZE` (incl. `SIZE_MINIMIZED`), `WM_DPICHANGED` | swapchain dirty flag; minimized skips frames; CSS size re-read next frame |
| `WM_KILLFOCUS` | release every held key and button (a key released while unfocused would otherwise stick) |
| `WM_CLOSE` | leave the loop; `DestroyWindow` after teardown |
| `WM_POINTER*` (touch) | `zimr_input_push_touch_*`, in S8 |

* **Hand-declared functions:**
  * `kernel32`: `GetModuleHandleW`, `LoadLibraryW`, `GetProcAddress`, `QueryPerformanceCounter` and
    `QueryPerformanceFrequency`, `Sleep`, `GetLastError`.
  * `user32`: about 25, covering class, window, message, DPI, cursor, capture, key state, and
    long-pointer.
  * They link from Zig's bundled MinGW import libraries (`x86_64-windows-gnu`), so no Windows SDK
    is needed either.
  * HWNDs are opaque and never `@alignCast`.
* **Errors surface.** A failed Win32 call is a named error that reaches the terminal, never a silent
  exit 0.

### 5.7 The rest of the host (`src/native_services.zig`)

| service | apps | web today | native v1 | later |
|---|---|---|---|---|
| frame clock `nowMs` | all | `performance.now()` | `QueryPerformanceCounter` (`runtime.zig:60-81` already has a Windows `hostMonotonicMs`) | - |
| log | 309 | on-page console via `js_log` | stderr (the existing host path in `web.zig`) | also `OutputDebugStringW` |
| panic | - | `__wzFail` page | Zig's own panic, with a real stack trace | - |
| RNG seed `crypto_random_fill` | 314 | `crypto.getRandomValues` | `ProcessPrng` (`bcryptprimitives.dll`, what `std.Io.Threaded` uses; this std has no `std.crypto.random`) | - |
| persistence (`size/read`, `save`, `remove`) | 144 (UI window state) | localStorage | files under `%LOCALAPPDATA%\zimr\<app>\` | - |
| wall clock `epoch_ms`, `tz_offset_min` | 3 / 2 | `Date` | `GetSystemTimePreciseAsFileTime`, `GetTimeZoneInformation` | - |
| cursor style / shape | 6 | CSS cursor | `SetCursor` / `ShowCursor` | - |
| pointer lock | 2 | Pointer Lock API | stub (unlocked) | `ClipCursor` + raw input |
| clipboard write | 2 | Clipboard API | stub | `OpenClipboard` / `SetClipboardData` |
| text-entry overlays | 11 / 4 | DOM `<input>` / `<textarea>` | none: `ui.zig`'s native path reads the char queue | - |
| file drop / picker / save | 3 | DOM | stub (`pending_count` 0) | `WM_DROPFILES`, `IFileOpenDialog` |
| jobs | 18 | Web Workers | **inline** (the existing no-worker fallback in `jobs.zig:620-623`) | a thread pool calling the kernels directly |
| audio | 7 | WebAudio | silent (`create_context` 0 disables it, `sound.zig:1167-1172`) | WASAPI + a mixer + an OGG decoder (the engine has none) |
| WebSocket / WebRTC | 3 / 2 | browser | inert | WinHTTP WebSocket; WebRTC only with a heavy dependency |
| GPU timing `gpuMs` | all | timestamp-query | 0 | timestamp queries |
| open URL | 2 | `window.open` | stub | `ShellExecuteW` |

### 5.8 Build

* **The native steps.** `zig build <kebab-name>-windows` for every example uses the same app-module
  wiring as the wasm exe, with:
  * target `x86_64-windows-gnu`;
  * `build_options.host = .native`;
  * the shader artifacts switched to `.spv` (5.5), with no spv2wgsl run, so native builds skip the
    translator entirely;
  * output `zig-out/windows/<name>.exe`.

  The steps are named for the target OS, not "native": in the Linux sandbox, "native" would mean
  Linux. Linux gets `<kebab-name>-linux` beside them later. `-Dmode` means what it means today.
* **The exe's switches**, used by Simon and the harness alike:
  * `--offscreen=WxH` renders without a window;
  * `--frames=N` exits after N frames;
  * `--screenshot=out.png` reads back the last frame;
  * `--gpu=<index or name>` is the same as `ZIMR_GPU`.
* **Cross-compiling.** Zig ships the MinGW import libraries, so the Linux sandbox can BUILD every
  Windows exe even though it cannot run one.
* **The native build must not rot under web-first work.** Every engine change lands on the web
  first, so nothing would notice a broken native build until someone opened Windows.
  * From S2 on, `zig build check` also cross-compiles ONE Windows exe (`hello-world-windows`),
    compile-only, which works in the sandbox.
  * The full `-windows` roster compiles at arc close, beside the full test run.
* **`zig build windows-smoke -Dfocus=<example>`** (S6) runs the exe with `--offscreen --frames=N`
  under the validation layer. It needs a GPU, so it runs on Windows. It fails on:
  * any validation message;
  * a census that does not return to zero;
  * a pixel difference over tolerance.
* **`test-windows`** already cross-compiles the host tests for Windows, and keeps doing so with
  `host = .none`.
* **`zig build vk-abi-check`** is dev-only, and runs only when `VULKAN_SDK` is set.
  * It runs `zig translate-c` on the SDK's `vulkan_core.h` (installed per D6).
  * It compares `@sizeOf`/`@offsetOf` for every struct and the value of every constant hand-declared
    in `vk.zig`.
  * A hand-declared ABI struct that is wrong does not fail loudly; it returns plausible garbage (the
    `fs_space.zig` lesson in `claude.md`). This check makes the compiler the oracle, without ever
    making the header a build dependency.

### 5.9 Files and sizes

| file | what | lines (est.) |
|---|---|---|
| `src/host.zig` | the three facts + the host kind | 40 |
| `src/gpu_abi.zig` | shared enums, flags, blob layouts + Zig decoder + round-trip test | 400 |
| `src/vk.zig` | hand-declared Vulkan (~60 structs, ~40 enums/flags, ~95 function pointers) + dispatch tables; platform-neutral | 1 500-2 000 |
| `src/wgpu_vulkan.zig` | the host (breakdown below) | 2 600 |
| `src/spv_vulkan.zig` | legalize, reflect, check + tests | 550 |
| `src/win32.zig` | hand-declared user32/kernel32, window, DPI, message translation, scancode table | 800 |
| `src/native_services.zig` | dom/audio/jobs/net natives and stubs | 300 |
| `src/native_loop.zig` | the loop of 5.2 | 150 |
| `src/wgpu.zig`, `src/web.zig` | the switches; ~130 gates removed | -150 net |
| `runtime.zig`, `ui.zig`, `sound.zig`, `text2d.zig`, `wgpu_app.zig`, ... | gate reclassification; `App.run` native branch | 150 |
| `src/kompute.zig`, `src/compute_host.zig`, `src/spv2wgsl.zig` | explicit bindings; real atomics and barriers; bindings from comptime; spv2wgsl arms | 250 |
| `build.zig` | `-windows` steps, `ShaderOutput.spv`, artifact switch, `windows-smoke`, manifest | 250 |

`wgpu_vulkan.zig` breakdown: instance/device 250, surface 250, handles 150, memory 150, resources 300,
descriptors 250, pipelines 300, commands 400, submit/uploads/retire 300, readback 120, debug 100.

**Total: about 6 500 new lines for a working Windows port (6 000 to 7 000).**
* That is the same order as mach's Vulkan backend (3 706 lines) plus its Windows core, for an API
  surface a fraction of the size.
* The earlier plan estimated 7 000 to 9 000 lines, but it carried a layout tracker, decoders for
  dead dom externs, and a larger `win32` surface, none of which this plan needs.
* `vk.zig` is the least certain line. The device property, limit and feature structs must be
  declared in full, because they are read by pointer.

**Rough turn estimates** (one turn = one reviewed, green snapshot):

| stage | turns |
|---|---|
| S0 | 2 |
| S1 | 2 |
| S2 (switches, gate reclassification, artifact sweep, host core) | 5-7 |
| S3 | 2-3 |
| S4 | 3-4 |
| S5 (web-first kompute + native compute) | 3-4 |
| S6 | 2-3 |
| S7 | 2 |
| S8 | 4-6 (audio alone is 2-3; OGG adds a decoder port) |

**About 25 to 33 turns to a Windows launcher at parity**, minus IME and OGG. The earlier plan
estimated 20 to 26, but its scope did not include the compute fix or the gate reclassification.

**The Vulkan functions used, ~95:**
* **Loader and instance:**
  * `vkCreateInstance`; enumerate layers, extensions and physical devices;
  * device properties, features, queue families, memory and format properties;
  * `vkCreateDevice`;
  * surface support, capabilities, formats and present modes;
  * `vkCreateWin32SurfaceKHR`;
  * the debug-utils messenger and object names.
* **Device:**
  * queue; wait idle; `vkQueueSubmit2`; `vkQueuePresentKHR`;
  * swapchain create/destroy/images/acquire;
  * semaphores, incl. `vkWaitSemaphores` and `vkGetSemaphoreCounterValue`;
  * command pools and buffers; memory allocate/free/map;
  * buffers, images, views, samplers, shader modules;
  * set layouts, pipeline layouts, descriptor pools/sets/updates;
  * graphics and compute pipelines.
* **Commands:**
  * `vkCmdBeginRendering` and `vkCmdEndRendering`;
  * bind pipeline, sets, vertex and index buffers;
  * draw and draw indexed; viewport and scissor; dispatch;
  * copy buffer, buffer->image, image->buffer;
  * `vkCmdPipelineBarrier2`.

---

## 6. Stages

Each stage adds one thing and has one number that says pass or fail. Nothing moves on after a
partial pass.

**S0 - the SPIR-V probe (no engine code).**
* **What.** `zig build vk-probe` is a small native exe. On EACH GPU it creates a device, then
  legalizes and loads every graphics `.spv` in the cache and builds a pipeline for each, with
  layouts from `reflect`.
* **Pass, all three:**
  * 79 of 79 graphics modules accepted on both GPUs;
  * 0 validation-layer messages;
  * `spirv-val --target-env vulkan1.3` clean on every legalized graphics module. That covers the
    rules zimr's own `check` does not know, e.g. `ArrayStride` on pointer types.
* Compute is reported, not judged: it cannot pass until S5.
* It proves `vk.zig`, the loader and `spv_vulkan.zig`, and it is the cheapest possible
  falsification of 1.4.

**S1 - a window that clears.**
* **What.** `win32.zig`, the surface, acquire/present, and one render pass that clears. No engine.
* **Pass:** 60 s of clearing with 20 resizes, a minimize and a monitor/DPI change, on each GPU.
  0 validation messages, 0 live objects at exit.

**S2 - the host switch and `hello_world`.**
* **What.**
  * `host.zig`, `gpu_abi.zig`, the switches, the gate reclassification, and the shader-artifact
    rename.
  * `App.run` native.
  * Buffers, textures, samplers, bind groups, render pipelines, draws and uploads.
* **Pass, all four:**
  * the web build's JS and WGSL are byte-identical to before;
  * `hello_world.exe` renders;
  * a screenshot differs from Chrome's by at most 1 LSB on 99.9% of pixels (the font rasterizer is
    ours on both sides);
  * the census reads zero at exit.

**S3 - input and UI.**
* **What.** The message table of 5.6.
* **Pass, all three:**
  * `ui-full-showcase` is fully usable with mouse, wheel, keyboard and typed text at 100% and 150%
    scaling (Simon's verdict);
  * a scripted input replay asserts the same widget state natively as the headless web harness
    does;
  * **text editing works without the DOM overlays**, in `text_field` and `ui_code_editor`: typing,
    selection, backspace/delete, arrows, home/end.
* **Why the third point matters.** On the web, text entry goes through DOM `<input>` overlays and
  `input_push_char` is never called. So `ui.zig`'s own editing path (`InputSnapshot.chars_typed`,
  "ASCII for now") will run for real for the first time here, and any gap it has is scoped here
  (the earlier plan's P3 gate). IME and clipboard paste are out of scope until S8.

**S4 - the graphics flagships.**
* **What.** Depth, render textures, MRT, MSAA resolve, depth-texture sampling, `FragDepth` and
  point lists, across `cube3d`, `render_texture`, `text-on-texture`, `fog-rendering`,
  `cel-shading`, `deferred-render`, `shadowmap-sw`, `pipeline-msaa`, `hybrid-raymarch` and
  `point_rendering`.
* **Pass, both:**
  * each is within tolerance of Chrome;
  * `shadowmap-sw`'s three panels agree natively as they do on the web.

**S5 - compute.**
* **What.**
  * The kompute source change and its spv2wgsl arms, web first and verified on a phone.
  * Then reflection in `compute_host`, and readback.
* **Pass, all three:**
  * the zimrnum conformance sweep (`src/gpu/zn_conformance.zig`) passes on both GPUs with the same
    tolerances it uses on the web;
  * `fluid-gpu` and `fluid-sort` run;
  * the WGSL diff on the web side is binding numbers only.

**S6 - the launcher and the gates.**
* **What.** All 32 flagships in one exe, and `windows-smoke` in the build.
* **Pass:** every smoke-roster example runs N frames offscreen with 0 validation messages, a zero
  census after the twice-lifecycle, and an empty object tracker at exit.

**S7 - measure, then optimize.**
* **What.** Frame time per flagship on both GPUs. The cost of the full barriers (tracked barriers
  on one pass, measured). The allocation count on the launcher. Pipeline-creation time at startup
  (a `VkPipelineCache`).
* **Only changes that move a number land.**

**S8 - polish.**
* Rendering during drag-resize (`WM_ENTERSIZEMOVE` + a timer).
* Touch through `WM_POINTER`.
* Pointer lock, clipboard, file drop.
* WASAPI audio (with an OGG decoder).
* A thread pool for jobs.
* The BGRA present blit, for surfaces without RGBA8.
* Porting the 8 hand-written-WGSL examples' shaders to Zig.

---

## 7. Keeping the door open

* **Linux.**
  * **What it takes.** A new window layer (`x11.zig` or `wayland.zig`) and `libvulkan.so.1`. The
    Vulkan host is unchanged apart from the surface extension.
  * **Why it matters.** With Mesa's lavapipe (a CPU Vulkan driver, `apt install
    mesa-vulkan-drivers`), the 1-core Linux sandbox could RUN the native build in offscreen mode,
    with the validation layer, and compare pixels. That would be the first time Claude's sandbox
    could see a real GPU API draw anything.
  * **Cost.** A test-only dependency, never a build dependency.
* **Windowless compute.**
  * **What it takes.** Offscreen mode with no window at all: kompute on the RTX 5060 from a console
    program.
  * **Why it matters.** It feeds directly into the ACTIVE plan (`rl_track_plan.md`): training runs
    that are bound by a browser tab today could run as native batch jobs on the same kernels.
* **Android.**
  * **What it takes.** `aarch64-linux-android`, `VK_KHR_android_surface`, a NativeActivity window
    layer, and APK packaging. Packaging is the hard part: signing and zipalign without Java tools.
  * **Risk.** The Adreno instability behind spv2wgsl's runtime-sized storage arrays was seen through
    Dawn, i.e. through Vulkan, so a direct path could meet it too.
  * **Priority.** The browser already runs zimr on Android, so this is the lowest-priority door.
* **Apple.**
  * **First: MoltenVK.** It needs `VK_KHR_portability_enumeration` + `portability_subset`, a Metal
    surface, and the BGRA present blit (MoltenVK surfaces usually lack RGBA8).
  * **If MoltenVK is not good enough:** a Metal host needs a SPIR-V -> MSL writer, and spv2wgsl's
    structurizer is most of that work already.
  * **iOS** adds signing.
* **What keeps them open.** The Vulkan host takes a `VkSurfaceKHR` factory from the window layer and
  nothing else. Nothing in the host or the loop names Win32.

---

## 8. What must not break

* **The web build.**
  * The switches default to `web` on wasm.
  * The generated JS and WGSL must be byte-identical before and after S2. Compare the
    `zig-out/standalone/*.html` blobs, decoded.
  * The only exception is where a decision deliberately changes them: kompute's bindings, atomics
    and barriers (D3), confirmed on a phone.
* **The gates.** `zig build check`, `test`, `test-fast`, the smoke runner, the corpus and lint stay
  green at every stage, on the Linux sandbox and on Windows.
* **The census.** Its semantics must not change: the leak gate reads the same counters on both
  platforms.
* **The acyclic import graph.** `host.zig`, `gpu_abi.zig`, `vk.zig`, `wgpu_vulkan.zig`,
  `spv_vulkan.zig`, `win32.zig`, `native_services.zig` and `native_loop.zig` are leaves below the
  files that use them.
* **The phone.** Every stage that touches a shared file is verified on a phone before the native
  side builds on it. That means S2's switches and gates, and S5's kompute change.

---

## 9. Risks and unknowns

| risk | how it is retired |
|---|---|
| A driver rejects SPIR-V the audit passed (e.g. `ArrayStride` on pointer types) | S0 on both GPUs, before anything else; the legalizer strips what the drivers or the validation layer object to |
| A shader reads a value that is undefined in SPIR-V but zero in WGSL (`OpUndef`, uninitialized variables, workgroup memory) | Native shows it as garbage, which is a real bug on both platforms; the CPU twin and the pixel comparison find it, one example at a time |
| WGSL approximations (`OpSMod`, unordered compares) make the web differ from the SPIR-V's meaning | Expected; a native-vs-web pixel difference is examined before it is called a native bug |
| `GENERAL` layouts or the full barriers are too slow somewhere | S7 measures; tracked barriers are the known fallback |
| Presenting from the NVIDIA GPU on the hybrid laptop | S1 on both GPUs, with `ZIMR_GPU` |
| `maxMemoryAllocationCount` on the launcher | a named assert at 80%; sub-allocation if it fires |
| The kompute change regresses the web on Adreno | S5 is web-first, with a phone round; the old path stays in git |
| std/Win32 drift on the next Zig bump | every OS call is hand-declared in one file; the bump checklist gains `test-windows` + one `-windows` build |
| Behaviour the bridge implements implicitly (defaults, clamps, row-pitch rules) | S2-S4 pixel comparisons against Chrome, one example at a time |
| No validation layer installed | D6 decided: Simon installs the LunarG SDK before S0 |

---

## 10. Decisions - MADE (awaiting Simon's confirmation of all eight together)

Each was asked one at a time, with its choices, the pros and cons, and a recommendation, and is
recorded here as Simon answered it.

**All eight were re-checked against the earlier plan (section 13), and all stand.** One refinement
within D2: the Vulkan host file is `wgpu_vulkan.zig` (the earlier plan's name), which sorts beside
`wgpu.zig` and reads "the wgpu calls, on Vulkan".

* **D1 - The seam. DECIDED (Sep 27, Simon): the raw host calls.** The Vulkan backend implements
  the same ~60 `wgpu.zig` calls with the same u32 handles and descriptor blobs, as a native twin of
  bridge.zig (section 5.1). Rejected: a typed seam (it would change every pipeline and bind-group
  call site) and a native WebGPU library (a C++/Rust dependency).
* **D2 - Where native code lives. DECIDED (Sep 27, Simon): flat files in `src/`.**
  * `vk.zig`: hand-declared Vulkan.
  * `wgpu_vulkan.zig`: the native twin of bridge.zig.
  * `spv_vulkan.zig`: legalize, reflect, check.
  * `win32.zig`: the window layer.
  * `native_services.zig`: dom, audio, jobs, net.
  * `native_loop.zig`: `App.run`'s native loop.

  They sit beside `host.zig` and `gpu_abi.zig`. Later platforms follow the same pattern (`x11.zig`,
  `android.zig`). Rejected: a `src/native/` subdirectory, and a `platform/` + `vulkan/` split.
* **D3 - kompute. DECIDED (Sep 27, Simon): fix at the source.** kompute emits explicit bindings
  (Params at 0, `Buffers` fields at 1..N), inline-asm `OpAtomicIAdd/Load/Store`, and
  `std.spirv.workgroupBarrier()`. spv2wgsl gains `OpAtomic*`/`OpControlBarrier` arms in place of the
  call-name intercept, and `compute_host` takes its bindings from comptime (section 5.5). It lands
  web-first: `fluid_gpu`, `fluid_sort` and the zimrnum sweep pass on the phone before native builds
  on it. Rejected: a native-only rewrite (a data-flow pass, and two different programs) and deferring
  compute until Zig implements `@atomicRmw` for SPIR-V.
* **D4 - The name of the embedded shader artifact. DECIDED (Sep 27, Simon): a neutral-name sweep.**
  * The build exposes `"<name>.shader"` and `"<entry>_shader"`: WGSL bytes on web builds, SPIR-V
    bytes on native builds.
  * `wgpu.createShaderModule(device, code, label)` becomes the one call.
  * `createShaderModuleWgsl` stays only for hand-written WGSL, and the Vulkan host refuses it by name.
  * The rename is mechanical, the compiler catches every missed site, and the web output stays
    byte-identical.

  Rejected: keeping the `.wgsl` names (they would lie on native), and a generated module per shader
  carrying both artifacts (more wiring, and a wasm-size trap).
* **D5 - The native host's state. DECIDED (Sep 27, Simon): one documented module global.**
  * Exactly one `var host: ?*Host` in `wgpu_vulkan.zig`, with a `lint:off module-var` giving the
    reason: it is the native twin of the bridge's JS-side tables, the same category as `active_app`
    and the handle census.
  * Everything else lives in the `Host` struct, including the Vulkan dispatch tables.

  Rejected: threading a `*Host` through every `wgpu` call (every call site changes, for one device
  per process), and packing it into handles (a u32 cannot hold a pointer, so the global survives,
  only hidden).
* **D6 - The validation layer. DECIDED (Sep 27, Simon): install the LunarG Vulkan SDK on the
  Windows box.**
  * It brings `VK_LAYER_KHRONOS_validation` (named misuse messages, plus the object tracker at
    exit).
  * It brings `spirv-val`, which S0 runs over all 93 modules as the official check alongside
    `spv_vulkan.check`, and `spirv-dis`.
  * It is a dev-time runtime tool only. Builds never need it, and the host enables the layer only
    when it is present (never in `ship`).

  Simon installs it before S0. Rejected: the layer alone (no `spirv-val`), and no layer at all
  (misuse becomes driver-specific corruption).
* **D7 - Order after S2. DECIDED (Sep 27, Simon): graphics first.**
  * The order is S3 (input + UI), S4 (graphics flagships), then S5 (compute).
  * Each graphics stage is checked against Chrome's pixels, and broadens the host before compute
    leans on it.
  * kompute's web-side change (D3) lands in parallel, with its own phone round, so S5 starts
    ready.

  Rejected: compute right after S2, and a windowless compute runner before `hello_world`.
* **D8 - `DepthReplacing`. DECIDED (Sep 27, Simon): legalize now, plus an upstream request.**
  * `spv_vulkan.legalize` inserts `OpExecutionMode %entry DepthReplacing` at load time, with a unit
    test.
  * Separately, Zig is asked to let `SpirvFragmentOptions` express the mode, or to emit it
    automatically when `FragDepth` is written. When that lands, `gen_shader_externs` sets it, and
    the insertion becomes a check.
  * Simon files the upstream request, or explicitly OKs Claude to; nothing is posted externally
    without that.

  Rejected: insertion only (the build's SPIR-V would stay incomplete for good), and waiting for Zig
  (two S4 flagships lost for an unknown time).

---

## 11. Found in passing (not this plan's work)

* **Web input numbering is wrong.** The bridge sends DOM `keyCode` and DOM `button`
  (`bridge.zig:2850-2915`) into an engine that expects raylib numbering
  (`runtime.zig:1671-1700`, `types.zig:699-836`). Flagged as a separate task.
* **The bridge leaks one surface-view handle per frame** (`bridge.zig:1027-1031`). Flagged as a
  separate task.
* **spv2wgsl lowers `OpSMod` to `%`**, which is wrong for mixed signs. It is documented at
  `spv2wgsl.zig:7906-7909`.
* **Stale comments.**
  * The bind-group-layout blob comment says 4 fields per entry; there are 5 (`gpu.zig:237-244`).
  * `webtests/wgpu_smoke.zig`'s name lists are stale. They miss the mip/array views, `gpu_ms` and
    `adapter_info`, and the dom lists lag too. The runner's Proxy hides this, because an unlisted
    import returns 0.

---

## 12. Journal

* **Sep 27** - Plan written fresh; no code was written.
  * **Studied:** mach's sysgpu Vulkan backend and Windows core, and zimr's wgpu seam, frame
    protocol, host imports (all 314 gallery wasms measured) and shader chain.
  * **Audited** all 93 cached SPIR-V modules against the Vulkan rules.
  * **Probed** the compiler:
    * `Linkage` comes only from 2122;
    * `DepthReplacing` cannot be expressed;
    * `build-exe` works;
    * `@atomicRmw` is unimplemented;
    * inline-asm atomics and barriers compile to real ops with no pointer parameters.
* **Sep 27** - Simon's eight decisions (section 10), asked one at a time. Each was folded into the
  plan as it landed:
  * D1: raw host calls.
  * D2: flat files in `src/`, with the paths renamed throughout.
  * D3: fix kompute at the source.
  * D4: the neutral `.shader` / `_shader` names.
  * D5: one documented module global.
  * D6: install the LunarG SDK, with `spirv-val` added to S0.
  * D7: graphics first.
  * D8: legalize now, plus an upstream request.
* **Sep 27** - Compared with the earlier plan, `vulkan_backend.md` (section 13); all eight
  decisions re-checked and they stand.
  * **Adopted from it:**
    * `-windows` step names;
    * a Windows compile gate in `check`;
    * `oldSwapchain` hand-off and in-place view handles;
    * validation on by default with a `ZIMR_VK_VALIDATE` override;
    * the S3 text-editing gate;
    * the loader in the window layer;
    * the minimal tracker as the S7 fallback;
    * the file name `wgpu_vulkan.zig`;
    * turn estimates.
  * **Added beyond both:** `vk-abi-check` (translate-c as the oracle for the hand-declared structs).
  * **Line estimate:** raised to about 6 500.
  * **Still to fold in** (the session hit its usage limit):
    * a "deliberately NOT doing" list;
    * S8's audio design (WASAPI voice mixer; OGG needs a Vorbis decoder port, since the engine has
      only a metadata sniffer at `codecs.zig:7507`);
    * a byte-exact blob appendix.

---

## 13. Comparison with the earlier plan (`vulkan_backend.md`)

Read only after this plan's eight decisions were made, at Simon's request.

**Where the earlier plan is right and this plan adopted it:**
* build steps named for the target OS (`-windows`), not "native";
* a cross-compile gate so web-first work cannot silently break native;
* `oldSwapchain` hand-off, with swapchain view handles refreshed in place;
* the validation env var, here as an override of an on-by-default layer;
* verifying `ui.zig` text editing without the overlays;
* the loader externs living in the platform file;
* the minimal layout tracker, kept as the fallback if S7 needs one;
* the monolith file name `wgpu_vulkan.zig`;
* a "not doing" list and turn estimates.

**Where both plans agree:**
* raw host calls with the same blobs;
* Vulkan 1.3 dynamic rendering;
* hand-written bindings loaded at run time;
* one allocation per resource;
* one big descriptor pool;
* discrete-GPU preference;
* the negative-viewport flip;
* WASAPI later;
* a byte-identical web build as P0/S2 acceptance.

**Where the earlier plan is outdated or wrong, measured this session:**

| earlier plan | now |
|---|---|
| shaders go through `zspv`, native consumes `shader.rewritten.spv` | `zspv` was deleted in 2307; decorations come from `@extern`; the cache holds only `shader.spv`/`compute.spv` |
| "the SPIR-V Tint accepts is what Vulkan consumes", risk retired | compute has fake atomics and barriers, storage pointers passed into functions, and no bindings; `DepthReplacing`, `NonWritable` and `PointSize` gaps (1.4) |
| prefer a BGRA swapchain; the engine branches on the format | the bridge forces RGBA8, because a BGRA backbuffer breaks the cached 2D pipeline in RTT passes; both GPUs offer RGBA8 |
| override constants map to spec constants from the Zig `.spv` twins | `pipeline_constants` is hand-written WGSL; no Zig shader has spec constants; constants are web-only |
| native OGG decode uses zimr's own pure-Zig decoder | there is no Vorbis decoder, only a metadata sniffer (`codecs.zig:7507`) |
| keycodes are "the web's"; wheel converts lines to pixels | the engine expects raylib keys and notches, and the web bridge itself is wrong (task flagged) |
| a host `pub fn main` loop | breaks the 17 own-`main` examples; `App.run` owns the loop instead |
| implement the ~68 dom externs, incl. fullscreen, icon, fetch, screenshot | 32 are dead (never imported by any of 314 wasms); scope to the 56 used |
| resize via `js_window_resized_take` | dead; sizes are pulled every frame |
| frame sync finds "the submit that touched the swapchain" via a tracker; one render-done semaphore per slot | a timeline semaphore numbers every submit (works windowless too); one present semaphore per image |
| `writeBuffer` may memcpy directly into host-visible memory | wrong between submits; always stage |
| 51 calls, 52 gates; only `wgpu`/`dom`/`audio` blocks switched | 60 calls; 216 `isWasm` gates in 10 files, incl. `text2d`'s font no-ops, that must be reclassified |
| decoders inside the monolith | the Vulkan host cannot import `wgpu.zig` (import cycle), so a `gpu_abi.zig` leaf holds the enums and decoders |

**Decisions re-checked against it:**
* **D1:** same choice in both plans.
* **D3, D8:** the earlier plan missed the problem entirely.
* **D4:** its per-site comptime `.wgsl`/`.spv` switch would put a platform branch in 54 examples.
* **D2:** it is also flat.
* **D5:** it has the same implicit global.
* **D6:** it made the layer optional; the SDK now also feeds `vk-abi-check`.
* **D7:** it put compute before input; with D3 web-first, graphics first remains right.

**None of the eight changes.**
