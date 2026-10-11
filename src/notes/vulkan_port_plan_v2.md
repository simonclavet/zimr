# vulkan port plan v2 - zimr on Windows through Vulkan, running the Zig compiler's own SPIR-V

**Status: CONFIRMED AND STARTED (Oct 5).**
* Simon's go-ahead (Oct 5): "make progress on this plan, even if you can't run on Windows ... check
  that it compiles for Windows with cross compiling ... verify by inspection that it should compile
  and run fine on Windows". All eight decisions of section 10 stand, confirmed together.
* **How the work runs:** every stage's code is written and CROSS-COMPILED for `x86_64-windows-gnu`
  in the Linux sandbox (no SDK needed: Zig ships the MinGW import libraries); what is pure runs its
  tests here; what needs a GPU runs on Simon's laptop, from a short run list per stage.
* **Done so far:** S0's offline half - `src/spv_vulkan.zig`; S1 - `src/vk.zig`, `src/win32.zig`,
  `src/vk_hello.zig`, both ABIs checked against official headers at compile time, and RUN by Simon on his desktop
  (Oct 5); S2 under way - `src/gpu_abi.zig`, `src/host.zig`, `wgpu.zig`'s host switch, and the Vulkan host's
  skeleton `src/wgpu_vulkan.zig` (section 12, Oct 5).
* **From S2 on, Simon tests once, when the port is complete** (Oct 5: "I will not be able to test more until the
  whole thing is ported"). Every stage is therefore proven in the sandbox before the next builds on it: compiled for
  Windows, ABI-checked, its pure parts tested here, the web build unchanged.

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
    * decorates `NonWritable` on StorageBuffer variables that only vertex entries reference and that
      nothing writes (a written one is refused by name: `VertexStageStorageWrite`). On 2307 the
      compiler decorates CONST storage pointers itself; zimr's `StorageBufferPtr` is not const, which
      is the only reason this gap exists (a source fix: section 12, Oct 5);
    * drops `ArrayStride` on POINTER types when the module has no `OpPtrAccessChain` - the only
      instruction that decoration gives meaning to (2307 emits it on unused pointer types; validators
      may refuse it outside `PhysicalStorageBuffer`);
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
* **`zig build vk-abi-check`** is dev-only: it needs the headers' include directory, from
  `-Dvulkan-headers=<dir>` or `VULKAN_SDK` (BUILT Oct 5).
  * It runs `zig translate-c` on `vulkan_core.h` + `vulkan_win32.h` (with the few Windows types
    `vulkan_win32.h` names declared ahead of it: `windows.h` itself pulls in clang intrinsic headers
    this translate-c cannot read).
  * Its twin, **`zig build win32-abi-check`**, checks `win32.zig` against the MinGW `windows.h` Zig
    ships (the intrinsic headers' include guards pre-defined), and needs nothing external.
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

**S3 - input and UI.** Four sub-steps, each its own green snapshot:
* **S3a - the message table (1 turn).** Every rule below matches what the browser bridge already sends, so the
  engine sees the same input on both:
  * **Keys are physical**, as `KeyboardEvent.code` is on the web: the scancode is `HIWORD(lParam) & (KF_EXTENDED |
    0xff)`, with RGFW's corrections - `0x54` (Alt+PrintScreen) is `0x137`, `0x146` (Ctrl+Pause) is `0x45`, `0x136`
    (CJK IMEs set the extended bit on the right Shift) is `0x36` - and `MapVirtualKeyW(vk, MAPVK_VK_TO_VSC)` when the
    scancode is 0. The extended bit tells the right Ctrl and Alt, the keypad Enter and the arrow cluster from their
    twins.
  * **Repeat is the OS's**, as the browser's `repeat` flag is: `lParam` bit 30, passed to `input_push_key_down`.
  * **Text comes only from `WM_CHAR`** (UTF-16 units; the engine combines surrogate pairs, as ImGui's
    `AddInputCharacterUTF16` does) - never derived from key codes: RGFW's `ToUnicodeEx` path truncates to a byte and
    consumes the dead-key state, the failure to avoid.
  * **Focus:** `WM_KILLFOCUS` releases every held key and button, so none stays down after Alt+Tab.
  * **Mouse positions** are client coordinates in physical pixels, DIVIDED by the window's scale - the engine works
    in the browser's CSS pixels (raygpu multiplies, to framebuffer pixels; zimr must not).
  * **The wheel:** `GET_WHEEL_DELTA_WPARAM / 120` - one unit per notch, positive away from the user for
    `WM_MOUSEWHEEL` and to the right for `WM_MOUSEHWHEEL`: the bridge's normalization and signs exactly.
* **S3b - the editor (2-3 turns).** `ui.zig`'s editor completed (the design in the journal, Oct 6: selection, word
  moves, undo/redo, Tab, scroll, the overlays' options), unit-tested headlessly by feeding key and character events.
* **S3c - the platform services (1 turn).** Clipboard get and set (Win32: `OpenClipboard`, `CF_UNICODETEXT`, UTF-16 and
  UTF-8 converted - ImGui's and RGFW's code agree); the text cursor's rectangle, which places the IME
  (`ImmSetCompositionWindow`, `ImmSetCandidateWindow`).
* **S3d - the web on the same editor (1-2 turns).** The hidden `<textarea>` input sink replaces the DOM overlays;
  checked by Simon on desktop browsers and his phone.
* **Pass, all three:**
  * `ui-full-showcase` is fully usable with mouse, wheel, keyboard and typed text at 100% and 150%
    scaling (Simon's verdict);
  * a scripted input replay asserts the same widget state natively as the headless web harness
    does;
  * **text editing works without the DOM overlays**, in `text_field` and `ui_code_editor`: typing,
    selection, backspace/delete, arrows, home/end.
* **Why the third point matters.** On the web, text entry goes through DOM `<input>` overlays and
  `input_push_char` is never called, so `ui.zig`'s own editor runs for real for the first time here.
* **The design (after Dear ImGui; see the journal, Oct 6):** one editor everywhere - `ui.zig`'s, completed with
  selection, word moves, undo/redo, Tab, scroll and the overlays' options - fed by the platforms' translated
  events, with three platform services: clipboard get, clipboard set, the text cursor's rectangle (which also
  places the IME). The web replaces its overlays with one hidden `<textarea>` input sink. Clipboard and IME are in
  scope here, no longer in S8.

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
* **First, an unthrottled present mode** (`ZIMR_VK_PRESENT=fifo|mailbox|immediate`, falling back through mailbox,
  immediate, FIFO to the first the surface offers, as raygpu's `thatOrNextBest` does): under FIFO every frame waits for
  the display, and a frame time measures the refresh rate, not the GPU.
* **What.** Frame time per flagship on both GPUs. The cost of the full barriers (tracked barriers
  on one pass, measured). The allocation count on the launcher. Pipeline-creation time at startup
  (a `VkPipelineCache`).
* **Only changes that move a number land.**
* **If the full barriers cost:** a middle step before state tracking - every image still in `GENERAL`, but each pass
  records what it writes, and the barrier between two passes that write nothing the other uses is skipped. Full
  tracking is the expensive end: WGVK's (per-encoder usage maps, compatibility barriers interspersed between command
  buffers at submit, per-texture layout state) still falls back to full barriers between submissions and tracks one
  subresource range per record.
* **If the allocation count nears the ceiling:** sub-allocation, with WGVK's allocator (pools per memory type, a
  virtual block allocator, its own test file) as the reference.

**S8 - polish.**
* Rendering during drag-resize: Windows runs its own message loop while a window is dragged, so a timer is the only
  way to draw then - `SetTimer(hwnd, id, USER_TIMER_MINIMUM)` on `WM_ENTERSIZEMOVE`, `KillTimer` on `WM_EXITSIZEMOVE`,
  a frame on each `WM_TIMER` (RGFW's `RGFW_ADVANCED_SMOOTH_RESIZE`).
* Touch through `WM_POINTER`.
* Pointer lock, clipboard, file drop.
* WASAPI audio (with an OGG decoder).
* A thread pool for jobs.
* The BGRA present blit, for surfaces without RGBA8.
* Porting the 8 hand-written-WGSL examples' shaders to Zig.

---

## 7. Keeping the door open

* **Linux:** section 7a below - from a door to a plan, because it proves the native structure on a second window
  system, and because the sandbox can run it.
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

## 7a. Linux

### 7a.1 Why now, and why it need not be blind

* **It proves the structure.** A second window system exercises exactly the seams the native host was built
  around - the window layer, the OS services (`native_os.zig`), and the surface the host is handed - while the
  Vulkan core, the frame protocol and every resource path stay untouched. If Linux needs changes there, the seams
  are in the wrong place; better to learn it with two platforms than with four.
* **The sandbox can run it - windowed, on both display servers.** Measured on Oct 6 with Mesa 25.2's lavapipe:
  * **X11:** `Xvfb` (a virtual X server) with `vkcube` presenting through XCB - the screenshot (`xwd`, 1152
    colors) shows the rendered cube.
  * **Wayland:** `weston --backend=headless` with `vkcube-wayland` - 60 frames presented, clean exit.
  * **Headless:** `zig build vk-host-test` already runs the host itself under the validation layer.
* **So Linux is tested by the sandbox, not by Simon** - and it can be the most-verified native platform: every
  stage below ends in something the sandbox runs, with the validation layer on, and checks (frames presented,
  zero validation messages, and on X11 the pixels themselves).

### 7a.2 What mach does (`src/core/Linux.zig`, `linux/X11.zig`, `linux/Wayland.zig`)

* **Wayland first, X11 as the fallback;** `MACH_FORCE_BACKEND=x11|wayland` forces one with no fallback. Wayland's
  failures that trigger the fallback: no decoration support, a missing library, no display connection.
* **Every system library loaded at run time,** never linked: `libX11.so.6`, `libXcursor.so.1`, `libXrandr.so.1`,
  `libxkbcommon.so.0`, `libwayland-client`, `libdecor` - versioned name first. A missing library is an error with a
  name, and the reason to fall back.
* **Its Wayland needs C:** `wayland-scanner`'s generated protocol code through `@cImport`, and a C file for the
  variadic `wl_proxy_marshal_flags` (Zig cannot define variadic functions on aarch64-linux).
* **Decorations:** GNOME implements no server-side decorations, so a Wayland client there draws its own title bar
  or has none; mach uses libdecor, and falls back to X11 without it.
* **X11 basics:** the close button through `WM_DELETE_WINDOW`, `_NET_WM_PING`, decoration hints, fullscreen state,
  resizes through `ConfigureNotify`. No DPI handling on X11; known-missing features are logged per backend.
* **Vulkan:** the instance enables all three surface extensions (xlib, xcb, wayland).

### 7a.3 Decisions

* **L-D1. X11 through XCB first; Wayland second.**
  * **X11 runs everywhere:** natively on X11 desktops, and on every Wayland desktop through XWayland, which every
    major compositor ships. One window layer reaches every Linux desktop.
  * **XCB, not Xlib.** XCB's C interface is plain: no variadic functions, no macros in the part zimr calls,
    fixed-layout event structs - it can be declared by hand and checked against its headers like `win32.zig`.
    `VK_KHR_xcb_surface` is supported by Mesa, NVIDIA and AMD.
  * **Wayland is real work:** `libwayland-client` (Vulkan's Wayland surface takes its `wl_display`), the protocol
    interfaces (`xdg-shell`, and `xdg-decoration` where offered), and decorations on GNOME. It comes second, with
    mach's rule then: Wayland when it fully works, X11 otherwise, `ZIMR_LINUX_BACKEND` to force one. Marshaling
    calls `wl_proxy_marshal_array_flags`, which is not variadic, so no C file is needed.
* **L-D2. Every system library loaded at run time,** with its versioned name: `libvulkan.so.1` (already),
  `libxcb.so.1`, later `libxkbcommon.so.0`, `libwayland-client.so.0`, `libdecor-0.so.0`. No link-time dependency:
  one binary runs on any distribution, and a missing library is reported by name.
* **L-D3. Declarations by hand, checked against the headers.** `xcb.zig` declares only what zimr calls; `zig build
  xcb-abi-check` translates the system's XCB headers (`libxcb1-dev`, in the sandbox) and compares every struct's
  size and field offsets and every function's signature - the `win32-abi-check` pattern.
* **L-D4. The window layer hands the host a surface, and nothing else.** Today the host creates the Win32 surface
  from the window's handles. It becomes: the window layer names its instance extension and creates the surface
  (`VkSurfaceKHR`) through a tiny table of its own creation command; `SurfaceDispatch` keeps only the commands
  common to every platform (destroy, support, capabilities, formats, present modes). The host's frame protocol
  reads the window's size, scale and flags (resized, minimized, close requested) - the same fields on every
  platform.
* **L-D5. Keys as physical codes first.** An X11 keycode is the Linux evdev scancode plus 8, so the web's
  `KeyboardEvent.code` (physical keys - what games bind) maps from a table, without xkbcommon. Layout-aware text
  input (the characters a key types) comes later, through `libxkbcommon-x11`. Mouse buttons and motion are core
  events; the wheel is buttons 4 to 7.
* **L-D6. Scale from `Xft.dpi`.** X11 has no per-monitor scale: the desktop's choice is the `Xft.dpi` entry of the
  root window's `RESOURCE_MANAGER` property (what GTK, Qt and Chrome read); 96 when absent; scale = dpi / 96 for
  the logical (CSS) size. Wayland later: `preferred_buffer_scale`, or fractional-scale-v1 with the viewporter.
* **L-D7. No frames while unmapped.** A minimized X11 window is unmapped; some drivers block a FIFO present to an
  unmapped window, so the loop skips frames between `UnmapNotify` and `MapNotify`, as it skips them while a Windows
  window is minimized. Resizes arrive as `ConfigureNotify` and mark the swapchain for a rebuild (out-of-date and
  suboptimal results are already handled).
* **L-D8. Window-manager manners.** The close button through `WM_PROTOCOLS` / `WM_DELETE_WINDOW`; `_NET_WM_PING`
  answered, so the desktop does not mark zimr unresponsive during a long frame; the title as `_NET_WM_NAME`
  (UTF-8) and `WM_NAME`; `WM_CLASS` for the desktop's window grouping.
* **L-D9. One binary for all distributions:** `x86_64-linux-gnu` with a conservative glibc version (Zig selects
  it at build time). Not static musl: a static program cannot `dlopen` the system's glibc-linked Vulkan loader and
  X libraries.
* **L-D10. Every stage verified in the sandbox:** the validation layer on, zero messages required; X11 under
  `Xvfb` with screenshots checked; Wayland under headless weston with frames checked.

### 7a.4 Stages

* **L1. The surface seam (L-D4).** The window layer creates the surface; `SurfaceDispatch` loses
  `vkCreateWin32SurfaceKHR` to a Win32 creation table. Windows unchanged in behaviour: both Windows programs build,
  the web build identical, `vk-host-test` green.
* **L2. `xcb.zig`, `xcb-abi-check`, and `vk-hello-linux`:** a window that clears, presented through XCB, the
  Linux twin of S1 - run under `Xvfb`, its screenshot checked for the clear color, zero validation messages.
* **L3. The native loop on Linux; `hello-world-linux`:** the engine's first Linux frames - run under `Xvfb`, the
  screenshot checked (background color, the squares' blue, the text present), zero validation messages. Every
  example then gets a `-linux` step beside its `-windows` one.
* **L4. Input, scale, title, close, unmapped frames** (L-D5 to L-D8) - checked under `Xvfb` with synthesized events.
* **L5. Wayland** (L-D1's second half): `libwayland-client`, xdg-shell, decorations where possible, X11 as the
  fallback - checked under headless weston.
* **L6. The distribution build** (L-D9): the glibc baseline chosen and recorded; a release `.tar` per example.

---

## 7b. The backend tutorial

### 7b.1 What it is

* **One page, a course in graphics backend development, taught through zimr's own code:** how one engine draws
  through the browser's WebGPU, through Vulkan on Windows, Linux and Android, and - for macOS and iOS - through
  Vulkan on Metal or Metal itself. It explains what each layer is, why it is shaped that way, and the intuition
  behind the techniques (explicit synchronization, descriptor sets, coordinate conventions, swapchains), so a
  reader learns backend development in general, not only zimr's.
* **Tone:** neutral and precise, like the zimrnum and robot-mocap tutorials: no development anecdotes, no plan or
  stage numbers, no humor. Interesting through its subject - the diagrams, the worked examples, the comparisons
  between APIs.
* **Name:** `src/notes/tutorials/backends-tutorial.html`, published as `backends-tutorial.html`.

### 7b.2 Form - zimr's documentation pipeline, as the robot-mocap tutorial uses it

* **Lots of real code, generated from the source.** Every declaration shown in full is a `src-fold` -
  `<details class="src-fold" data-src="src/wgpu_vulkan.zig" data-decl="fn submitBatch(">` - which
  `tools/doc_folds.zig` fills in from the file, so the page cannot show code that no longer exists. Most folds start
  closed, so the prose reads straight through and the code is one click away; the few the text walks through line
  by line stay open (`<pre data-src=... data-decl=...>`).
* **Short quotes, checked.** A few lines quoted inside the prose are checked by `doc_sync` (the page is paired
  with its source files); illustrative code that is not in the source is marked `class="sketch"`.
* **Diagrams in text:** ASCII diagrams in `<pre><code>` - the layer stack, a frame on the GPU timeline, the
  coordinate systems, the synchronization of a submit - as the other tutorials draw them.
* **Tables** for every mapping between APIs (WebGPU to Vulkan to Metal): formats, blend factors, binding kinds,
  load and store operations, coordinate conventions.
* **Worked examples:** one frame of `hello_world` followed from `wgpu.zig` down to `vkQueuePresentKHR`; one
  texture upload followed through staging, the barrier and the copy; one shader followed from Zig to SPIR-V to WGSL
  and to legalized Vulkan SPIR-V.
* **The pipeline's gates:** the page goes in `doc_pages` (styled by `docfmt`, checked by `doc-gate`), in
  `doc_folds_pages`, and in `doc_sync`'s pairs.

### 7b.3 Platforms not built yet

* **A status table at the top** says, per platform, what exists and how it is verified: built and run, built
  only, or designed.
* **A designed platform gets a design chapter, marked as such:** what it will take and why, from this plan
  (Android's surface lifecycle and packaging; macOS and iOS through MoltenVK first, Metal if needed) - and becomes a
  chapter about code when the code lands.
* **Verification is a chapter of its own, about method:** checking a declared ABI against official headers,
  validation layers, software drivers (lavapipe), virtual displays, comparing pixels across backends - the
  techniques for developing a backend on hardware one does not have.

### 7b.4 Outline

1. **One engine, many GPUs.** The platforms and their APIs; the status table; the shape of the answer (one
   WebGPU-like API, hosts beneath it).
2. **The API and its hosts.** `wgpu.zig`'s surface; `host.zig`'s three facts; the web host (the bridge) and the
   Vulkan host; the comptime check that both hosts implement every call with the same types.
3. **Objects and lifetimes.** Handles and generations (`Pool`); deferred destruction on the GPU timeline; why a
   destroyed object must outlive the commands that use it.
4. **Descriptions as bytes.** The descriptor blobs (`gpu_abi.zig`): one encoding read by JavaScript and by Zig;
   their decoders and round-trip tests.
5. **One shader, three languages.** Zig to SPIR-V; SPIR-V to WGSL (`spv2wgsl`); legalizing SPIR-V for Vulkan
   (`spv_vulkan.zig`); what different validators accept (handle values in WGSL, source languages, unused types).
6. **Bringing up Vulkan.** The loader and dispatch tables (`vk.zig`, generated and ABI-checked); instance, layers
   and the messenger; choosing a GPU; features; the device; memory types.
7. **Synchronization.** WebGPU's implicit ordering against Vulkan's explicit barriers; one layout and full
   barriers; the timeline semaphore; the uploads command buffer; frames in flight; acquire and present semaphores.
8. **Resources.** Buffers and textures, zero-initialized as WebGPU promises; staging; formats; samplers; uploads and
   readback.
9. **Bindings and pipelines.** Bind groups as descriptor sets; pipeline layouts; translating a render pipeline
   (vertex input, blending, depth); dynamic rendering; the Y flip and front faces.
10. **Render passes and draws.** Load and store operations, resolve, depth; binding groups at draw time.
11. **Windows and surfaces.** The surface seam; the swapchain (formats, present modes, rebuilds); Win32 (DPI,
    resize, minimize); X11 through XCB; Wayland; the native loop.
12. **Compute.** Compute pipelines and dispatches; kompute's kernels natively; readback.
13. **Android** (designed, then built).
14. **macOS and iOS** (designed): MoltenVK's portability requirements; when a Metal host is needed, and how
    `spv2wgsl`'s structurizer would serve a SPIR-V-to-MSL writer.
15. **Verifying what you cannot run** (method, 7b.3).
16. **Reference.** Every host call with its WebGPU and Vulkan counterparts; the file map; the platform matrix.

### 7b.5 Schedule

* **First: the page itself** - the outline, the status table, and chapters 1 to 11 for the code that exists (the
  API, the hosts, Vulkan on Windows, the headless host), with their folds and diagrams.
* **Then alongside the backend work, in the same turn as each stage:** L1 (the surface seam), L2 to L5 (X11 and
  Wayland), readback and kompute (chapter 12), Android, Apple - each stage updates its chapter, as the zimrnum
  tutorial grows with zimrnum. A stage's exit includes its chapter.

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

* **Oct 5 - Confirmed; S0's offline half landed.**
  * **The plan re-verified against the tree's compiler (2307):** `std.DynLib` is still
    `@compileError("unsupported platform")` on Windows; `kernel32.zig` is still 27 lines and there is
    no user32; `callconv(.winapi)`; `Compile.win32_manifest` exists. A probe declaring
    `LoadLibraryW`, `GetProcAddress` (kernel32) and `GetDpiForSystem` (user32) cross-compiles for
    `x86_64-windows-gnu` in 9 s in the sandbox, and the PE imports `USER32.dll` / `KERNEL32.dll` with
    exactly those functions - so section 5.8's compile gate needs no SDK and no Windows.
  * **Real modules from 2307** (the build's own flags):
    * a fragment shader writing `frag_depth`: `Shader` alone (no `Linkage` - probe 1's 2313
      behaviour holds on 2307), SPIR-V 1.5, and NO `DepthReplacing` - gap 1 confirmed;
    * a vertex shader reading a CONST storage pointer: the compiler decorates it `NonWritable`
      itself. Gap 2 therefore exists only because `shader_builtins.StorageBufferPtr` is a non-const
      pointer. **Follow-up candidate (web-first, a phone round):** a const pointer for read-only
      bindings closes gap 2 at the source, as P3 prefers; `legalize` keeps closing it until then;
    * both modules carry `ArrayStride` on a pointer type with no `OpPtrAccessChain` anywhere - a
      third legalization (section 5.5), since the decoration means nothing there.
  * **LANDED: `src/spv_vulkan.zig`** (std only): one indexing pass (`Module`), `reflect` (an entry
    point's globals with storage class, set, binding, location, built-in, resource kind, vertex-input
    components), `check` (capabilities, bindings, locations, block offsets, storage pointers into
    functions, kompute helpers, merge-less branches, and the gaps legalize closes), `legalize`
    (DepthReplacing, NonWritable, pointer ArrayStrides; refuses Linkage and written vertex storage).
    7 tests, two of them on the real 2307 modules above as known answers; in the fast tier; an atlas
    entry; lint 0; the tests cross-compile for Windows.
  * **NEXT - the rest of S0:** `src/vk.zig` with exactly what S0 calls (instance, physical devices,
    device, shader modules, set and pipeline layouts, graphics and compute pipelines with dynamic
    rendering, the validation layer and its messenger); the loader part of `src/win32.zig`
    (`LoadLibraryW` + `GetProcAddress` only); the `vk-probe` exe (walk a directory for `shader.spv`,
    legalize, reflect, build a pipeline per module on each GPU, report) and `zig build vk-probe`
    building it for Windows. Then S1.

* **Oct 5 (later) - S1's program built for Windows; both ABIs checked by the compiler.**
  * **`src/vk.zig`** (1 400 lines): the Vulkan subset S1 calls - 48 structures, 14 enumerations,
    the flag and limit constants, 45 commands in three dispatch tables (global, instance, device)
    filled by name through `vkGetInstanceProcAddr`; extension commands are optional fields, every
    other missing command is the named error `MissingCommand`. Handles are non-exhaustive enums of
    their ABI size (distinct types, `.null_handle`). The declarations were drafted from the
    registry (`vk.xml`: each `sType` value, each pointer's `len` and `optional`) with values from
    the translated headers - a one-off drafting script in the sandbox, no generator in the build.
  * **`tools/vk_abi_check.zig` + `zig build vk-abi-check`**: every structure's size, alignment and
    field offsets (by position), every enumeration value and constant, every command's parameter
    count and sizes, compared with `translate-c` of the official headers (Vulkan-Headers, header
    version 365) as comptime checks compiled for x86_64-windows-gnu. PASSES. Controls: a widened
    field, a wrong enumeration value and a wrong constant, planted one at a time, each fails with a
    message naming the declaration. It also caught two real errors while being built: two structures
    declared opaque that `DependencyInfo` and the messenger's callback data point to as arrays.
  * **`src/win32.zig`** (430 lines): the user32/kernel32 subset by hand with Windows' own names
    (`lint:off screaming-const`, since the check matches twins by name), the window (per-monitor
    DPI v2 by `SetProcessDpiAwarenessContext` - no manifest yet; `WM_DPICHANGED`'s rectangle
    applied; state behind `GWLP_USERDATA` from `WM_NCCREATE`), `pump`, the clock, and
    `openVulkanLibrary`. **`win32-abi-check` PASSES**; control: `WM_SIZE` planted as 6 fails by
    name. MinGW's `MSG` has six fields (no `lPrivate`).
  * **`src/vk_hello.zig`** (800 lines) and **`zig build vk-hello-windows`** -> `zig-out/windows/
    vk_hello.exe` + `.pdb` (Debug): the S1 program. GPU list and choice (discrete first; Vulkan 1.3,
    dynamic rendering, synchronization2, timeline semaphores, swapchain, a family that renders,
    computes AND presents, checked per family; `--gpu=` / `ZIMR_GPU`), validation on when installed
    (`ZIMR_VK_VALIDATE=0` off; messages logged and counted into the exit code), the frame of 5.3.5
    (timeline per submit, 2 frames in flight, acquire semaphores per slot, present semaphores per
    image, GENERAL with full barriers, a dynamic-rendering clear), rebuilds on OUT_OF_DATE /
    SUBOPTIMAL / size change with `oldSwapchain`, no frames while minimized or zero-sized,
    `--frames=N`. Imports only KERNEL32, USER32 and ntdll; `vulkan-1.dll` is loaded at run time.
  * **This Zig's reflection** is `field_names` / `field_types` / `decl_names` (no `fields` / `decls`),
    and `.spirv_vertex` takes no options payload - both met while building.
  * **S1 RUN LIST (Simon, Windows):** (1) `vk_hello.exe`: a window cycling through colors; resize it
    many times, minimize and restore, move it to another monitor (or change the display scale), then
    close it; (2) the same with `--gpu=` naming the other GPU; (3) with the LunarG SDK installed,
    the report's validation counts. PASS: no crash, the color follows every resize, the report says
    0 errors on both GPUs. The console output (the GPU list onward) is the report to paste back.
  * **NEXT:** S0's `vk-probe` (shader modules and pipelines for every cached `.spv`, through
    `spv_vulkan`), then S2. Still open: the DPI manifest (`Compile.win32_manifest`, generated in
    build.zig), atlas entries for the new files.

* **Oct 5 (evening) - S1 RUN on Simon's desktop; S2 begun with the ABI file.**
  * **S1, on Windows** (a photo of the console): "Vulkan loader 1.4", "validation layer on" (the SDK is installed),
    "GPU 0: NVIDIA GeForce RTX 5070 (discrete_gpu, Vulkan 1.4)", "using NVIDIA GeForce RTX 5070", "surface offers 5
    formats; using r8g8b8a8_unorm, FIFO present", and the window cleared (orange at that moment). The window layer,
    the loader, the instance and device, the surface and the swapchain all work on the first run. Not exercised: the
    hybrid laptop (two GPUs), the full resize/DPI protocol, the exit report.
  * **Simon tests next when the port is complete** - the status section says how stages are proven meanwhile.
  * **LANDED: `src/gpu_abi.zig`** - the contract section 5.1 describes: the 14 enumeration and flag types MOVED
    from `wgpu.zig` verbatim (which re-exports them: no call site changed), plus `AddressMode`,
    `TextureViewDimension`, `BindingKind`, `BindingResource`; the three blob formats documented byte by byte (the
    layout entry IS five u32 - the old "4 fields" comment is corrected by this file); `BlobReader` (little-endian,
    byte-wise, so the bind group's unaligned u64s read correctly); allocation-free decoders for the bind-group
    layout, the bind group and the render pipeline (fixed arrays at WebGPU's limits: 8 buffers, 16 attributes,
    8 color targets), each failing with a named error (`BlobTruncated`, `BlobBadValue`, `BlobTooManyEntries`).
  * **Proof:** 4 decoder tests on hand-written blobs, and 4 ROUND TRIPS in `gpu.zig` through the real encoders:
    every binding kind, every bind-group resource, a two-buffer instanced pipeline with `less_no_write` (its
    "less" / no-write resolved by the encoder and read back), a constant and an MRT tail; plus a check that
    `shader_introspect`'s view dimensions are numbered as `gpu_abi`'s. `gpu.zig` joined the fast tier (its closure is
    shader-free; the fast roots now get `shader_interface`): 8 of 8 pass. The web build compiles unchanged
    (`hello-world`, release: 315 of 315 steps). Lint 0.
  * **NEXT:** `src/host.zig` (the three facts, `build_options.host` optional with a per-target default) and
    `wgpu.zig`'s host switch (`web_host` aliasing the externs, `null_host` holding today's stubs, the comptime
    interface check), then `wgpu_vulkan.zig`'s skeleton implementing all 59 calls - each first a named
    "vulkan host: <call> not implemented" assert - so the native build compiles end to end, then filled in.

* **Oct 5 (night) - S2: the host facts, the switch, the skeleton.**
  * **The seam is 60 calls, not 59:** `render_pass` and `compute_pass` re-declared their externs in nested
    namespaces, and `js_render_pass_set_scissor_rect` existed only there. Its declaration moved to the main block;
    both nested namespaces are gone.
  * **LANDED: `src/host.zig`** - `Kind` (web, native, none) and the three facts (`is_browser`, `has_gpu`,
    `has_window`). The kind is `build_options.host` when a build sets it (a string, "native" for the `-windows`
    steps), else web on wasm and none elsewhere - the old rule, so no existing build changes.
  * **LANDED: `wgpu.zig`'s switch.** The 60 gates read `!host.has_gpu`; every wrapper calls `gpu_host.<name>`, the
    extern's name without `js_`; `gpu_host` is `web_host` (60 aliases of the externs) on web and none, and
    `vulkan_host` (`wgpu_vulkan.zig`) on native. A null host was not needed: the gates still return each wrapper's
    default before the call, exactly as before, so the handle census behaves as it did.
  * **LANDED: `src/wgpu_vulkan.zig`** - 60 functions generated from the extern declarations (same names minus
    `js_`, same parameter types), each still a `@compileError` naming itself: a function's TYPE can be taken without
    compiling its body, so web builds pass, while a native build lists exactly the calls it needs that are missing -
    the house rule for a backend's unsupported calls.
  * **The interface check (P6) runs in WEB builds only.** Measured: naming an `extern "wgpu"` function in a native
    build, even only through `@TypeOf`, makes the program link against a library "wgpu" (Windows: "DLL import
    library for -lwgpu not found"). Every web build compares each extern's parameter and result types with the
    Vulkan host's. Control: `device_create_buffer`'s `usage` planted as u64 fails the web build with "the Vulkan
    host's `device_create_buffer` takes a parameter of another type".
  * **The web is unchanged** (`hello-world`, release, against a baseline saved before the switch): `index.html` (the
    bridge's JavaScript) and `source.json` byte-identical; the wasm the same size, with the same 70 imports in the
    same order, differing in 4 bytes - two `i32.const`s, the `@src()` line numbers of `queueWriteBuffer`'s two
    asserts, moved by the lines inserted above them. The none build (the fast tier) passes. Lint 0.
  * **NEXT:** `web.zig`'s per-namespace switches with `src/native_services.zig`; the `isWasm()` gate
    reclassification (216 lines in 10 files); `App.run`'s native loop (`src/native_loop.zig`); a
    `hello-world-windows` step - whose first compile lists the Vulkan calls `hello_world` needs, the order in which
    `wgpu_vulkan.zig` is then written.

* **Oct 5 (late) - hello_world compiled for Windows: the to-do list, measured.**
  * **`ShaderOutput.spv`** (`shader_codegen.zig`): the compiler's own SPIR-V, returned beside the WGSL.
  * **`zimr_windows_mod`** (build.zig): the zimr source for x86_64-windows-gnu with `build_options.host =
    "native"`; every engine shader wired into it as SPIR-V UNDER THE WGSL IMPORT NAME (`<name>.wgsl`), so engine
    code embeds unchanged and receives what its host loads (the `.shader` rename of D4 is cosmetic and can follow).
  * **`zig build hello-world-windows`**: the web build's own runner and example over Windows modules. Its FIRST
    compile reached 202 of 205 steps (every engine shader compiled to SPIR-V) and failed on 24 Vulkan calls plus
    `std.heap.wasm_allocator` (a compile error off wasm in this std) - reached through the runner's exports, while
    `App.run` still returned early natively.
  * **Gates reclassified in `wgpu_app.zig`** (its two): `App.run`'s early return now means "no GPU host"
    (`!host.has_gpu`, error `NoGpuHost`); the RNG seed from the browser's `crypto.getRandomValues` is a browser
    service (`host.is_browser`). **`host.heap`**: the wasm allocator on wasm, `std.heap.smp_allocator` elsewhere
    - the four allocator sites of `wgpu_app.zig` use it (`jobs.zig` and `runtime.zig` keep theirs until a native
    build reaches them).
  * **THE TO-DO LIST, measured** (second compile: 41 compile errors, all stubs, nothing else): hello_world reaches
    41 of the 60 calls - `init_device`, `device_get_queue`, `get_surface`, `surface_get_format`,
    `surface_get_size`, `surface_get_css_size`, `surface_get_current_texture`, `surface_present`, `now_ms`,
    `gpu_ms_last`; buffers (create, write, destroy); textures (create, view, write, write region, destroy, view
    destroy); samplers, shader modules, bind-group layouts, bind groups, pipeline layouts, render pipelines (create
    and destroy each); the command encoder (create, finish), `queue_submit`; the render pass (begin, set pipeline,
    bind group, vertex buffer, index buffer, draw indexed, end). Not reached: compute, readback, MRT, copies,
    scissor, mip and array views, adapter info, non-indexed draw.
  * **The web is still unchanged** (`hello-world`, release): JavaScript and `source.json` byte-identical; the wasm
    differs in the same 4 bytes as before (`queueWriteBuffer`'s two `@src()` lines) - `host.heap` compiles to
    exactly the old allocator code. Lint 0.
  * **Hidden behind the stubs:** LINK errors - `extern "dom"` calls a native build cannot resolve - which appear
    once compilation succeeds; and the native loop (`App.run` sets up and RETURNS natively: nothing ticks frames
    yet).
  * **NEXT:** the Vulkan host's core in `wgpu_vulkan.zig` - the module state (D5), the window first (the native
    loop opens it before `init_device`), then `init_device` / `device_get_queue` / `get_surface` and the surface
    calls, moved from `vk_hello.zig`'s proven code; then the resources in the list's order.

* **Oct 5 (night, later) - S2: the Vulkan host's core and the native loop.**
  * **`wgpu_vulkan.zig`'s core** (5.3), much of it moved from `vk_hello.zig`'s run-proven code: `Host` behind the
    one module global (D5); `Pool(Slot)` - a handle is `(generation << 24) | (slot + 1)`, and a stale or unknown
    handle panics by name; bring-up in order (library, instance with validation per `ZIMR_VK_VALIDATE` and the
    messenger logging through `std.log`, the Win32 surface, the GPU choice per `ZIMR_GPU` - read through
    `GetEnvironmentVariableW`, added to `win32.zig` - the device with dynamic rendering, synchronization2,
    timeline semaphores and robust buffer access, the command pool, the timeline, two acquire semaphores);
    command buffers recycled through the timeline (`retireCompleted`); `uploads`, begun lazily, closed by a full
    barrier; `submitBatch` (uploads + commands, the acquire wait once, the timeline's next number, the present
    semaphore when presenting); the swapchain with ONE view handle per image for the host's life, refreshed in
    place on rebuild; acquire and present exactly as 5.3.5; `shutdown`, returning the validation counts.
  * **TEN CALLS IMPLEMENTED:** `init_device`, `device_get_queue`, `get_surface`, `surface_get_format`,
    `surface_get_size`, `surface_get_css_size` (client size over the DPI scale), `surface_get_current_texture`,
    `surface_present`, `now_ms` (the performance counter), `gpu_ms_last` (0, "not measured", as on a browser
    without timestamp queries).
  * **A refinement of 5.3.4:** `getSurfaceFormat` reports the swapchain's actual format - RGBA8 UNORM, or BGRA8
    UNORM when the surface lacks RGBA8 - and the engine builds its pipelines for it, as it does for a browser
    canvas (whose preferred format can be BGRA): no present blit needed.
  * **`src/native_loop.zig`** (5.2): the window (one module global: the OS keeps a pointer to it), `openWindow`
    (then `attachWindow` on the host), `run` (pump; skip while minimized; `update` - the browser's own export -
    each frame), `finish` (the host's shutdown, then the window). `App.run` opens the window before
    `initDevice`; the runner's `main` (now last in its file) runs the loop, then `runnerShutdown` (the census at
    zero), then `finishNative`, which logs the validation counts. `zimr.host` is exported.
  * **Measured:** `hello-world-windows` compiles to exactly 31 stubs, no other error - and the runner's native
    main now reaches the loop, `attachWindow`, `shutdown` and the window, so all of the new code is type-checked
    for Windows. A type error the build caught: `update` is an `export` (C calling convention), so the loop's
    function pointer says `callconv(.c)`.
  * **The web stays unchanged, and the check was strict enough to matter:** a first version kept the window in
    `App` as a field (`void` on the web) - JS still identical, but the wasm grew 8 bytes over 31 functions: the
    same code over a REORDERED `App` (Zig's automatic layout placed the existing fields differently once a field
    was added, even a zero-sized one). Moving the window to `native_loop.zig` restored `App`'s layout. Final:
    `index.html` and `source.json` byte-identical; the wasm the same size, 11 bytes differing, every one a
    `@src()` line number (three `i32.const`s before the assert call, five `SourceLocation` records' line fields,
    shifted by the lines inserted above them in `wgpu.zig` and `wgpu_app.zig`). Lint 0.
  * **NEXT:** the remaining 31 calls, starting with the command encoder, `queue_submit` and buffers - then
    textures, samplers, shader modules (through `spv_vulkan`), layouts, bind groups, pipelines and the render
    pass. Then the link stage (the `extern "dom"` calls a native build cannot resolve).

* **Oct 5 (night, last) - S2: encoders, submits and buffers; `vk.zig` complete for hello_world.**
  * **`vk.zig` grown once for the rest of S2** (drafted from the registry as before, then checked): 89 structures,
    18 more enumerations and 10 more formats, the usage / memory / stage / cull / color-write bits, `whole_size` and
    `lod_clamp_none`, 87 commands - memory and buffers, images and buffer-image copies, samplers, shader modules,
    descriptor-set layouts, pools, sets and writes, pipeline layouts, graphics and compute pipelines, binds, draws,
    viewport and scissor - and 11 more handle types. **`vk-abi-check` PASSES**; it caught `CopyDescriptorSet`
    declared opaque where `vkUpdateDescriptorSets` takes an array of them. A drafting error the size-based check
    cannot see was found by reading: `vkMapMemory`'s `ppData` (`void**`) was drafted as one pointer level - fixed to
    `*?*anyopaque` by hand. **`win32-abi-check` PASSES** with `GetEnvironmentVariableW` (unchecked since it was
    added: now checked).
  * **Six calls implemented:** `device_create_command_encoder` (a command buffer begun, `open_encoders` + 1),
    `command_encoder_finish`, `queue_submit` (`open_encoders` - 1 BEFORE the submit, so the submit that closes the
    last encoder numbers the pending destroys), `device_create_buffer`, `buffer_destroy`, `queue_write_buffer`.
  * **The machinery behind them (5.3.6, 5.4.4, 5.4.5):** one `vkAllocateMemory` per resource, of the first type
    with the preferred properties else the required ones, failing by name at 80% of
    `maxMemoryAllocationCount`; buffers device-local - or host-visible, cached and mapped for life when
    `map_read` - with the transfer usages always on, and ZEROED by `vkCmdFillBuffer` in `uploads` (WebGPU
    guarantees a new buffer reads as zeros; Vulkan memory starts undefined); staging in 4 MiB host-visible coherent
    chunks mapped for life (a larger write gets a chunk of its own), 16-byte aligned, numbered by the batch that
    consumes them and reused after the timeline passes it; a full barrier before every fill and copy in `uploads`
    (5.3.7); destroys deferred - pending while an encoder is open, then retiring with the timeline - with the
    handle's slot freed at once; zimr labels on Vulkan objects (`vkSetDebugUtilsObjectNameEXT`) when the layer is
    on; `maxBoundDescriptorSets >= 4` asserted at bring-up; shutdown drains every destroy and the staging.
  * **Measured:** `hello-world-windows` compiles to 25 stubs, nothing else; the web build unchanged (`index.html`
    and `source.json` identical, the wasm differing only in the same 11 `@src()` line bytes). Lint 0.
  * **NEXT:** the remaining 25 - textures and views (zero-cleared, `GENERAL` from creation), texture writes,
    samplers, shader modules (SPIR-V through `spv_vulkan.legalize`), bind-group layouts and groups (one pool,
    written once), pipeline layouts, render pipelines (dynamic rendering, the 5.4.7 tables, the viewport flip),
    and the render pass with its binds and draws.

* **Oct 6 - S2: textures, views, writes, samplers, shader modules.**
  * **Ten calls implemented:** `device_create_texture`, `texture_create_view`, `texture_destroy`,
    `texture_view_destroy`, `queue_write_texture`, `queue_write_texture_region`, `device_create_sampler`,
    `sampler_destroy`, `device_create_shader_module_wgsl`, `shader_module_destroy`.
  * **Textures:** the 5.4.7 formats (`depth24_plus` -> D32_SFLOAT), the usage bits mapped (transfer both ways
    always), Vulkan's sample-count flags (equal to the counts), device-local memory; moved to GENERAL across every
    mip and layer and CLEARED TO ZERO in `uploads` - color by `vkCmdClearColorImage`, depth by
    `vkCmdClearDepthStencilImage` (added to `vk.zig`; `vk-abi-check` passes) - since WebGPU zero-initializes
    textures as it does buffers. `imageBarrier` now takes the subresource range.
  * **Views:** WebGPU's default `createView()` - every mip and layer, 2D for one layer, a 2D array for several (the
    bridge passes no descriptor). A swapchain view's destroy is ignored: the host owns those.
  * **Writes:** staged, then `vkCmdCopyBufferToImage` with `bufferRowLength = bytes_per_row / texel size` (a row
    pitch that is not whole texels fails by name); layer 0, the call's mip level and origin.
  * **Samplers exactly as the bridge makes them** (read from `bridge.zig`, not from 5.4.7): the address mode on u and
    v only - w keeps WebGPU's default, clamp to edge - and WebGPU's default LOD range 0..32 (the plan's "maxLod
    unclamped" would differ from the web).
  * **Shader modules:** the embedded bytes (natively the compiler's SPIR-V, under the WGSL import name) copied into
    aligned words, legalized by `spv_vulkan.legalize`, created; a module whose bytes are not SPIR-V - hand-written
    WGSL - fails by name ("has no native path"). Destroyed at once: Vulkan reads a module only while creating a
    pipeline. Entry points keep the names the pipeline blob carries (the compiler's `OpEntryPoint` names, which
    spv2wgsl gives the WGSL).
  * **Measured:** `hello-world-windows` at 15 stubs, nothing else; the web build passes its interface check (the ten
    signatures were written by hand this time) and is unchanged (JS and `source.json` identical, the wasm's same
    11 line bytes). Lint 0.
  * **NEXT:** the last 15 - bind-group layouts and groups, pipeline layouts, render pipelines, and the render pass
    (begin, set pipeline, set bind group, vertex and index buffers, draw indexed, end).

* **Oct 6 - REVIEW of the Vulkan host so far (Simon: "review carefully ... compare with mach ... find bugs").**
  Everything since `vk_hello` has only been compiled, so the code was re-read in full against Vulkan's rules, what
  `wgpu.zig` and the bridge expect, and mach's `sysgpu/vulkan.zig` and `core/Windows.zig`. EIGHT BUGS, all fixed:
  1. **Asking for the current texture twice acquired twice** (a pending acquire semaphore reused, the frame drawn
     into the wrong image). WebGPU - and mach - return ONE texture per frame until the present: now so.
  2. **Presenting with nothing acquired panicked.** The browser presents nothing, mach returns: now a no-op.
  3. **Composite alpha was hard-coded opaque.** A surface without it would refuse the swapchain; now the first
     supported of opaque, pre-multiplied, post-multiplied, inherit (mach's order). Three constants added to
     `vk.zig`; `vk-abi-check` passes.
  4. **THE SERIOUS ONE: a destroy while `uploads` still used the object.** A buffer created, written and destroyed
     before any submit retired at the LAST submit's number - which the timeline can pass before `uploads` even
     runs: freed memory touched by commands not yet submitted. mach avoids it with per-command-buffer reference
     tracking; here, pending `uploads` now holds destroys back exactly like an open encoder.
  5. **Destroying handle 0 panicked;** the bridge's object table ignores it. Now a no-op on every destroy call
     (a stale NON-zero handle still panics by name: a real engine bug the web merely hides).
  6. **Present semaphores were destroyed at every swapchain rebuild.** A present has no fence: nothing says the
     presentation engine has consumed its wait, `vkDeviceWaitIdle` included (the known swapchain-semaphore hazard;
     the clean answer, `VK_EXT_swapchain_maintenance1`, is optional). They are now kept across rebuilds (grow-only)
     and destroyed once, at shutdown.
  7. **The acquired image's content was undefined.** WebGPU's current texture reads as zeros each frame - a first
     pass that LOADS sees black on the web. Now cleared to zero in `uploads` right after its transition.
  8. **`spv_vulkan.legalize` could mark a WRITTEN buffer read-only:** its write tracking followed access chains but
     not a pointer passed into a function. The analysis is now WRITTEN / ESCAPED (`StorageUses`, shared by
     `legalize` and `check`'s gap report): written -> refused by name; escaped -> left undecorated; provably
     read-only -> `NonWritable`. The host enables `vertexPipelineStoresAndAtomics` when offered (every desktop GPU),
     which makes an undecorated read-only buffer legal. A new test (8 of 8 pass).
  **Checked and sound:** the handle pool (no slot pointer held across an `add` to the same pool); instance and
  device creation; `submitBatch` (the acquire wait travels with the batch carrying the transition); staging (16-byte
  offsets, chunks reused only after retiring); buffer zeroing; texture creation, clears (multisampled included),
  views, writes; samplers; shader modules; present (the semaphore wait still happens on OUT_OF_DATE); sizes (depth is
  sized after the acquire, so it always matches the swapchain image); the window procedure (it APPLIES
  `WM_DPICHANGED`'s rectangle, which mach does not).
  **Known limitation, shared with mach:** dragging the window border runs Windows' modal size loop, so no frame
  ticks until the drag ends (the content stretches meanwhile) - for S3 (render from `WM_SIZE` / a timer).
  **Expected at the link stage:** `std_options`' log function must write to stderr natively.
  **Measured after the fixes:** `hello-world-windows` at 15 stubs, nothing else; both ABI checks pass; the web
  build unchanged (JS and `source.json` identical, the wasm's same 11 line bytes). Lint 0.

* **Oct 6 (later) - S2: bind-group layouts, bind groups, pipeline layouts (5.4.2).**
  * **Six calls implemented:** `device_create_bind_group_layout`, `device_create_bind_group`,
    `device_create_pipeline_layout`, and the three destroys. Each implementation keeps its stub's own signature
    line (so it matches the browser's by construction, and the web build's check confirms).
  * **Layouts:** decoded with `gpu_abi.decodeBindGroupLayout`; uniform -> UNIFORM_BUFFER, both storage kinds ->
    STORAGE_BUFFER (read-only is a promise WebGPU checks, not another descriptor), sampler -> SAMPLER, texture ->
    SAMPLED_IMAGE, storage texture -> STORAGE_IMAGE; stage flags from the visibility; the decoded entries kept
    (writing a group needs each binding's kind) and freed at the destroy.
  * **Bind groups:** one set from the newest pool page (`FREE_DESCRIPTOR_SET`; 512 sets a page, sized for the
    engine's shapes), a new page when one reports `OUT_OF_POOL_MEMORY` or `FRAGMENTED_POOL` (both result codes
    added to `vk.zig`; `vk-abi-check` passes); written ONCE with `vkUpdateDescriptorSets` (WebGPU groups are
    immutable); each entry's descriptor type from its layout's binding - a binding the layout lacks fails by name;
    a buffer size of 0 binds the rest of the buffer; views in GENERAL. The set returns to its page when destroyed.
  * **Pipeline layouts:** the groups' set layouts, no push constants; WebGPU's group number IS the set number (the
    bring-up assert guarantees 4); a 0 handle - an empty group slot - gets one shared empty set layout. More groups
    than the device binds fail by name.
  * **Destroys** deferred like every other object; shutdown destroys the pool pages (freeing every set still in
    them) and the empty layout after draining the destroys, and frees live layouts' entries.
  * **Measured:** `hello-world-windows` at 9 stubs - exactly the render pipeline and the render pass; the web build
    unchanged (JS and `source.json` identical, the wasm's same 11 line bytes). Lint 0.
  * **NEXT:** the last 9 - `device_create_render_pipeline` / `render_pipeline_destroy` (5.4.3 and the 5.4.7 tables:
    dynamic rendering, vertex input, topology, cull with counter-clockwise front faces, blend, depth compare and
    write from the blob, MRT formats, dynamic viewport and scissor) and the render pass (5.4.1: `vkCmdBeginRendering`
    with the full barrier first, CLEAR or LOAD, depth CLEAR to 1.0, MSAA resolve, the viewport flip, bind groups
    bound at draw time against the bound pipeline's layout). Then the link stage.

* **Oct 6 (later) - S2: render pipelines and render passes; `hello_world.exe` BUILDS AND LINKS.**
  * **The last nine calls:** `device_create_render_pipeline`, `render_pipeline_destroy`, `encoder_begin_render_pass`,
    `render_pass_set_pipeline`, `render_pass_set_bind_group`, `render_pass_set_vertex_buffer`,
    `render_pass_set_index_buffer`, `render_pass_draw_indexed`, `render_pass_end`.
  * **Pipelines mirror the bridge's WebGPU pipeline** (read from `bridge.zig`): vertex layouts (binding = slot),
    topology, cull with counter-clockwise fronts, the sample count; depth only when the mode tests depth AND a
    depth format is given - the pipeline's rendering depth format follows the same rule, so it matches the passes it
    is used in; the blob's compare string; blending on target 0 with the bridge's exact factors per mode (alpha,
    additive, multiply with DST_COLOR, premultiplied; all add), none on the MRT extras; dynamic viewport and
    scissor; dynamic rendering's formats. WGSL override constants fail by name (5.4.3).
  * **Passes mirror the bridge's:** a full barrier first (5.3.7); CLEAR (load op 1) or LOAD; STORE or DISCARD (store
    op 1); resolve by averaging when a resolve view is given; depth CLEAR to 1.0 and STORE; render area, viewport
    and scissor from the color attachment; the viewport FLIP (y = H, height = -H). Bind groups are recorded as set
    and bound at the next draw against the bound pipeline's layout (`setPipeline` marks every slot dirty) - WebGPU
    lets a group be set before its pipeline. Vertex and index buffers bind to the end (the bridge drops the size);
    handle-0 groups and buffers are skipped, as the bridge skips them. GPU timestamps stay off natively
    (`gpu_ms_last` reports 0, "not measured").
  * **`zig build hello-world-windows`: 205/205 steps, compiled AND linked.** The expected link stage brought no
    errors: every browser-only call `hello_world` reaches sits behind a comptime gate that is dead natively. The
    exe imports only KERNEL32, USER32 and ntdll (`vulkan-1.dll` is loaded at run time).
  * **One more gate converted (`text2d.zig`):** its five `is_wasm` sites skipped the default font's and every TTF
    font's GPU upload off-wasm ("the upload path doesn't exist on host builds") - natively, no text. Now
    `host.has_gpu`: true on the web exactly as before (the web build is unchanged), false for host tests exactly as
    before, true natively.
  * **Gates reviewed and left (correct natively for now):** `runtime.zig`'s browser bridges (title, clipboard,
    screenshot, fullscreen) and DOM cursor - no-ops until S3 gives them native versions; its clock falls back to a
    host monotonic source; its C `malloc` shim returns null off-wasm - only C-derived code uses it (image decoding),
    so S4 must point it at `host.heap`; logging already reaches stderr natively (`web.dom.log`).
  * **Measured:** both ABI checks pass; the web build unchanged (JS and `source.json` identical, the wasm's same 11
    line bytes). Lint 0.
  * **NEXT: Simon's first run of `hello_world.exe`** (expected: a 480x200 window titled "zimr - hello_world", dark
    background, four concentric blue squares, "Hello, World!" in Atkinson Mono, the viewport size line). Then the
    rest of S2's exit test: resize, minimize, DPI, the validation census at exit.

* **Oct 6 (later) - VULKAN IN THE SANDBOX; S0's GPU half done on lavapipe: all 50 engine shaders valid.**
  Simon cannot test for now ("continue working theoretically"). The sandbox reaches Ubuntu's archive, so it now has
  Mesa 25.2's lavapipe (a complete software Vulkan 1.4 device, `llvmpipe`, with every feature the host requires:
  dynamic rendering, synchronization2, timeline semaphores, robust buffer access, vertex stores) and the Khronos
  validation layer 1.3.275, plus `spirv-tools`. Vulkan now RUNS here, under validation.
  * **`vk.loadDispatch(Table, Handle, get_proc_address, handle)`:** the three loaders were one pattern (walk a table
    type's fields, fetch each by name, null allowed only for optional fields); now one generic function over comptime
    types, the three as one-line wrappers. Any program declares a small table of exactly the commands it needs.
  * **`tools/vk_shader_probe.zig` and `zig build vk-shader-probe`:** opens the loader (`std.DynLib`, libc's
    `dlopen` on Linux), creates an instance with the validation layer and a device with the host's features, and
    for every engine shader (`name=path` arguments, collected by the engine-shader loop beside the native module's
    imports) legalizes it, runs `spv_vulkan.check` on the result, and creates a Vulkan module - the layer runs the
    SPIR-V validator on each. Any finding fails the run. Runs on the build machine's driver: a GPU, or lavapipe.
  * **First run: 50 of 50 FAILED** - one cause: `OpSource Zig` (language 12, added to SPIR-V in 2024); validators
    built before then reject the value and with it the module. Debug information only: `legalize` now declares
    `Unknown` (0) in place (same length, every offset holds); `check` reports `zig_source_language`.
  * **Second run: 48 of 50 valid; `fluid_discs_vs` and `points_vs` failed a REAL rule** (VUID 04680: any struct
    holding a runtime array must be `Block`). Disassembled: the compiler declares THREE structs around the same
    runtime array while lowering `StorageBuffer(@Vector(2, f32))`; the variable uses the decorated one, and the two
    others - with pointer types to them - are referenced by nothing but their names and decorations. `legalize` now
    drops such dead structs with their dead pointer types, names and decorations (a precise dead-type elimination:
    "mentions" counted on every operand word, which can only overcount); a USED one is refused by name
    (`RuntimeArrayOutsideBlock`); `check` reports `unused_struct_with_runtime_array` / `runtime_array_outside_block`.
    The web path never noticed: spv2wgsl translates only what the variables reach.
  * **Third run: 50 shaders, every one valid for Vulkan, 0 warnings.** The SPIR-V validator is driver-independent, so
    the verdict holds on Simon's RTX 5070.
  * **Measured:** `spv_vulkan` 10/10 tests (two new); `hello-world-windows` 205/205 (the package refreshed with the
    new legalizer); `vk-abi-check` passes; the web build identical. Lint 0.
  * **NEXT - the headless host, then kompute.** (1) A headless mode for `wgpu_vulkan.zig`: no window, surface or
    swapchain; the Win32-only pieces (loading the library, environment variables, the clock) given Linux versions;
    window-system commands optional in the dispatch tables. (2) Real tests through `wgpu.zig` on lavapipe: draw
    offscreen, copy to a buffer, map and read back, compare pixels; zero validation errors required. (3) Kompute:
    compute pipelines, compute passes, dispatches, buffer copies and readbacks - exercised by kompute's own
    workloads on lavapipe, so native compute lands already tested.

* **Oct 6 (later) - toward the headless host, step 1: the window-system commands in their own tables.**
  * **Simon's Safari report** ("'texture_2d<f32>' cannot be used as the type of a 'let'" in `shapes_fs`) is the
    handle-`let` bug `spv2wgsl` already fixed: `emitLoad` binds no name for a texture or sampler, and
    `convertSpirvToWgslEntry` runs `checkNoHandleValues` on every translation. The current `shapes_fs` WGSL has no
    such `let`; the iPad's page predates the fix (rebuild and redeploy). naga 30 (built in the sandbox from
    crates.io) validates all 107 generated WGSL files - but ACCEPTS a let-bound texture, typed or inferred, exactly
    like Chrome: only Safari enforces that rule, so `checkNoHandleValues` stays its guard.
  * **The headless host needs no surface or swapchain commands**, and on Linux without a window they do not exist -
    while the host's tables treated them as REQUIRED. `gen.py` now emits five tables: `GlobalDispatch`,
    `InstanceDispatch`, `SurfaceDispatch` (VK_KHR_surface / VK_KHR_win32_surface: six commands), `DeviceDispatch`,
    `SwapchainDispatch` (VK_KHR_swapchain: five commands), each with a doc line; `vk.zig` gains
    `loadSurfaceDispatch` and `loadSwapchainDispatch` beside the other three loaders (all five over `loadDispatch`).
  * **The host and `vk_hello` moved** their 14 and 13 window-system calls to the new tables (zero left on the old
    ones), loaded beside the instance and device tables - for now unconditionally; the headless step makes both
    loads depend on having a window.
  * **Measured:** `hello-world-windows` and `vk-hello-windows` build (208/208); `vk-abi-check` passes (it walks the
    `PFN_` declarations, not the tables); the shader probe still finds 50/50 valid; the web build identical. Lint 0.
  * **NEXT - step 2:** an OS facade for the three services the host takes from `win32.zig` (open and close the
    Vulkan library, environment variables, the monotonic clock), with Linux versions; **step 3:** headless
    bring-up (no window: no surface, no swapchain extension, any device with a graphics and compute queue), window
    code comptime-gated to Windows; then the first test program through `wgpu.zig` on lavapipe.

* **Oct 6 (later) - toward the headless host, step 2: `src/native_os.zig`, the OS services on Windows and Linux.**
  * **Three services, the host's only non-window ties to Win32:** the Vulkan loader (`openVulkanLibrary` /
    `closeVulkanLibrary`, returning `vkGetInstanceProcAddr` untyped), environment variables (copied into the
    caller's buffer as UTF-8), and a monotonic clock in milliseconds.
  * **Windows delegates to `win32.zig` (unchanged); Linux uses the C library:** `dlopen("libvulkan.so.1")` with
    lazy binding (the loader's ABI-versioned name - the unversioned one comes only with development packages),
    `dlsym`, `getenv`, `clock_gettime(MONOTONIC)`. Each function is one comptime branch, so a Linux build references
    no Win32 function and a Windows build no C-library one.
  * **Tests** (`zig test src/native_os.zig -lc`, 2/2 on the sandbox; the file also compiles for Windows): an unset
    variable reads null, the clock never runs backwards, and the loader opens with its entry point - or reports
    `VulkanNotInstalled`, the one failure that is not a bug. They join the build with the headless test program.
  * **The host switched:** its library, environment and clock calls go through `native_os`; the only `win32` name
    left in `wgpu_vulkan.zig` is the `Window` type, which the headless step makes optional.
  * **Measured:** both Windows programs build (208/208); the web build identical. Lint 0.
  * **NEXT - step 3: headless bring-up** (no window: no surface or swapchain extension, no surface or swapchain
    tables, any device with a graphics and compute queue), and the first test program through `wgpu.zig` on
    lavapipe.

* **Oct 6 (later) - step 3: THE HOST RUNS, headless, on lavapipe - zero validation messages.**
  * **The window is optional:** `Host.window: ?*win32.Window`; `startHeadless()` beside `attachWindow`. Without a
    window, bring-up skips every window-system step: the surface instance extensions and `SurfaceDispatch`, the
    surface, the swapchain-extension and present-support tests in the GPU choice (any device with a graphics and
    compute queue), the swapchain device extension and `SwapchainDispatch`. Code that needs the window (swapchain
    sizing, the acquire's resize check, the surface sizes) takes it once per function through `theWindow`, which on a
    headless host fails by name.
  * **For programs that start the host themselves:** `wgpu.vulkan_host` is re-exported; `messageCounts()` and
    `isValidating()` report the validation layer (a test without the layer FAILS: silence from an absent layer
    proves nothing).
  * **`tools/vk_host_test.zig` and `zig build vk-host-test`:** a module rooted at `wgpu.zig` built for the build
    machine with `host = native` and libc, driven exactly as the engine drives it. The first check: headless
    bring-up, a 4x4 texture cleared in a render pass, submit, destroys, shutdown. The step also runs
    `native_os.zig`'s two tests.
  * **First run, first try: "Vulkan 1.3, validation on" - "using llvmpipe" - "headless clear - no validation
    errors, no warnings".** The code written for the RTX 5070 has now EXECUTED: bring-up, device, texture creation
    and its zero-clear, the view, the encoder, the render pass (its full barrier, dynamic rendering, the viewport
    flip), the submit, the deferred destroys and shutdown - all clean under the Khronos validation layer.
  * **Measured:** both Windows programs build (208/208); the web build identical. Lint 0.
  * **NEXT:** readback - `encoder_copy_texture_to_buffer` and the `buffer_read_*` family (map-read buffers are
    host-visible and persistently mapped: "ready" is the timeline passing the submit) - and the clear's pixels
    checked; then buffer writes and copies; then a draw with a real engine pipeline; then kompute.

* **Oct 6 (later) - THE LINUX PLAN (section 7a), after mach's Linux layer and a sandbox measurement.**
  * **Simon:** improve the Linux plan, perhaps attack it now to prove the multi-backend structure; he will probably
    never test on Linux himself.
  * **The sandbox can run Linux windows:** `Xvfb` + `vkcube` (XCB) on lavapipe - the screenshot shows the cube;
    headless `weston` + `vkcube-wayland` - 60 frames, clean exit. So Linux need not be blind: every stage is checked
    here (zero validation messages; on X11 the pixels).
  * **mach (read):** Wayland first with X11 fallback, `MACH_FORCE_BACKEND`; every system library `dlopen`ed by
    versioned name; Wayland through C (scanner output, a varargs shim) and libdecor; no X11 DPI handling.
  * **Decisions L-D1..L-D10:** X11 through XCB first (everywhere via XWayland; plain C, hand-declared and
    ABI-checked), Wayland second with mach's fallback rule and no C (`wl_proxy_marshal_array_flags` is not
    variadic); run-time loading; a surface seam (the window layer creates the surface); physical key codes from
    evdev; scale from `Xft.dpi`; no frames while unmapped; window-manager manners; one glibc binary for every
    distribution; every stage verified in the sandbox.
  * **NEXT: L1, the surface seam;** then L2, `xcb.zig` and `vk-hello-linux` under `Xvfb`.

* **Oct 6 (later) - THE BACKEND TUTORIAL (section 7b).** Simon: alongside the backend work, a detailed one-page
  tutorial on how zimr reaches WebGPU, Windows, Linux, Android, macOS and iOS - neutral in tone, an interesting
  course in graphics backend development, in the zimrnum tutorial's form (lots of code, much of it in folds).
  Built on zimr's documentation pipeline: `src-fold`s generated from the source by `doc_folds` (the page cannot
  show code that no longer exists), short quotes checked by `doc_sync`, ASCII diagrams, API mapping tables, worked
  examples, the shared style from `docfmt`, `doc-gate`. A status table says per platform what exists and how it is
  verified; designed platforms get design chapters, marked as such; verification is a chapter about method.
  Sixteen chapters outlined. First the page with chapters 1-11 for the code that exists; then each backend stage
  updates its chapter in the same turn.

* **Oct 6 (later) - THE BACKEND TUTORIAL BEGINS: `src/notes/tutorials/backends-tutorial.html`, chapters 1 and 2.**
  * **Registered** in `doc_pages` (styled by `docfmt`, checked by `doc-gate`, published as `backends-tutorial.html`)
    and in `doc_folds_pages` (its code generated from the source). Not yet paired in `doc_sync`: the page quotes no
    code by hand; its diagrams are `class="sketch"`.
  * **Chapter 1, One engine, many GPUs:** the platforms and their APIs with the status table; why WebGPU on the
    web and Vulkan elsewhere; the layer stack (diagram); what differs between WebGPU, Vulkan and Metal (a table:
    destruction, synchronization, layouts, new memory, shaders, binding, presenting, clip-space Y, depth range).
  * **Chapter 2, The API and its hosts:** handles and descriptors; `host.zig`'s three facts; the compile-time
    switch; the web host and the bridge; the Vulkan host; the interface check - twelve declarations generated from
    `wgpu.zig`, `host.zig`, `bridge.zig` and `wgpu_vulkan.zig`.
  * **A comment fixed at its source:** `gpu_host`'s doc comment cited this plan by file name, which the fold would
    have shown; it now states the compile-time choice instead (same line count: the web build stays identical).
  * **Measured:** `doc-folds` fills all twelve blocks; `doc-pages` passes the doc gate; the web build identical.
  * **NEXT:** chapters 3 to 5 (objects and lifetimes, descriptions as bytes, one shader in three languages).

* **Oct 6 (later) - the backend tutorial: chapters 3 and 4.**
  * **Chapter 3, Objects and lifetimes:** handles and generations (`Pool`, a bit-layout diagram, stale handles
    reported by name); the browser's table (`jsBufferDestroy`, `tblRelease`: WebGPU keeps a destroyed object alive
    itself); destroying what the GPU may still use - the timeline semaphore numbering every submission, a diagram of
    a buffer destroyed when the counter passes its last use, `Destroy`, `deferDestroy`, `retireCompleted`,
    `executeDestroy`; commands not yet submitted (open encoders, pending uploads); releasing nothing (handle 0, as
    the browser; a stale handle is an error).
  * **Chapter 4, Descriptions as bytes:** why three descriptions cross the WebAssembly boundary as bytes; one
    encoding with two readers (diagram); a bind-group layout byte by byte (a worked example); the encoder, the
    byte-wise `BlobReader`, the allocation-free decoder; the encoders and decoders tested against each other.
  * **13 more blocks generated** (25 in all); the folded comments carry no plan or stage references; `doc-pages`
    passes the doc gate.
  * **NEXT:** chapter 5, one shader in three languages (Zig to SPIR-V, `spv2wgsl`, `spv_vulkan.legalize`, what
    validators differ on).

* **Oct 6 (later) - the backend tutorial: chapter 5, One shader, three languages.**
  * **The running example is `default_shapes_fs`,** the 2D renderer's fragment shader: its interface as Zig types
    (`Samplers`, `Outputs`), its body (`shaderMain`, which also runs on the CPU rasterizer); Zig to SPIR-V
    (`spirv32-vulkan`, a diagram of both destinations); SPIR-V to WGSL (the translator's passes and output checks as
    a diagram; `emitLoad` and the handle rule; `checkNoHandleValues`; the example's WGSL as a sketch); SPIR-V for
    Vulkan (`legalize` and a table of its five adjustments; `StorageUses`, the source-language constants,
    `RuntimeArrayStructs`); what validators differ on (Tint, naga, WebKit, spirv-val - a table, as facts).
  * **Comments rewritten at their source, because the folds publish them:** `checkNoHandleValues` (development
    history became a statement of the rule) and `ShaderOutput.spv` (a plan citation removed).
  * **Finding - `spv2wgsl.zig`'s comments carry development history:** `convertSpirvToWgslEntry`'s guard rails are
    explained through what went wrong ("That shipped...", "for months", "a day of bisecting a fluid", "I wrote it
    that way first..."). The technical content is valuable; the narrative is against the house style. The tutorial
    shows the function's passes as a diagram instead of folding it. PROPOSED: a cleanup pass over `spv2wgsl.zig`
    rewriting such comments as rules and reasons, after which the tutorial can fold the function.
  * **Measured:** 10 more blocks generated (35 in all); the page carries no plan, stage or history references;
    `doc-pages` passes the doc gate; the web build identical.
  * **NEXT:** chapters 6 to 8 (bringing up Vulkan, synchronization, resources).

* **Oct 6 (later) - SECOND REVIEW of the code and the tutorial (Simon: find bugs, ways to improve, simple idioms,
  the clearest comments).** The new headless test turned two of the findings into failing runs first.
  * **B1 - descriptor pool pages grew without bound under bind-group churn:** allocation tried only the newest
    page, so sets freed in older pages were never used again (a group created and destroyed per frame would add a
    page every 512 frames). Pages are now `DescriptorPage { pool, has_room }`: allocation tries the newest page with
    room first, a failed allocation marks a page full, a freed set marks it open again; a bind group remembers its
    page's index.
  * **B2 - a host without a window never reclaimed anything:** `retireCompleted` ran only at acquire. It now also
    runs after every submission.
  * **B6 - staging memory grew with the GPU's backlog** (found by the new test: 93 chunks of 4 MiB after 1300
    rounds of a 64-byte write). Without a window nothing paces submission, and every submission in flight keeps its
    chunk. Now a staging budget (4 chunks): with all of them held by unfinished submissions, an upload waits for the
    oldest and reuses its chunk - the pacing a windowed host gets from its frames in flight.
  * **B3 - a latent overflow:** the pipeline layout's array held 32 set layouts but was bounded by the device's
    `maxBoundDescriptorSets`, which a GPU may report above 32. Now bounded by zimr's own four groups.
  * **B4 - `spv_vulkan`'s insertion point** advanced past `OpName` and `OpSource` but not past the other debug
    instructions and annotations (`OpMemberName`, `OpString`, `OpModuleProcessed`, decoration groups, `OpDecorateId`,
    `OpDecorateString`): added to the opcode enumeration and to one arm that advances it.
  * **B5 - the tutorial's table said Metal's new memory is undefined:** Apple documents `makeBuffer(length:options:)`
    as zero-filled; textures are undefined. Corrected. Chapter 3.3 updated for B2.
  * **The test that found them:** `vk-host-test`'s churn check - 1300 rounds of create a bind group, write a buffer,
    destroy the group, submit - then `vulkan_host.statistics()` (pages, staging chunks, waiting destroys) must stay
    bounded. After the fixes: 1 page, 4 chunks, 0 waiting, no validation messages. The blobs are written by hand from
    their documented format, which also checks the documentation.
  * **Checked and right:** the Y flip with counter-clockwise front faces (framebuffer coordinates match WebGPU's
    exactly after the flip, and Vulkan's area formula makes a counter-clockwise-on-screen triangle positive); the
    pass's full barrier covering the uploads submitted before it; the chapter 5 WGSL sketch (group 1, bindings 0 and
    1, the real `textureSample` line).
  * **PROPOSED idioms (simple, not clever) - next, file by file, starting with `wgpu_vulkan.zig`:**
    1. A handle as `packed struct(u32) { slot_plus_one: u24, generation: u8 }`: the bit diagram becomes the type.
    2. The dirty bind-group slots as `std.bit_set.IntegerBitSet(max_bind_groups)`, not a `u8` and shifts.
    3. One format table, `formatInfo(format)` -> `{ vk format, texel bytes, aspect }`, replacing three switches that
       must agree (`textureFormat`, `texelSize`, `isDepthFormat`).
    4. `vk.bool32(value)` for Vulkan's 32-bit booleans, replacing `@intFromBool` and `vk.bool_true` noise.
    5. One `outOfMemory()` for the host's two dozen identical out-of-memory panics.
  * **PROPOSED comments - the clearest expression of each piece:**
    1. No plan citations in code comments (16 across the native files): each states its reason in place - the
       tutorial's folds publish them verbatim.
    2. Each host function opens with the WebGPU promise it keeps, then the Vulkan mechanism, then the edge cases.
    3. `wgpu_vulkan.zig`'s header becomes a short course in the host's few big ideas (one layout and full barriers,
       the timeline, the uploads command buffer, deferred destroys, staging and its budget) with a frame diagram.
    4. Invariants other code relies on are stated where they live (the retiring lists keep submission order; the
       staging budget depends on it).
    5. `spv2wgsl.zig`'s development history rewritten as rules and reasons, after which the tutorial folds
       `convertSpirvToWgslEntry`.

* **Oct 6 (later) - the idiom and comment pass, `wgpu_vulkan.zig`.**
  * **Idioms:**
    1. `Handle = packed struct(u32) { slot_plus_one: u24, generation: u8 }`: the pool's handle arithmetic is now
       `@bitCast` between the handle and its parts - the tutorial's bit diagram is the type (and chapter 3.1 shows
       it under the diagram).
    2. `GroupSet = std.bit_set.IntegerBitSet(max_bind_groups)` for a pass's dirty bind groups; this toolchain's
       bit set offers `empty` and `full` as values, so the field default is `.empty` and a pipeline change sets
       `.full`.
    3. `FormatInfo` / `formatInfo`: one table (Vulkan format, texel bytes, depth or not) replacing three switches
       that had to agree.
    4. `vk.bool32(value)` for Vulkan booleans set from a condition (in `vk.zig`'s hand-written head).
    5. `outOfMemory()`: one `noreturn` for the 22 identical out-of-memory panics, its doc saying why a GPU call ends
       the program there (the calls cannot return errors, as their browser twins cannot).
  * **Comments:**
    1. The file header rewritten as a short course: what the host is; KEEPING WEBGPU'S PROMISES ON VULKAN (ordering
       through GENERAL and full barriers, destruction on the timeline, write order through `uploads`, zeros, the Y
       flip); objects (`attachWindow` / `startHeadless`); the timeline; a frame, with a diagram; memory and the
       staging budget; the swapchain.
    2. Every plan citation in the file replaced by its reason (the module global's comment now says why a global:
       the calls are free functions with no context argument).
    3. Invariants where they live: the staging lists' docs (the retiring list keeps submission order, which
       `reclaimOldestStagingChunk` relies on); `retireCompleted`'s doc brought up to date (it reclaims command
       buffers, staging chunks and released objects, compacting in place).
  * **Measured:** `vk-host-test` green (1 page, 4 chunks, 0 waiting, no validation messages); both Windows programs
    build; the folds refreshed and the doc gate passes; the web build identical. Lint 0.
  * **NEXT:** the same pass over the other native files (`vk.zig`'s hand-written parts, `spv_vulkan.zig`,
    `gpu_abi.zig`, `native_os.zig`, `win32.zig`, `native_loop.zig`, `wgpu.zig`'s host section, `wgpu_app.zig`), then
    `spv2wgsl.zig`'s history-to-rules rewrite; then tutorial chapters 6 to 8.

* **Oct 6 (later) - the comment pass over the other native files.**
  * **Every plan citation gone from `vk.zig`, `spv_vulkan.zig`, `gpu_abi.zig`, `native_os.zig`, `win32.zig`,
    `native_loop.zig`, `host.zig`, `wgpu.zig` and `wgpu_app.zig`;** each comment now states its reason.
  * **`spv_vulkan.zig`'s header** narrated an audit ("an audit ... found ... three gaps") and listed three
    adjustments; it now states the rules: the five adjustments `legalize` makes (DepthReplacing; NonWritable on
    provably read-only vertex-stage buffers, escaped ones left to the vertex-stores feature; pointer strides; the Zig
    source language; unused runtime-array structs) and its three refusals, keeping the section-layout diagram.
    The kompute-helpers comment says why such a module cannot run natively (`spv2wgsl` replaces those calls; Vulkan
    has no such step) instead of citing a decision.
  * **`vk.zig`'s header** brought up to date: five dispatch tables (the window system's apart, since a host without a
    window has none of those commands), `loadDispatch` for any table, the library opened by `native_os.zig`.
  * **`wgpu.zig`'s three "STRUCTURE-PLAN S2 (t1177)" markers** became section headers stating what they mark
    (the render-pass, compute-pass and storage-buffer namespaces, their one-way dependencies); `wgpu_app.zig`'s
    "S4: these were ..." note states what the code is (draw3d's mesh helpers, re-exported).
  * **Line counts kept in the web-built files** (`wgpu.zig`, `wgpu_app.zig`, `gpu_abi.zig`), so `@src()` lines and
    the web build stay byte-identical.
  * **Measured:** `spv_vulkan` 10/10; `vk-host-test` and the shader probe (50/50) green; both Windows programs build;
    the folds unchanged and the doc gate passes; the web build identical. Lint 0.
  * **NEXT:** `spv2wgsl.zig` - its development history rewritten as rules and reasons, then the tutorial folds
    `convertSpirvToWgslEntry`; then tutorial chapters 6 to 8.

* **Oct 6 (later) - THIRD REVIEW, of the last few turns' code (Simon: "make it perfect").**
  * **B7 - repeated large writes grew staging memory without bound.** A write larger than a standard chunk always
    got a new dedicated chunk, which went to the free list and was never used again (`stage` reused free chunks
    only for writes of at most 4 MiB), and the budget never applied. Now `stagingChunkFor` chooses, in order: the
    chunk being filled; a free chunk that fits (`takeFreeStagingChunk`, the smallest that fits); with the budget
    spent, a chunk freed by waiting for the oldest submission (`waitForOldestStagingChunk`); else a new one.
    PROVED by the new `large` check (24 writes of 6 MiB): the old behaviour, reintroduced for the experiment, ends
    with 28 chunks and FAILS; the fix ends with 5, the budget plus one.
  * **Three doc comments had been displaced by the insertions of the last turns** - a new declaration placed between
    a function's doc comment and the function takes the doc: `stage`'s doc sat on the staging reclaimer,
    `imageBarrier`'s on `single_color_range`, `checkGaps`' (spv_vulkan) on `StorageUses`. All three restored
    (recovered from the backups); the compiler cannot see this, only reading does.
  * **52 functions documented** - every helper and every entry point of `wgpu_vulkan.zig` (each entry point names the
    WebGPU call it answers, and points at the function doing the work); only the unwritten-call stubs remain without
    one, documented as a group by their section. `createSwapchain` had never had a doc: it now states its choices
    (format, FIFO, one image more than the minimum, the extent rule, the usages, minimized windows, stable views).
  * **One name per idea:** `TextureSlot.texel_size` became `texel_bytes`, as in `FormatInfo`.
  * **The test reads the host's budget** (`staging_chunk_budget`, now public) instead of a copy of its value; the
    header's memory paragraph corrected (chunks are 4 MiB or exactly the size of a larger write; reuse by fit).
  * **Measured:** `vk-host-test` (clear; churn: 1 page, 4 chunks; large: 5 chunks; no validation messages); the shader
    probe 50/50; `spv_vulkan` 10/10; both Windows programs build; four folds refreshed, the doc gate passes; the web
    build identical. Lint 0.

* **Oct 6 (later) - COMPARED WITH MACH, design point by design point (Simon: "are the differences justified?").**
  Read from mach's `sysgpu/vulkan.zig` and `core/`, not recalled.
  * **Same choices:** the Y flip (a negative-height viewport from the bottom - mach also flips `setViewport`'s y, which
    zimr must do when it implements that call); one device-memory allocation per resource (neither sub-allocates);
    choosing a supported composite-alpha mode; one thread on Windows (mach's render-thread hook is empty there, so
    it shares zimr's frozen content during a window drag).
  * **zimr differs, and is right to:**
    1. **Zero-initialized memory** - mach fills and clears nothing, a WebGPU conformance gap; zimr fills buffers and
       clears textures, as the web does.
    2. **Descriptor sets** - mach creates a WHOLE POOL per bind group (sized for `256 / entries` sets, one set
       used); zimr shares pool pages and reuses freed sets.
    3. **Present semaphores** - mach signals one semaphore for every present (a reuse the specification forbids);
       zimr has one per image.
    4. **Staging** - mach's upload pages recycle but have no budget (the unbounded growth zimr fixed as B6/B7).
    5. **An out-of-date swapchain at acquire** - mach drops the frame; zimr rebuilds and acquires again.
    6. **DPI** - zimr applies Windows' suggested rectangle; mach does not.
    7. **Validation as a gate** - zimr counts messages and reports them at exit (and the headless test requires
       zero); mach's layers are optional and uncounted.
    8. **A memory-allocation ceiling** - zimr fails by name at 80% of `maxMemoryAllocationCount`; mach would meet
       the driver's limit.
  * **zimr differs by design, with a known cost:**
    1. **Bindings** - mach depends on vulkan-zig (the whole API, generated at build time); zimr declares the subset
       it calls, ABI-checked against the official headers: no dependency, at the price of regenerating to add a
       command.
    2. **Shaders** - mach compiles WGSL with its own compiler (to SPIR-V, HLSL, MSL); zimr writes shaders in Zig (they
       also run on the CPU) and translates SPIR-V to WGSL. Each follows from what its API accepts.
    3. **Backends** - mach has Vulkan, D3D12, Metal and OpenGL; zimr has the browser's WebGPU and Vulkan, so Windows
       runs Vulkan, not D3D12 (sound on NVIDIA, AMD and Intel; weaker on Windows-on-Arm drivers).
    4. **Synchronization** - mach tracks every resource's state and emits precise barriers with optimal layouts;
       zimr keeps GENERAL and full barriers: correct by construction and far simpler, at a performance cost
       (serialized passes; some GPUs compress less in GENERAL) still to be measured. If it is large, mach's tracker
       is the model.
    5. **Lifetimes** - mach reference-counts objects and command buffers; zimr numbers submissions and destroys
       after the last one: simpler, slightly more conservative.
    6. **Present mode and GPU choice** - mach offers FIFO, mailbox and immediate, and WebGPU's power preference;
       zimr presents FIFO (as `requestAnimationFrame` paces the web) and ranks GPUs by type, `ZIMR_GPU` overriding.
       Mailbox/immediate (for measuring) and power preference are small additions when wanted.
    7. **Errors** - mach returns them through its API; zimr ends the program with a named failure. Right while
       porting; device loss will need a recovery path for shipped programs.
  * **NOT justified everywhere - ACTION: the Vulkan 1.3 requirement.** zimr requires dynamic rendering,
    synchronization2 and timeline semaphores as core features; mach builds render passes and framebuffers and runs
    on Vulkan 1.1. Every desktop driver zimr targets offers 1.3, but a large share of Android devices in use offer
    only 1.1. Before Android: either accept 1.3-only Android (newer devices), or accept the three as EXTENSIONS on
    1.1/1.2 (`VK_KHR_dynamic_rendering`, `VK_KHR_synchronization2`, `VK_KHR_timeline_semaphore` - widely available,
    and the host's code is unchanged by the switch). Decision deferred to the Android stage, with this recorded.
  * **Other follow-ups:** device-memory sub-allocation before object counts approach the allocation limit (neither
    host has it); `setViewport` with mach's y flip; measuring the full-barrier cost (S7).

* **Oct 6 (later) - `spv2wgsl.zig`: development history rewritten as rules and reasons.**
  * **`convertSpirvToWgslEntry`'s guards** now each open with the invariant they keep, then the rule and its reason:
    hard checks (no non-finite constant, no handle held as a value); every merge variable assigned (a phi's `var`
    read but never assigned silently reads 0 - loops run once - which kernels without loops never show); every
    storage buffer the SPIR-V uses still used (a dropped block takes its memory accesses with it; membership not
    count; against the ORIGINAL module, since the fold is what drops the block); the `_N` closure diagnostic. The
    narrative (which kernels broke, for how long, how it was found) is gone; every technical fact stayed. The tutorial
    now folds the function (chapter 5.3).
  * **Documentation bugs found and fixed:** `mergeBlockPhiWouldOrphan`'s doc described the rule its code had dropped
    (fold unless the merge is BOTH phi-carrying AND a header) while the code refuses any phi-carrying merge - the doc
    now states the code's rule, both failure modes, and its cost (unfolded `if (73u == 73u)` guards); two more
    DISPLACED docs (`emitFunctionBody`'s doc sat below it, `appendValueOperands`' 150 lines above it, behind
    `OpShape`), both also describing the deleted walker - returned to their owners and corrected; doc comments for
    imports that no longer exist (folded into namespaces) were silently documenting the next section - replaced by a
    plain comment on the file's structure; the block-emission doc merged two eras - rewritten as one.
  * **Dangling references:** four cited documents do not exist (`spv2wgsl_ir_rewrite.md` thrice,
    `docs/zig-spirv-quirks.md`, `docs/tint-vs-spv2wgsl.md` twice, `docs/spv2wgsl-flow-guards.md`), and
    `finishing_webgpu.md` moved to the archive: each comment made self-contained instead. Plan and phase citations
    (`spv2wgsl-rewrite-plan.md`, `spirv_2307_decorations_plan.md`, "(F2; complete)", "Phase 1.1") removed. Kept: the
    pointer to the existing `zig-spirv-compiler-interface.md`, and the user-facing message citing the existing
    `spv2wgsl_dropped_block.md`. A user-facing error's history ("clamp01/step used to be") became an example.
  * **Measured:** lint 0 before and after; the folds and the doc gate pass; the web build identical (the translator's
    output unchanged).
  * **NEXT - the stale-walker layer:** 37 comments still describe the deleted recursive walker as current (state
    fields "set for the duration of the walker", "the walker's emitTerminator"), beside 8 phase labels and 5 turn
    numbers, in the namespaces folded in from sub-files. Each needs the structured IR's actual mechanism worked out,
    so it is a careful pass of its own. Then tutorial chapters 6 to 8.

* **Oct 6 (later) - `spv2wgsl.zig`: the deleted walker's dead mechanism removed, and its comments brought to the
  present.**
  * **Dead code:** the walker's phi-assignment injection had stayed wired up after the walker was deleted. Every
    function still built a map of (value, predecessor) pairs per phi, `emitFunctionBody` published it in
    `State.phi_assigns_ref` - and the structured-IR path, the only path, set it to null for the whole emission "for
    the legacy fallback path", which no longer exists; `emitBlockBodyOnly`'s injection branch could never run. Removed:
    the `PhiAssignment` / `PhiAssignList` / `PhiAssignMap` types, the state field, `emitFunctionBody`'s parameter,
    the save-and-restore, the injection branch, and the map-building half of the per-function loop (its other half,
    naming parameters and phis, stays - the rest of the translator relies on those names).
  * **PROVED BY A DIFFERENTIAL CORPUS CHECK:** the translator binary from before the change, and the one after, run on
    all 55 SPIR-V modules in the build cache - 55 of 55 byte-identical WGSL. `spv2wgsl`'s own 60 tests pass.
  * **Comments that described the deleted walker as current** (37) rewritten to the structured IR's actual mechanism,
    with the 8 phase labels and 5 turn numbers. Three more docs CONTRADICTED their code: `IrBuildUnsupported` ("not a
    hard failure: the caller falls back to the legacy walker" - it is a hard error), the unbuilt-loop-shapes note (the
    same fallback), and `isEntryFunctionContext` ("a stub ... returning false matches the safe default" - it returns
    `is_current_entry`). The defensive branch that reported `IrBuildUnsupported` "to degrade gracefully" now states
    the remaining reason: the error names missing support instead of blaming the input.
  * **Measured:** no walker, phase or turn reference left; lint 0; the web build identical; the folds unchanged, the
    doc gate passes.
  * **NEXT:** tutorial chapters 6 to 8 (bringing up Vulkan, synchronization, resources).

* **Oct 6 (later) - the backend tutorial: chapters 6 and 7.**
  * **Chapter 6, Bringing up Vulkan:** the loader and its dispatch tables (a diagram of the levels; `loadDispatch`
    open, `SurfaceDispatch` as an example table); declarations that can be trusted (why a wrong hand-declared
    structure fails silently, and the compile-time check against the official headers; `InstanceCreateInfo`,
    `check`); the instance, the validation layer and the messenger (`MessageCounts`, `debugMessage`,
    `createInstance`; `ZIMR_VK_VALIDATE`); choosing a GPU (`suitableQueueFamily`, `typeRank`, `chooseGpu`;
    `ZIMR_GPU`); the device and a table of why each enabled feature is needed (`createDevice`); memory types
    (preferred then required properties, the allocation ceiling; `memoryTypeIndex`, `allocateMemory`); the whole
    sequence (`bringUp` open).
  * **Chapter 7, Synchronization:** what WebGPU does for you (a GPU overlaps work and caches writes - a diagram of a
    pass reading a texture before the previous pass wrote it, and the barrier that orders them; execution and
    memory dependencies, layouts); one layout and full barriers (`fullBarrier` open, `imageBarrier`; the cost, and
    precise tracking as the path if it matters); submissions and the timeline (`waitTimeline`, `submitBatch`);
    writes on the queue (`uploadsCommandBuffer`, a diagram of a batch; `beginCommandBuffer`); a frame - acquire,
    render, present - with its three semaphore handshakes, a diagram, frames in flight, and why present semaphores
    are per image (`acquireImage`, `presentImage`).
  * **22 more blocks generated** (58 in all); two statements made exact against the code and the specification
    (which batch waits for the acquire; what robust buffer access guarantees). The doc gate passes.
  * **NEXT:** chapter 8 (resources), then 9 to 11.

* **Oct 6 (later) - the backend tutorial: chapter 8, Resources.** Buffers (usage flags with copy always allowed,
  device-local or mapped-for-life memory, the zero-fill through `uploads`; `bufferUsageFlags`, `createBuffer`);
  staging memory (chunks, their cycle as a diagram, the chunk choice and the budget; `stagingChunkFor` open,
  `takeFreeStagingChunk`, `staging_chunk_budget`, `waitForOldestStagingChunk`, `stage`); ONE WRITE FOLLOWED (a worked
  example: 64 bytes staged at an aligned offset, copied in `uploads`, consumed by submission #57, the chunk
  retiring and coming back; `writeBuffer`); textures (the format table, depth24plus as a 32-bit float, the one
  layout change and the zero-clear; `formatInfo` open, `createTexture`, `createTextureView`); writing a texture
  (row pitch in bytes against texels; `TextureRegion`, `writeTexture`); samplers and shader modules
  (`createSampler`, `createShaderModule`). 15 more blocks (73 in all); the doc gate passes. Readback waits for its
  native implementation. NEXT: chapters 9 to 11.

* **Oct 6 (later) - names for the C-interop types (Simon: "these concepts feel very foreign ... find the best way to
  write all this").** The function-pointer types were spelled inline wherever they appeared - `get_proc_address: *const
  fn (Handle, [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void`. Now each recurring concept has a name,
  documented with the idea it stands for:
  * **`vk.PFN_vkVoidFunction`** - "a command as a lookup returns it, before it is cast to its real type" - the C
    headers' own name, so `vk-abi-check` verifies it like every other `PFN_`. The generator now emits the two
    lookups' return types as `?PFN_vkVoidFunction`.
  * **`vk.CommandLookup(Handle)`** - what `vkGetInstanceProcAddr` and `vkGetDeviceProcAddr` are (an instance or a
    device and a name in, the command out); `PFN_vkGetInstanceProcAddr = CommandLookup(Instance)`, and
    `loadDispatch(Table, Handle, lookup: CommandLookup(Handle), handle)`.
  * **`native_os.VulkanLibrary.get_instance_proc_address` is typed** (`vk.PFN_vkGetInstanceProcAddr`): the operating
    system hands the entry point out untyped, and it gets its type once, where it arrives - the host's cast is gone.
  * **`native_loop.UpdateFunction`**, documented with why it is a C function (the browser's JavaScript calls the same
    export).
  * **A glossary of C types in Zig** in `vk.zig`'s header (`?*const T`, `[*]const T`, `[*:0]const u8`,
    `?*const anyopaque`, `*const fn (A) callconv(.c) R`, and what `callconv(.c)` means), and in tutorial 6.2 as a
    table; tutorial 6.1 introduces the two names before `loadDispatch`.
  * **Measured:** both ABI checks pass; both Windows programs build; `vk-host-test`, the shader probe (50/50) and
    `native_os`'s tests pass; the web build identical; the folds filled, the doc gate passes. Lint 0.

* **Oct 6 (later) - the backend tutorial: a vocabulary (1.5) and chapter 9, written for a first reading.** Simon:
  "make all this understandable by mortals like me". The rule from here: every new idea opens with one plain
  sentence, every term is defined where it first appears, and each section carries a diagram and a worked example.
  * **1.5 A vocabulary:** 22 terms (physical device to validation layer), each in one plain sentence with a link to
    the section that explains it.
  * **Chapter 9, Bindings and pipelines:** how a shader finds its resources (group and binding; a layout as the blank
    form, a bind group as the form filled in; a diagram mapping the shapes shader's WGSL bindings to Vulkan's sets);
    bind groups as descriptor sets (pool pages and their reuse); pipeline layouts (empty slots); a render pipeline as
    the path a triangle takes through the GPU, each stop with the setting that controls it; blending, worked through
    (half-transparent red over blue, computed); which way is up (one triangle's corners onto an 800 x 600 target with
    and without the flipped viewport, and why the front-face rule survives the flip). 11 more blocks (86 in all); the
    doc gate passes.
  * **NEXT:** chapters 10 (render passes and draws) and 11 (windows and surfaces), in the same manner.

* **Oct 6 (later) - the backend tutorial: chapter 10, Render passes and draws.** What a pass is (targets fixed for
  a stretch of drawing; load or clear, store or discard, depth cleared to 1.0 and why, resolve - a diagram of the
  two ends); beginning a pass (`RenderPassRequest`, `beginRenderPass`: the full barrier first, dynamic rendering,
  the flipped viewport, the scissor); inside a pass (why bind groups are recorded and bound at the next draw:
  WebGPU allows a group before its pipeline, Vulkan binds against a pipeline layout; `GroupSet`, `RenderPassSlot`,
  `render_pass_set_pipeline`, `render_pass_set_bind_group`, `bindDirtyGroups`, `render_pass_draw_indexed`); ending a
  pass; ONE FRAME FOLLOWED - `hello_world`'s frame from the engine's calls through the host to the Vulkan commands,
  checked against the engine's real sequence (`gpu_iface` begin and end of frame; the 2D renderer's projection and
  vertex writes during the frame, landing in `uploads`). One fold's anchor fixed (a three-line signature); 9 more
  blocks (95 in all); the doc gate passes. NEXT: chapter 11, Windows and surfaces.

* **Oct 6 (later) - LESSONS FROM VULKAN-ZIG (Snektron's binding generator; Simon: inspiration, not vendoring).**
  Read from its source and examples.
  * **What it does:** generates the WHOLE API from `vk.xml` with a Zig program, usually at build time (the registry
    a build dependency); renames (`createInstance`, `PfnCreateInstance`); generates WRAPPERS - each command's exact
    error set from the registry, out-parameters returned, count-and-pointer pairs as slices, extra success codes
    returned; PROXIES (a handle with its table, for method calls); FLAGS AS PACKED STRUCTS OF BOOLS with set
    operations (`.{ .transfer_dst_bit = true }`); `Version` as a packed struct; struct defaults for `sType` and `pNext`
    only (every other field must be written); a CALLING-CONVENTION CONSTANT (hardfloat AAPCS-VFP on 32-bit ARM Android,
    stdcall on 32-bit Windows, C elsewhere).
  * **Already the same in zimr:** handles as non-exhaustive enums (pointer-sized when dispatchable, `u64` otherwise);
    `sType`/`pNext` defaults; pointer kinds from the registry's metadata; one dispatch table per level, loaded by name.
    Its swapchain example keeps per-image semaphores (swapping the acquire semaphore into the image's slot) - as
    careful as zimr's frame protocol, nothing to change there.
  * **THE LESSON THAT MATTERED - ADOPTED: zimr's generator was not in the repository.** `vk.zig` had been generated by
    a script and a hand-made translate-c reference living in the sandbox, spliced by throwaway scripts: nobody else
    could have regenerated it. Now `tools/vk_gen.py` (496 lines; the repo already keeps Python tools in
    `src/notes/scripts/`): `python3 tools/vk_gen.py <Vulkan-Headers>` makes the translate-c reference itself, reads
    `registry/vk.xml`, generates the subset its lists declare, splices it between `vk.zig`'s hand-written parts, and
    applies the two hand edits as declared data. PROVED: run on the unchanged lists, it reproduces `src/vk.zig` byte
    for byte (and again after the header changed: hand-written parts are preserved). `vk.zig`'s header now says how to
    add a command (the tool's lists, the tool, `vk-abi-check`).
  * **PROPOSED next, cheap:** the calling-convention constant (`vk.call_conv`, emitted by the generator in place of
    `callconv(.c)`): identical on every target zimr builds today, correct on 32-bit ARM Android should it ever be one.
  * **PROPOSED with a later regeneration:** flags as packed structs per bitmask (`ImageUsageFlags = packed
    struct(Flags) { transfer_src: bool = false, ... }`) - type-safe (no image bits where buffer bits belong) and
    readable, as `gpu_abi`'s usage structs already are; `Version` as `packed struct(u32)` - both from the registry's
    bitmask and bit-position data, through the same tool. A Zig port of the tool is optional.
  * **CONSIDERED, NOT ADOPTED:** the whole API at build time (it makes the registry a dependency of every build; a
    committed subset, checked against the headers, stays small, auditable and dependency-free); renaming commands
    (the spec's names keep the code searchable against the specification, and the tutorial reading like it);
    generated wrappers - error sets, returned out-parameters, slices (the most complex part of vulkan-zig; the host
    ends the program on any failure with a named error, and raw commands mirror the spec the tutorial teaches from);
    proxies (a layer the host does not need); defaults for `sType`/`pNext` only (zimr defaults every field to zero and
    relies on the validation layer, which the tests require clean).

* **Oct 6 (later) - THE BINDING GENERATOR GOES TO ZIG, closer to vulkan-zig (Simon: "we don't want python tools in
  zimr ... the binding generator should be in zig ... follow vulkan-zig a bit more closely").**
  * **`tools/vk_gen.py` removed;** `vk.zig`'s header no longer names a tool until the Zig one exists.
  * **The design, after vulkan-zig's generator** (`xml.zig` -> `registry.zig`/`parse.zig` -> `render.zig`): a Zig
    tool, `tools/vk_gen.zig`, run on demand - `zig build vk-gen -Dvulkan-registry=<path to vk.xml>` rewrites
    `src/vk.zig`, the build itself never needing the registry. Its stages, as simple static functions over arrays:
    1. **Read the XML** with zimr's own `codecs.xml` (one XML reader in the code base), extended for this.
    2. **Build a registry model:** types (structures, unions, handles, enumerations, bitmasks, function pointers),
       their members as C declarations (const-ness, pointer depth, array bounds, the `len` and `optional`
       metadata), commands and parameters, enumerants with their values - TAKEN FROM THE REGISTRY, as vulkan-zig
       does (`value`, `bitpos`, an extension's `offset` with its number; the API constants' C expressions such as
       `(~0U)`), so `translate-c` stays the ABI check's independent oracle and the generator needs only `vk.xml`.
    3. **Render** the subset, then splice it between `vk.zig`'s hand-written parts (the hand edits declared as data).
  * **Acceptance: byte-identical.** The Zig tool must reproduce today's `src/vk.zig` exactly (the Python tool's
    output, proved earlier) before any output change; then `vk-abi-check`.
  * **Then, one by one, each with its own regeneration and check:** `vk.call_conv` (vulkan-zig's calling-convention
    constant); flags as packed structs per bitmask; `Version` as a packed struct; and a selection closure (list the
    COMMANDS - plus the structures chained through `pNext` - and let the registry supply every type they need,
    instead of maintaining STRUCTS and ENUMS by hand).
  * **Step 1 done - `codecs.xml` reads mixed content.** `vk.xml` writes C declarations as text interleaved with
    elements (`<member>const <type>void</type>* <name>pNext</name></member>`); the reader kept only an element's
    first text segment. Now ElementTree's model: `text` is the text before the first child, a new `tail` the text
    after an element's end tag - together they give the content in order. A test pins it on two real `vk.xml`
    members (a pointer; an array bounded by an enumerant). `zig build test-fast`: 23/23 steps, 1281 tests passed
    (the URDF and MJCF parsers, which read through the same reader, unchanged). Lint 0.
  * **NEXT:** step 2, the registry model read from `vk.xml` (with tests on real excerpts).

* **Oct 6 (later) - the Zig generator, step 2: the registry model (`tools/vk_gen.zig`, `zig build vk-gen-test`).**
  * **The subset lists, transcribed** programmatically from the Python generator's (89 structures, 4 opaque, 33
    enumerations - `StructureType` computed from the structures' `sType` values - 71 constants, 2 special, 88 commands
    in five levels), as typed Zig arrays (`Enumeration`, `CommandLevel`, `SpecialConstant`).
  * **The model:** `Registry` over a `codecs.xml` document - types by name (first definition), commands by name
    (Vulkan definitions only), enumerants with how each value is given (`EnumerantValue`: a number, or an alias), the
    API constants' C text, the 64-bit flag-bits enumerations. Map types named (`ElementIndex`, `EnumerantIndex`).
  * **Values from the registry alone:** `value` (decimal or hex), `bitpos`, an extension's block (`1000000000 + (N -
    1) * 1000 + offset`, negated for `dir="-"`, `extnumber` naming the owner of a promoted enumerant), aliases
    followed; held as `i128` (a 64-bit flag's bit 63 cannot overflow).
  * **A latent bug of the Python generator found on the way:** three commands (`vkCreateDevice`,
    `vkCreateGraphicsPipelines`, `vkCreateComputePipelines`) have a Vulkan and a Vulkan SC definition, and its
    last-wins indexing took the Vulkan SC ones. Harmless as it happened (the only difference, `pipelineCache`'s
    optional-ness, does not change a handle's Zig type), but the Zig model selects by `api`.
  * **Tests on real excerpts** (2/2): direct values, bit positions (one past 32 bits), extension 2's block giving
    `VK_ERROR_OUT_OF_DATE_KHR = -1000001004` as the header does, an alias, a promoted enumerant, a string constant
    that is not a number; a handle named by its child, the first of two definitions kept, the Vulkan SC variant
    skipped, an alias command, API constants as text. Lint 0.
  * **NEXT - step 3:** rendering (types, members, defaults, enumerations, constants, function pointers, tables) and
    the splice, `main`, `zig build vk-gen -Dvulkan-registry=...`; acceptance: today's `src/vk.zig` reproduced byte
    for byte from the real registry.

* **Oct 6 (later) - THE ZIG GENERATOR IS COMPLETE: `zig build vk-gen -Dvulkan-registry=<vk.xml>` reproduces
  `src/vk.zig` BYTE FOR BYTE.** No Python left in the Vulkan tooling.
  * **Step 3, rendering:** one Zig function per function of the old generator (`snakeCase`, `baseType`, `zigType`,
    `defaultFor`, `declarationOf`, the four renderers), the splice with its markers and hand edits as named data,
    formatting in-process with `std.zig.Ast` (the `zig fmt` renderer, no subprocess), `main`, and the `vk-gen` step
    (`b.addFail` without the option, like `vk-abi-check`).
  * **Two things the real registry taught:** it parses whole through `codecs.xml` (2.5 MB); and recent registries
    write a function-pointer type's name inside `<proto>` - the old generator searched descendants (ElementTree's
    `.//name`), so the port does too (`descendantText`, now in a test).
  * **A TRAP, recorded so it is not repeated: the linter's `--fix` deletes unused private declarations.** Run on the
    registry half alone, before anything referenced the subset lists, it removed all of them (and their types); the
    tests, which never touched the lists, still passed. Restored from the transcription. Since then: `--fix` only on
    a copy, comparing the declaration names before and after.
  * **The lists one name per line** (adding a command is a one-line change); std functions bound at file scope; the
    splice's markers named and documented.
  * **Measured:** regenerated twice, byte-identical both times (the second with `vk.zig`'s header now naming the tool);
    `vk-gen-test` 2/2; `vk-abi-check`; both Windows programs (208/208). Lint 0 on the tool, `vk.zig`, the build.
  * **NEXT, each its own regeneration and check:** `vk.call_conv`; flags as packed structs; `Version` as a packed
    struct; the selection closure. Then the tutorial's chapter 11.

* **Oct 6 (later) - vulkan-zig's naming, steps 1 and 2 (Simon: "Go").**
  * **Step 1, `vk.call_conv`:** Vulkan's calling convention (`VKAPI_CALL`/`VKAPI_PTR`) - C's own, stdcall on 32-bit
    Windows, hard-float AAPCS-VFP on 32-bit ARM Android - used by every generated command type, `PfnVoidFunction`,
    `CommandLookup`, the callback type and the three debug callbacks (host, S1 program, shader probe). Identical on
    every target zimr builds today; verified on its own (ABI check, Windows 208/208, headless test, probe 50/50).
  * **Step 2, Zig names for commands:** table fields drop `vk` and start lower-case, as Zig functions do (`std.Io`'s
    vtable precedent): `self.device_dispatch.createImage(...)`; function-pointer types are `Pfn` and the name
    (`PfnCreateImage`; `PfnVoidFunction`, `PfnGetInstanceProcAddr`, `PfnDebugUtilsMessengerCallbackEXT`). The
    generator keeps the registry's C names in its lists and converts on output (`commandTitle`, `commandField`); the
    loader turns each field's name back into the C name it looks up, at compile time (`commandName`); the ABI check
    pairs `PfnX` with the headers' `PFN_vkX`. 187 field uses renamed (host 114, S1 program 55, probe 18) and the
    probe's own table; `vk.zig`'s NAMES section states the rule; tutorial 6.1 too.
  * **One error on the way:** `commandName` computed its string with `comptimePrint` over a call to `toUpper` -
    not evaluated at compile time without `comptime`, which the ABI check (never instantiating the loader) did not
    catch and the host builds did.
  * **Measured:** regenerated (and again: unchanged, the hand-written loader preserved); `vk-gen-test`;
    `vk-abi-check`; both Windows programs (208/208); `vk-host-test` (no validation messages); the probe (50/50); the
    folds and the doc gate. Lint 0 on the seven files.
  * **NEXT:** step 3, flags as packed structs (fields without `_bit`, as `gpu_abi`'s) and `Version` as a packed
    struct; then the selection closure.

* **Oct 6 (later) - step 3a: flags as packed structures, generated beside the old constants.**
  * **The model:** each flag-bits enumeration's bits, from its own block and from what Vulkan's features and enabled
    extensions add (`extends`); aliases and disabled extensions left out (`recordFlagBit`, `supportsVulkan`); each
    enumeration's flags type (`requires`, or `bitvalues` for 64-bit flags).
  * **The rendering:** the flags types the subset's members and parameters use (a flag-bits type standing for one bit
    counts: `VkSampleCountFlagBits samples`) - 39 - each a `packed struct(Flags)` or `(Flags64)` with a `bool` per
    bit at its position and `_reserved_bit_N` between. Field names: the prefix, `BIT` and the enumeration's own
    vendor tag left out (`transfer_dst`), an extension's bit keeping its tag (`fragment_density_map_ext`), keywords
    and digits quoted (`@"opaque"`, `@"error"`, `@"4"`). Reserved flags types (`VkDeviceCreateFlags`) stay `Flags`.
  * **The oracle:** the old bit constants, proved equal to the headers, against the new structures - 58 compile-time
    checks generated into `vk.zig` (`QueueFlags{ .graphics = true }` is `queue_graphics_bit`); every build of
    `vk.zig` ran them, and all passed. They leave with the constants in 3b.
  * **Found on the way:** the check messages first embedded quoted field names (`@"opaque"`), which ended their
    strings early - the generator's in-process format refused the output and wrote nothing; it now prints each parse
    error's source line, which named the cause at once.
  * **Measured:** `vk-gen-test` 3/3 (a flags test on the excerpt: gathering, every naming case, placement);
    `vk-abi-check`; `vk-host-test`; the probe (50/50); both Windows programs. `vk.zig` 2441 -> 4166 lines (complete
    flags, as vulkan-zig's). Lint 0 on the tool and `vk.zig`.
  * **NEXT - 3b:** members and parameters typed with the structures; the host's 77 flag expressions rewritten; the bit
    constants and the checks retired; then `Version`.

* **Oct 6 (later) - REVIEW of the generator and its surroundings (Simon: "Review").** Ten findings, all fixed;
  none changed the output (regenerated twice after the fixes: byte-identical).
  1. **Quoting covered 12 keywords** - the Python generator's list. Zig has ~50, and primitives (`bool`, `null`,
     `u8`) cannot be bare names either; with every registry bit now emitted, a future `INLINE` or `EXTERN` bit
     would have produced code that does not compile. Now `std.zig.isValidId` and `std.zig.primitives.isPrimitive`
     decide (`quotedIfNeeded`).
  2. **Vulkan SC filtering compared `api == "vulkansc"`** for members and parameters (a list would slip through), and
     types were indexed with no API filter at all (first definition wins - an SC variant first would win). Now
     `appliesToVulkan` everywhere.
  3. **Return types fell back to the raw C name** (a command returning `VkBool32` would have emitted `VkBool32`).
     Now `returnTypeOf`, through `baseType`.
  4. **The splice failed silently** - a missing hand-edit target or marker gave a bare `MalformedOutput`. Now
     `replaceOnce` and `findMarker` name the text.
  5. **A bit past its type's width reported `UnknownType`.** Now `UnexpectedRegistry`.
  6. **`renderConstants` assigned an `undefined` through a for/else chain.** Now `constantValue`.
  7. **`addLine` took `anytype` without a `require`.** Now `requireFormatTuple`, with its comptime test.
  8. **A duplicated section header** (left from restoring the lists).
  9. **The main renderers had no unit test** - only the byte-for-byte reproduction. `renderStructure` and
     `renderCommandType` split out of their loops, and tested on the excerpt: a structure exercising every default
     (`sType`, null pointer, zero, array, an API-constant bound, a null handle) with its Vulkan SC member left out; an
     alias command rendered with the Vulkan definition's parameters. A quoting test too.
  10. **`vk.zig`'s NAMES section** did not mention the flags structures, and earlier edits had left ragged lines -
     described and reflowed.
  * **Reviewed and sound:** `codecs.xml`'s mixed content (`placeText`), the loader's `commandName`, the ABI check's
    `Pfn` mapping, the `vk-gen` and `vk-gen-test` steps.
  * **Measured:** `vk-gen-test` 6/6; regeneration byte-identical; lint 0 on the generator, `vk.zig` and `codecs.zig`.

* **Oct 6 (later) - step 3b: the flags structures are the API.**
  * **Generator:** `baseType` maps a flags type with named bits (or one bit of it) to its structure; reserved flags
    types stay `Flags`. The constants list keeps the limits and special values (9, plus `whole_size` and
    `lod_clamp_none`); the 58 bit constants, the four zero values (`.{}` now) and the transitional checks are gone.
    The registry queries `categoryOf`, `resolveAlias`, `bitsOfFlags` and `flagsTypeOf` sit together before rendering.
  * **`vk.zig`:** `hasAllFlags` and `mergeFlags` (the two bitwise questions code asks of flags, through the backing
    integers); the debug messenger's callback typed (`DebugUtilsMessageSeverityFlagsEXT`, ...); NAMES updated.
  * **Host, S1 program, probe:** every flag expression a literal or a field - `.{ .transfer_src = true, .sampled =
    usage.texture_binding }`, `family.queue_flags.graphics`, `message_severity.@"error"`, `.{}` for none.
    `bufferUsageFlags`, `stageFlags`, the texture's usage became single struct literals; `sampleCountFlags` now
    serves textures and pipelines (a pipeline's count was passed through unchecked); `allocateMemory`'s doc lost a
    plan reference.
  * **The compiler found every site the inventory missed** (literal `0`s for flags parameters, `aspectOf`'s return
    type, a flags union, the pipeline's sample count, Windows-only S1 code).
  * **Measured:** `vk-host-test` with no validation messages (the validation layer checks every flag the host
    passes); the probe (50/50); both Windows programs (208/208); `vk-abi-check`; `vk-gen-test` 6/6; regeneration
    unchanged; the folds (18 refreshed) and the doc gate. Lint 0 on the five files.
  * **Tutorial 6.2:** flags as packed structures - a sketch of `ImageUsageFlags` with its bit positions, the integer a
    literal makes, and `hasAllFlags`.
  * **NEXT:** `Version` as a packed struct; then the selection closure; then the tutorial's chapter 11.

* **Oct 6 (later) - names to enums, and the host's render-pipeline section rewritten (Simon: "compareOp and others
  has names for an enum ... find the true best way ... intermediate variables for any long expression ... increase
  comment verbosity").**
  * **The finding:** `compareOp` scanned a table of WebGPU strings ("less-equal") at run time, with a panic for
    unknown names - parsing back the string the encoder had made, for the browser, from `gpu_abi.DepthMode`, which
    the same descriptor carried as an enum.
  * **The design:** `gpu_abi.CompareFunction` (WebGPU's `GPUCompareFunction`, Zig tag names) with `webgpuName()`;
    `DepthMode.compareFunction()`; `depthCompare()` now derived from it, so the blob and the browser's strings are
    unchanged (the web page and source map identical, the module the same size). The host maps the enum with an
    exhaustive switch - no strings, no panic path, no label: a new comparison fails to compile until it is mapped.
  * **The idiom, decided:** an exhaustive `switch` for every enum-to-enum translation. Where the names match
    exactly (`primitiveTopology`), `inline else => |tag| @field(vk.PrimitiveTopology, @tagName(tag))` would be
    shorter and equally checked, but explicit arms keep each Vulkan name visible and searchable.
  * **Expressed better:** `blendAttachment`'s positional tuple (`factors[0]`, `factors[2]`) became `BlendFactors`
    with named fields; `inputRate` replaced an `if` (a new step mode now fails to compile); `createRenderPipeline`
    names its long expressions (`sample_flags`, `mode_tests_depth`, `has_depth_target`, `writes_depth`,
    `depth_compare`, `depth_format`).
  * **Comments:** the section opens with what a pipeline is and how the translators work; each translator explains
    the Vulkan concept it maps (format names' components and `sfloat`/`uint`/`unorm`; lists and strips; the blend
    equations with what each mode means); `createRenderPipeline`'s doc is a table of its state blocks, and each block
    in the body has its explanation. `gpu_abi.DepthMode`'s docs rewritten neutrally (an anecdote and all-caps
    emphasis removed).
  * **Measured:** `gpu_abi`'s tests (4/4, the blob still "less-equal"); both Windows programs (208/208, which
    compile the pipeline code); `vk-host-test` (no validation messages); the web build; the folds (4 refreshed) and
    the doc gate. Lint 0.
  * **NEXT:** the same pass - names, intermediates, comment depth - over the rest of the host, section by section.

* **Oct 6 (later) - REVIEW of the whole host for the same problems, VERIFIED AGAINST MACH (Simon: "Review again ...
  similar problems elsewhere. Verify against mach").**
  * **The same problem, four more times: enumerations crossing the host boundary as integers and decoded ad hoc.**
    The browser's calls carry enumerations as numbers, and the same entry points serve this host. The texture format
    was already converted right (`std.enums.fromInt ... orelse panic`); four were not: the sampler's address mode (a
    switch on `1`, `2`, `else` - an unknown value became clamp-to-edge), the index format, the load op and the store
    op (each compared with `@backingInt(...)`, an unknown value silently becoming the other case). Now
    `enumFromValue(Enum, value, what)` converts at each entry point (an unknown value ends the program naming the
    argument), `RenderPassRequest` carries `gpu_abi.LoadOp`/`StoreOp`, and exhaustive translators map them:
    `samplerAddressMode`, `indexType`, `attachmentLoadOp`, `attachmentStoreOp` - Mach's `vulkanSamplerAddressMode`,
    `vulkanIndexType`, `vulkanLoadOp`, `vulkanStoreOp` have the same shape.
  * **A related trap:** `createSampler(mag_linear, min_linear, address_mode, mipmap_linear)` - three booleans by
    position, which a swap would not catch. Now a `SamplerRequest` with named, documented fields.
  * **Compound expressions named:** the handle check (null, or past the table), the validation decision (the layer,
    the debug-utils extension), the swapchain-extension test, GPU suitability (each feature, with what it is for).
    The other long lines are single Vulkan calls with long names, left as they are.
  * **VERIFIED AGAINST MACH (`src/sysgpu/vulkan/conv.zig`, `vulkan.zig`'s sampler): every translation agrees.**
    Compare ops (including `less_or_equal`/`greater_or_equal`), cull mode, front face (Mach too keeps
    counter-clockwise under its negative-height viewport), index type, load/store (`discard` -> `dont_care`),
    topology, address modes (`mirror_repeat` -> `mirrored_repeat`), input rate, all 8 of zimr's vertex formats, all
    11 texture formats (`depth24plus` and `depth32float` -> `d32_sfloat`), descriptor types (both storage kinds ->
    `storage_buffer`), sampler defaults (LOD 0..32, w clamp-to-edge, no anisotropy, no compare, transparent black).
    Differences are the documented design choices (GENERAL layouts and full barriers, copy usage on every resource,
    FIFO only, no dynamic offsets).
  * **Measured:** both Windows programs (208/208); `vk-host-test` (no validation messages); the folds and the doc
    gate. Lint 0.

* **Oct 6 (later) - the comment pass, section 1: bring-up (instance, surface, GPU, device).** Comment-to-code
  ratio 0.11 -> 0.28. A section introduction (the chain loader -> instance -> surface -> GPU -> device, and Vulkan's
  two-call enumeration explained once); `BringUpError`'s errors documented; `debugMessage`'s callback contract (the
  calling thread, `user_data`, why it returns false, why the message types are unused); the instance as a table of
  version, layers and extensions; `p_next` chains explained where the messenger rides on the instance's creation and
  where features are queried and enabled; queue families explained in `suitableQueueFamily`; `createFrameObjects` as
  a table. Expressed better: `hasExtensionNamed` shared by the instance and device extension lookups (the search was
  written three times); names hoisted out of loops (`wanted`); named conditions (`needs_presenting`,
  `renders_and_computes`, `matches_name`, `ranks_higher`, `extension_count`); the descriptor-set check uses
  `max_bind_groups` instead of 4. Measured: both Windows programs; `vk-host-test` (GPU choice on lavapipe, no
  validation messages); the folds (7 refreshed) and the doc gate. Lint 0. NEXT: memory, names and destroys; command
  buffers and the timeline; the swapchain; the frame.

* **Oct 6 (later) - the comment pass, sections 2 and 3: memory, names and destroys; command buffers and the
  timeline.** Each section opens with its model (heaps, memory types and their properties, a resource's type mask;
  command buffers, submissions, the timeline and what retires with a number). `memoryTypeIndex` names its mask test
  (`type_bit`, `is_allowed`, `has_properties`); `allocateMemory` names its two lookups and explains the allocation
  limit; `nameObject`, `executeDestroy` and `deferDestroy` say why, not only what. `retireCompleted`'s three
  compaction loops became `retireCommandBuffers`, `retireStagingChunks` (documenting the submission order
  `waitForOldestStagingChunk` relies on) and `retireDestroys`, leaving it a summary; `submitBatch` is phased
  (command buffers, the wait, the signals) with named conditions (`waits_for_acquire`, `presents`), its bookkeeping
  moved to `retireWithBatch`. `fullBarrier` and `imageBarrier` say what they guarantee and when layouts change.
  Measured: `vk-host-test`'s statistics unchanged (1 page, 4 chunks; 5 chunks; no validation messages) - the
  retirement split and `retireWithBatch` behave as the code they replace; both Windows programs; the folds (11
  refreshed; `retireDestroys` and `retireWithBatch` added to chapters 3 and 7) and the doc gate. Lint 0. NEXT: the
  swapchain; the frame.

* **Oct 6 (later) - the comment pass, sections 4 and 5: the swapchain; the frame (acquire and present).** Each opens
  with its model (the presentation engine lending images; the three handshakes and frames in flight).
  `chooseSurfaceFormat` names its preference list and its two tests, and says what the sRGB color space means for the
  bytes the engine writes; `createSwapchain`'s doc is a table (format, count, size, usage, FIFO), and the body names
  Vulkan's two special values (`surface_states_size` for the all-ones extent - `maxInt` bound from `zimrmath`, as the
  house's std.math ban requires; `has_maximum` for a maximum image count of 0), explains exclusive sharing, the
  transform and `clipped`, and why present semaphores are per image; the view's range is `single_color_range`, the
  constant that already said it. `rebuildSwapchain` explains the idle wait and the handover. `acquireNextImage`
  removes the duplicated seven-argument acquire; `acquireImage` and `presentImage` are phased with named conditions
  (`is_stale`, `needs_rebuild`). Measured: both Windows programs (the only build compiling the windowed paths, which
  the sandbox cannot run); `vk-host-test`; the folds (2 refreshed) and the doc gate. Lint 0. NEXT: staging and
  buffers; textures, samplers, shader modules.

* **Oct 6 (later) - REVIEW of the comment pass: every technical claim checked against the specification.** A comment
  that teaches must be right; five were not, and the review's own first fix overclaimed once more:
  1. **"The loader's one exported command"** (host introduction, `vk.zig`, `native_os`): the loader exports the whole
     core API. True: `vkGetInstanceProcAddr` is the one command the host takes from it by name. The tutorial's
     sentence aligned. (The first correction then said a looked-up command "reaches its driver directly" - true only of
     device commands looked up through `vkGetDeviceProcAddr`, which skip the loader's dispatch; narrowed to that.)
  2. **`VulkanTooOld`:** timeline semaphores are core from 1.2, not 1.3 (`createDevice`'s comment had it right - the two
     contradicted each other).
  3. **`pre_transform`, backwards:** setting it to the surface's current transform DECLARES the content already in the
     display's orientation - the engine does not rotate it. The identity on desktop, so zimr is right today; a rotated
     (phone) display needs rotated rendering, or the identity and the compositor rotating. Now said so.
  4. **The callback's thread:** usually the reporting call's, not guaranteed - softened.
  5. **"The sRGB color space, which every surface offers":** the standard one, not a guarantee - softened. (FIFO being
     the one present mode every surface must support IS the specification's rule, and stays.)
  * **Checked and right:** the callback's `false` (Vulkan reserves `true` for layer development); the debug messenger
    in the instance's chain; queue priorities; robust buffer access; the allocation limit (often 4096); memory
    properties; the two special values (all-ones extent, maximum count 0); `clipped`; exclusive sharing; per-image
    present semaphores; the `old_swapchain` handover; acquire signalling when the image is really free; UNDEFINED as
    "contents not needed"; the full barrier's guarantee; one-time-submit; the front-face rule under the flipped
    viewport; the store op's `dont_care`; 16-bit index range; LOD 0..32.
  * **Measured:** lint 0; the regeneration preserves `vk.zig`'s corrected doc; `vk-host-test`; the folds and the doc
    gate.

* **Oct 6 (later) - the last review-and-comment turn (Simon: "one last turn of review and comments").**
  * **A defect from an earlier edit, found:** inserting the load/store/index translators had separated
    `RenderPassRequest`'s doc line from its struct - it sat atop `attachmentLoadOp`'s doc, and the struct had none.
    Zig does not flag a doc comment on the wrong declaration. Returned to its struct.
  * **A stale doc, found:** `createShaderModule` listed three of the legalizer's five adjustments; it now points to
    `spv_vulkan`'s header, which owns the list. Its all-caps emphasis went too, as did `beginRenderPass`'s.
  * **Introductions** for staging and buffers (two-step crossing, a chunk's life, the budget), textures (images, views,
    samplers, optimal tiling), bind groups (descriptor sets, layouts, pipeline layouts, pool pages), render passes
    (dynamic rendering; load/store fixed at the start; groups bound at the next draw), shutdown (children before
    parents), the entry points (the bridge's names and integer arguments; `theHost`, `enumFromValue`; failures named)
    and the stubs (a compile error only when called).
  * **Named conditions:** `budget_allows_a_new_chunk`, `no_submission_holds_a_chunk`, `write_offset`. **Explained:** the
    texture's optimal tiling and undefined initial layout; its zero clear - a depth of 0 at creation, as WebGPU promises,
    unlike a pass's clear to 1.0 at the start of drawing; the read-back buffer's memory (coherent: no invalidate call -
    the first wording said "flush", the wrong operation for reads, and was corrected in review).
  * **Measured:** comment ratio of the host 0.15 -> 0.23 over the whole pass (sections 0.12 to 0.42; the thin wrappers
    and stubs remain lowest, as they should). Both Windows programs; `vk-host-test` statistics unchanged; the folds (9
    refreshed) and the doc gate. Lint 0.

* **Oct 6 (later) - titles that name their topic (Simon: "One write, followed. The device and its features. Why
  bytes. Blending, worked through ... sound like claudisms ... Titles should just name the topic").** 43 of the
  tutorial's titles renamed, in the headings and the contents alike - the patterns: a trailing participle ("One
  write, followed" -> "Buffer writes"; "Blending, worked through" -> "Blending"; "One frame, followed" -> "A complete
  frame"), questions and fragments ("Why bytes" -> "The wasm boundary"; "Which way is up" -> "The Y axis"; "What a
  render pass is" -> "Targets, load and store"; "What WebGPU does for you" -> "Implicit synchronization"), paired
  slogans ("One engine, many GPUs" -> "Overview"; "One shader, three languages" -> "Shaders"; "One layout, full
  barriers" -> "Layouts and barriers"), clauses that editorialize ("Declarations that can be trusted" -> "Declarations
  and the ABI check"; "Destroying what the GPU may still use" -> "Deferred destruction"; "The whole sequence" ->
  "Initialization order"). The planned "Verifying what you cannot run" -> "Verification". The host's "The calls not
  written yet: each a compile error naming itself" -> "Unimplemented calls". The same sound in prose, rewritten as plain
  statements: "Here is everything that follows", "Here is a frame of", "Two things stand out" (with its not-X-but-Y
  sentence), "Usually that is exactly what makes it fast". The doc gate passes; lint 0.

* **Oct 6 (later) - WHERE THE LAUNCHER STANDS, re-estimated from the code (Simon: "how many turns before we have the
  full launcher app running on windows, including ... the ui textfields").**
  * **Done:** S0, S1, S2 (all of `hello_world`'s calls; the host's core). Since then: the Zig binding generator, the
    names and flags, reviews and the tutorial - none of it advancing S3-S6.
  * **Left, measured:** 19 host calls unimplemented (compute 7; copies and readback 6; MRT, `draw`, scissor 3; mip and
    array views 2; `adapter_info` 1); 65 `isWasm()` gates in 7 files (from 216); NO Win32 input yet (no key, mouse,
    wheel or `WM_CHAR` handling; nothing calls `input_push_*` natively).
  * **What the launcher's 31 apps need:** compute (fluid_sort, four_ways, mandel_sidebyside, rt_sidebyside, a
    ui_full_showcase panel) - so S5 is on the path; jobs (worker_png, four_ways); persistence (ui_full_showcase); text
    fields (ui_full_showcase). No app uses audio or pointer lock.
  * **Estimate:** S3 3-4 (the message table; `WM_CHAR` -> `input_push_char` with UTF-16 surrogate pairs; `ui.zig`'s
    editing path run for real; clipboard copy/cut/paste brought forward from S8), S4 3-4, S5 4-5 (kompute's source
    change web-first, checked on a phone), S6 3-4 (jobs - synchronous first -, persistence, the remaining gates, the
    launcher itself) - ABOUT 14 TO 18 TURNS of stage work; about 20 to 25 with a review and the tutorial after each
    stage, as this session has worked. IME composition is extra (1-2). Every stage's pass needs a Windows run by Simon.

* **Oct 6 (later) - TEXT INPUT, AFTER DEAR IMGUI: the design for S3 (Simon: "Imgui is probably doing the correct
  thing for text fields on windows ... keep all these differences between web and native as limited and simple as
  possible").** Read from ImGui's source (`backends/imgui_impl_win32.cpp`, `imgui.cpp`, `imgui_widgets.cpp`,
  `imstb_textedit.h`).
  * **ImGui's split.** The platform layer only TRANSLATES: key up/down (`AddKeyEvent`, modifiers submitted first),
    typed text as UTF-16 units (`AddInputCharacterUTF16`, from `WM_CHAR` only - the OS has applied the layout, dead
    keys and IME, so text never comes from key codes), mouse, focus (`AddFocusEvent`, so the core releases stuck keys).
    It provides three SERVICES on request: get the clipboard, set it (`Platform_Get/SetClipboardTextFn`; Win32's is 40
    lines: `OpenClipboard`, `CF_UNICODETEXT`, UTF-16<->UTF-8), and where the text cursor is (`Platform_SetImeDataFn`,
    called only when it changes; Win32's is 20 lines: `ImmSetCompositionWindow` and `ImmSetCandidateWindow` - the OS
    draws the composition, and the committed text arrives as plain `WM_CHAR`s). EVERYTHING ELSE IS THE CORE, the same on
    every platform: the editor (stb_textedit: selection, undo, word moves), the shortcuts (Ctrl+X/C/V, Shift+Delete,
    Ctrl/Shift+Insert, Ctrl+Z/Y, Ctrl+A; one switch, `ConfigMacOSXBehaviors`), surrogate pairing, key repeat.
  * **zimr today: two editors.** On the web the BROWSER edits: `ui.zig` shows DOM `<input>`/`<textarea>` overlays
    (about 20 `dom.*overlay*` calls: password, read-only, filters, Escape, Tab, Ctrl+Enter, input mode) and reads the
    text back. Natively `ui.zig`'s own editor runs - never yet for real - and documents its gaps: no selection, no
    clipboard, no undo/redo, no Tab, no scroll. Keys are physical on both (`KeyboardEvent.code`; Windows scancodes);
    repeat is the OS's on both (the browser's `repeat` flag; `WM_KEYDOWN`'s bit 30) - kept: it respects the user's
    settings, and nothing in the engine changes.
  * **The design: one editor everywhere, ImGui's split.** `ui.zig`'s editor completed (selection - Shift+arrows/Home/End,
    drag, double-click word, select all -, word moves and Ctrl+Backspace/Delete, undo/redo, Tab, multi-line scroll,
    password masking and the filters the overlays offered), structured after stb_textedit. The platform layers feed the
    existing `input_push_*` calls plus a focus event; UTF-16 surrogates are combined once, in the engine. Three
    services per platform: clipboard get, clipboard set, the text cursor's rectangle. Natively: Win32 (ImGui's code
    as the reference). On the web: ONE hidden `<textarea>` as an input sink - focused while a field is active,
    placed at the cursor (so IME candidates and mobile keyboards appear there), its `input`/`compositionend` events
    pushed as characters, `deleteContentBackward` as Backspace, its `paste`/`copy`/`cut` events carrying the
    clipboard; `autocorrect`/`autocapitalize`/`spellcheck` off, `inputmode` kept. The overlays and their ~20 calls are
    then deleted.
  * **Why this is also the testable choice:** with one editor, every editing behaviour can be unit-tested headlessly in
    Zig by feeding key and character events - in the sandbox, which can run neither Windows nor the browser's own
    editor.
  * **What the web gives up against real DOM inputs:** the browser's spellcheck; password managers and autofill;
    screen-reader access to the fields; some mobile autocorrect behaviour (replacement suggestions).
  * **S3, revised: 5-7 turns** (from 3-4): the Win32 message table and the input API (1); the editor's missing parts
    (2-3); the clipboard and cursor services, both platforms (1); the web sink replacing the overlays, checked by Simon
    on desktop browsers and his phone (1-2). IME comes nearly free (the cursor service). **The launcher: about 16 to
    21 turns of stage work.**

* **Oct 6 (later) - LESSONS FROM RAYGPU AND WGVK (Simon: "Study deeply how raygpu deals with the windows backend ...
  make our plan better and more precise").** raygpu: a raylib on WebGPU, Windows through GLFW, SDL3 or RGFW (one
  `InitWindow_*.c` each), GPU through Dawn or WGVK - its author's WebGPU-on-Vulkan (`src/wgvk.c`, ~11 900 lines,
  fetched from GitHub for the study).
  * **The platform side.** GLFW's path is complete (characters, focus, clipboard, content scale); the RGFW path is not:
    it DROPS repeated key-downs (`if(repeat && pressed) return;` - a held Backspace does nothing) and ignores `keyChar`
    (no text at all). RGFW itself derives characters with `ToUnicodeEx` truncated to a byte - non-ASCII lost, dead keys
    consumed - which is why zimr's text comes from `WM_CHAR` only. Worth adopting: RGFW's scancode rules (three
    corrections and a fallback) and its drag-resize timer. Surface creation from `HWND` + `GetModuleHandle(NULL)`, as
    zimr's. raygpu scales mouse positions UP to framebuffer pixels; zimr's engine works in the browser's CSS pixels,
    so it divides - now stated in S3a. raygpu's frame limiter waits on a waitable timer WITHOUT
    `CREATE_WAITABLE_TIMER_HIGH_RESOLUTION`, so it still rounds to the 15.6 ms tick - the rule for any limiter zimr
    adds: a high-resolution timer (`CreateWaitableTimerExW`).
  * **The GPU side, WGVK.** Precise usage tracking (per-encoder records of each resource's first and last use; barriers
    between uses; references held until a per-submission fence signals; compatibility barriers between command
    buffers at submit) - yet full barriers at the submit boundary, conservative access masks, one subresource range
    per record. Two of its choices are faults zimr's design avoids: `wgpuQueueWriteBuffer` copies into a host-visible
    buffer IMMEDIATELY, on the CPU, racing any submitted frame still reading it (WebGPU orders the write after that
    work - zimr stages every write and copies on the queue), and otherwise creates a staging buffer per write; and its
    present waits on a per-frame semaphore (`syncState->semaphores`, indexed by frame-in-flight slot) - the reuse
    hazard found in mach, which zimr's per-image present semaphores avoid. Confirmed in zimr's favour: the timeline
    (one semaphore for every submission, where WGVK keeps a fence per submission and a cache per frame); the full
    barrier (WGVK's precision costs per-encoder hash maps and still ends in full barriers between submissions).
  * **The plan, made precise:** S3 split into S3a-S3d with the exact rules (physical keys by scancode, repeat bit 30,
    `WM_CHAR` and surrogates, focus releasing keys, mouse divided by the scale, the wheel's units and signs, clipboard,
    the IME rectangle, the editor, the web sink); S7 starts with an unthrottled present mode (under FIFO a frame time
    is the refresh rate), names a middle step before state tracking, and WGVK's allocator as the sub-allocation
    reference; S8's drag-resize made exact. Estimates unchanged (S3 5-7).

* **Oct 6 (later) - S3a, THE MESSAGE TABLE, written (Simon: "Proceed").** Three files, each one job:
  * **`win32.zig` - Windows' own part, nothing of the engine.** Input messages go to `Window.input_handler` with the
    window's scale (`InputMessage`); the procedure first captures the mouse on a press and releases it when the
    message's `MK_*` flags show no button left down, fills in a missing scancode (`MapVirtualKeyW`), and refuses the
    bare menu key (`SC_KEYMENU` with no character: Alt alone, F10), keeping Alt+F4 and Alt+Space. 26 constants and
    3 functions added, all matched by `win32-abi-check`. It still imports nothing but `std`, so `vk-hello-windows` and
    the ABI check need no engine modules.
  * **`native_input.zig` (new) - the whole translation, platform-neutral.** The scancode table for exactly the
    bridge's 105 codes (W3C's Windows column), turned into engine keys at compile time THROUGH the bridge's own table
    (`dom_input.keyboardKeyFromDomCode`), so the two platforms share one mapping; RGFW's three corrections; repeat
    from bit 30; PrintScreen's lone release given its press; `WM_CHAR` surrogates paired (`Utf16Decoder`) and control
    characters dropped; mouse in logical pixels, signed (negative when captured); buttons through
    `dom_input.mouseButtonFromDomButton`; the wheel in notches; focus loss releasing held keys and buttons. 11 tests
    (`zig build native-input-test`), several from real message bit patterns.
  * **`native_loop.zig` - delivery.** Installs the handler, queues between frames, and before each `update` passes the
    events in order to `wgpu_app`'s `input_push_*` - the bridge's calls. `ZIMR_LOG_INPUT=1` prints each event as the
    engine receives it (through `web.dom.log`'s native path, so release builds print too).
  * **Checked:** both Windows programs; the ABI check; `vk-host-test`; lint 0; the web `hello_world` byte-identical with
    and without the one shared change (`dom_input.dom_key_count` made public for the coverage test). Found in passing:
    `native_loop.run`'s doc sat on `UpdateFunction` (the same misplaced-doc defect as `RenderPassRequest`'s) - fixed.
  * **To verify on Windows (Simon):** `set ZIMR_LOG_INPUT=1` then `hello_world.exe` - keys (left/right modifiers,
    keypad with Num Lock on and off, arrows), held-key repeat, typed text including accents and an emoji, mouse, a
    drag leaving the window, the wheel, Alt+Tab with a key held. **Next:** a Windows build of an input example
    (`input_keys`), the hand-wired `hello-world-windows` step made reusable.

* **Oct 6 (later) - THE LAUNCHER COMPILES FOR WINDOWS UP TO 15 CALLS (Simon: "Hello world exe works. But i wont be
  able to test until the full launcher is complete. Continue").** Order of work changed accordingly: reach a launcher
  that builds, then links, then runs, before the editor (S3b-S3d).
  * **`build.zig` - every app buildable for Windows, wired as on the web.** `AppContext.wasm_target` renamed `target`;
    `AppContext.vulkan_shaders` embeds each shader's SPIR-V (`ShaderOutput.spv`) under its WGSL import name - the
    engine module's convention, now the apps' too; a Windows context, the web context's twin (Windows target and
    engine, Windows instances of `example_common` and `kompute`, its own shader cache); `addWindowsApp` (the browser
    build's runner with the app, into `zig-out/windows`) and `appNamed`. `hello-world-windows` now goes through them
    (its hand-wired block deleted); `launcher-windows` is new, the 32 flagships from the shared `flagships` list. The web
    `hello_world` is byte-identical.
  * **The launcher's compile, the to-do list - exactly 15 host calls:** compute 7 (`device_create_compute_pipeline`,
    `compute_pipeline_destroy`, `encoder_begin_compute_pass`, `compute_pass_set_pipeline`,
    `compute_pass_set_bind_group`, `compute_pass_dispatch_workgroups`, `compute_pass_end`); copies and readback 5
    (`encoder_copy_buffer_to_buffer`, `buffer_read_start`, `buffer_read_poll`, `buffer_read_into`,
    `buffer_read_release`); render 3 (`encoder_begin_render_pass_mrt`, `render_pass_draw`,
    `render_pass_set_scissor_rect`). Not reached: mip and array views, `adapter_info`, texture-to-buffer copies.
  * **What comes after:** link errors are reported only once compilation succeeds - browser-only `extern "dom"`,
    `"jobs"` and `"audio"` declarations still analyzed natively will surface then - and after that, run-time `isWasm()`
    gates (65 left). **Order:** the 3 render calls (S4); copies and readback (S5); compute, with kompute's SPIR-V source
    change (S5); then the link list; then the editor and services (S3b-S3d).

* **Oct 6 (later) - THE THREE RENDER CALLS (S4), the launcher down to 12.** `render_pass_draw` (as the indexed draw:
  the dirty groups bound, then `cmdDraw`); `render_pass_set_scissor_rect` (passed through unchanged - both APIs measure
  framebuffer pixels from the top-left corner, and zimr's Y flip is the viewport's alone; the engine's own doc says
  "backing pixels, origin top-left"; the bridge does not clamp either); `encoder_begin_render_pass_mrt` (as the
  bridge: every color target cleared or loaded, stored or discarded alike, depth cleared to 1.0 and stored, no
  resolve). `beginRenderPass` now takes `RenderPassRequest.color_views` (1 to `gpu_abi.max_color_targets`, all one
  size; a resolve only with one), so the single-target call is a list of one - one pass for both. `vk-host-test` gains
  `targets` (two color targets, a depth target, a scissor) - no validation message. A defect I reported in passing
  was not one: a doc line I took for a stray duplicate was two overlapping print ranges in my own listing. **Left for
  the launcher's compile: 12** - copies and readback 5, compute 7.

* **Oct 6 (later) - COPIES AND READBACK (S5, first half), the launcher down to the 7 compute calls.**
  `encoder_copy_buffer_to_buffer` (after a full barrier, like every transfer). The reads follow the bridge exactly:
  `buffer_read_start` on a `map_read` buffer, `buffer_read_poll` 0 until ready then 1 with the bytes copied out (so
  later work on the buffer cannot change them, as the browser copies the mapped range before unmapping),
  `buffer_read_into` copying as many bytes as both hold and nothing before ready, `buffer_read_release`.
  * **A requirement the plan had missed - the barrier to the host.** A GPU write reaches a CPU read only through a
    barrier with the `host` stage and `host_read` access as destination: the full barrier stops at the queue's stages,
    and a semaphore signal moves nothing to the host. Lavapipe and the validation layer (without synchronization
    validation) would never show its absence. `hostReadBarrier` is recorded at `buffer_read_start`, as Dawn does when
    it maps a buffer.
  * **Reads see pending writes too.** `buffer_read_start` submits the pending writes and the barrier at once
    (`flushUploads`): `submitBatch` takes `.null_handle` for "no commands", and such a batch takes no acquire wait
    (only a batch of commands touches the acquired image). The read's serial is that batch's.
  * **Checked:** `vk-host-test` gains `read` - words written, copied into a `map_read` buffer, polled and read back,
    equal byte for byte, no validation message. `hello-world-windows` builds. **The launcher's compile: 7 left, all
    compute.**

* **Oct 6 (later) - S5 compute, step 1: kompute's bindings explicit, proved on every kernel.**
  * **The instrument:** `ShaderPipeline.compute_outputs` records each kernel entry as `addCompute` builds it (the
    file's SPIR-V, the entry's WGSL, named `<file>__<entry>`), and `zig build kernels-wgsl` installs every entry's WGSL
    into `zig-out/kernels-wgsl` - 192 entries - so a kompute or spv2wgsl change is checked by comparing two
    directories. The SPIR-V is recorded for the native kernels to come.
  * **The change (Decision D3's first half):** `kompute.params_binding` (0) and `kompute.bufferBinding(Buffers, field)`
    (1 + the field's index); `Globals.bind` decorates each storage block with its number; on GPU `P` is now a
    `@extern` POINTER carrying binding 0 (a declaration-level `extern` takes no options) - `g.P.count` and
    `@field(Module.g.P, name)` read through it unchanged - and `uniform()` returns it. The comment saying the host
    must read the numbers back from WGSL is replaced. CPU side untouched.
  * **Proof - the plan's criterion met exactly:** 192 kernels; 182 differ in `@binding(N)` only, 10 identical, 0 other
    changes, 0 missing. The old numbers followed the SPIR-V backend's variable order (fluid_kernels' buffers 2/3/4
    were fields 4/2/3); now they follow the fields. The web host reads each number BY NAME from the WGSL
    (`parseBindings`: `kbuf_<field>` as a whole word, plus a used-but-unbound cross-check), so it follows them.
  * **Left for the native compute step:** `compute_host` scans WGSL text for the numbers, for which buffers each kernel
    uses, and for the cross-check - natively the bytes are SPIR-V. The numbers come from kompute's declarations; the
    uses from `spv_vulkan.reflect`; the scans stay, on WGSL only (told apart from SPIR-V by its magic number, not by
    another `isWasm()` gate). **Next:** real atomics and barriers (inline-asm `OpAtomic*`,
    `std.spirv.workgroupBarrier()`) with spv2wgsl's `OpAtomic*`/`OpControlBarrier` arms - expected WGSL diff: none.

* **Oct 6 (later) - REVIEW OF THE LAST SIX TURNS (Simon: "Review carefully the last few turns").** Four defects, all
  fixed and tested:
  * **Alt with a character beeped - Alt+Enter, the usual fullscreen key, included.** `WM_SYSCHAR`'s default handling
    sends `SC_KEYMENU` with the character; the handler refused only the character 0, so `DefWindowProcW` looked for a
    menu item, found none, and beeped. Now every `SC_KEYMENU` is refused except Alt+Space (the window's own menu).
  * **PrintScreen could be pressed twice.** The key-up translation always gave a press first, but Windows does send the
    press when no screenshot tool takes the key. Now the press is given only when the key is not held. Tested both
    ways.
  * **A read whose buffer was destroyed panicked - or, unchecked, would read freed memory.** WebGPU rejects the pending
    map and the bridge reports the read ready and empty; the native poll now does the same, through `Pool.find` (null
    for a destroyed or reused handle, where `get` ends the program).
  * **`kernels-wgsl` could hide a kernel.** Two different files with one stem and one entry name would have shared a
    name, and the second been skipped silently; now the build stops, naming both files (none collide today: 16 kernel
    files, 192 entries).
  * **Also:** `compute_host.parseBindings`' comment still said the SPIR-V backend assigns the numbers - corrected.
  * **Checked and kept:** depth-only render passes are not used by the engine (its one multi-target caller always
    passes targets), so `beginRenderPass` still requires a color target and names the case if one ever comes; mouse
    leaving the window does nothing on either platform.
  * **A web gap, recorded for later: losing focus releases nothing in the browser.** The bridge has no `blur` handler,
    so a key held during Alt+Tab stays down in the engine until pressed again; native releases it. The fix is an engine
    call releasing all input, made from the bridge's window `blur` - a web behaviour change, to make with the editor
    work (S3d).

* **Oct 6 (later) - the tutorial: chapter 11, Windows, first half (Simon: "work on the tutorial. Spend many turns on
  this").** 11.1 the window (messages, the window procedure, what `Window` records, `pump`); 11.2 the frame loop
  (`native_loop.run` beside `requestAnimationFrame`); 11.3 logical and physical pixels (the scale, per-monitor
  awareness, `WM_DPICHANGED`; a window followed at 150%); 11.4 the input path (the three files, `translate`); 11.5 keys
  (physical keys, scancodes and the extended flag, the scancode -> DOM code -> engine key table worked through three
  keys, the three corrections, repeat, PrintScreen). Six code blocks from source. In passing: `Window.scale`'s doc
  ("logical pixels per physical pixel's inverse") rewritten plainly; `translateKeyDown`/`translateKeyUp` given docs.
  Four older folds refreshed (`RenderPassRequest` among them). **Next:** 11.6 typed text, 11.7 the mouse and the wheel,
  11.8 focus and the menu key, 11.9 building for Windows.

* **Oct 6 (later) - the tutorial: chapter 11 completed.** 11.6 typed text (keys against text; a dead key worked
  through; UTF-16 surrogates, U+1F600 encoded and decoded step by step; control characters left to the keys); 11.7
  the mouse and the wheel (signed positions, capture, the button table through the DOM's numbering, wheel notches);
  11.8 focus and the menu key (releasing on focus loss; the menu commands refused, Alt+Space and Alt+F4 kept; the
  browser's missing release stated plainly); 11.9 building for Windows (the two contexts; one shader name, two
  embeddings; `addWindowsApp`). Found while writing, all fixed:
  * **11.9 referred to an explanation that did not exist** - section 2.6 described the interface check, not why an
    unimplemented call fails only the programs that call it. 2.6 now says so (Zig compiles a body only when called).
  * **`AppContext` had lost its doc comment** - the THIRD misplaced-doc defect from my edit scripts: inserting a
    declaration directly above another's declaration LINE puts it between that declaration and its doc, and Zig reads
    one doc block for the inserted one. The fold of `addWindowsApp` showed `AppContext`'s doc. Returned, and the other
    two insertions anchored on a declaration line checked (both fine). **Rule from now on: insert above a
    declaration's doc comment, never between the comment and its line.**
  * **A plan reference in code** - `wgpu.zig`'s comment "(the plan's principle P6)" - removed (no line moved: a
    web-built file).

* **Oct 6 (later) - THE HOST CALLS NAMED IN ZIG'S STYLE (Simon: "some functions called on zig side are not
  respecting convention for names ... Do what you suggest").** WebGPU never required the snake_case names; only the
  wasm SYMBOLS are shared with the bridge, and the bridge already binds camelCase functions to snake_case symbol strings
  (`ns.set("js_render_pass_draw_indexed", funcNum(&jsRenderPassDrawIndexed))`).
  * **Kept:** the 60 `extern "wgpu" fn js_*` declarations, named as their symbols (as `std.c` declares `malloc`), and
    every symbol string in the bridge.
  * **Renamed to camelCase:** the 60 host-interface names, both hosts alike (`web_host`'s `pub const renderPassDrawIndexed
    = js_render_pass_draw_indexed`, the Vulkan host's entry points and stubs - their compile errors now name
    `computePassEnd` and the like - and every `gpu_host` call); the 10 `wgpu_js` thunks; the 11 input calls
    (`inputPushKeyDown` ..., the touch ones without their `zimr_` prefix), exported under their old symbols with
    `@export`. 13 new names equal the engine API's own (`queueWriteBuffer`, `bufferReadStart` ...): legal - Zig forbids
    shadowing in local scopes only, checked - and they read as the typed call over the raw call of the same name.
  * **An import cycle removed:** `native_loop.zig` <-> `wgpu_app.zig` (S3a's direct calls into the app; flagged once
    `wgpu_app.zig` was linted). The app now hands the loop its input function, as it hands it `update`:
    `native_loop.run(update, receive_input)`, with `wgpu_app.receiveNativeInput` making the calls. The loop keeps the
    logging, and imports nothing of the app.
  * **Proof:** the web `hello_world`'s wasm imports and exports are the same names (70 and 25; the input exports moved
    within the export section, which the bridge reads by name). Both Windows programs; `vk-host-test`;
    `native-input-test`; the launcher still at the 7 compute calls; lint 0. Tutorial: 7 `data-decl`s and 15 prose
    mentions renamed (the frame table realigned), and `wgpu_js`'s stale comment ("no-ops on host builds") corrected.

* **Oct 6 (later) - the tutorial: chapter 8 gains copies and readback.** 8.4 copies between buffers (a command in an
  encoder, after a full barrier; how results leave device-local memory); 8.5 reading back (why a read is asynchronous;
  the engine's start/poll/into/release; three conditions - order, with the pending writes submitted at once;
  visibility, the barrier to the host and why the full barrier does not reach it; a stable answer, the bytes copied
  out - one read followed across three frames on the timeline; a destroyed buffer's read ending empty). Textures,
  texture writes and samplers renumbered 8.6-8.8 (nothing cited them by number). The chapter's opening list of WebGPU's
  promises gains "a read sees everything submitted before it". Four code blocks from source. **Next:** chapter 10 -
  multiple render targets, the scissor rectangle, draws without indices.

* **Oct 6 (later) - the tutorial: chapter 10 gains several targets, plain draws and the scissor.** 10.2: several color
  targets (fragment outputs by location; a G-buffer as the example; all targets alike, one size, the render area from
  the first, a resolve with one target only). 10.3: draws without indices (vertices in order; a full-target triangle
  with no buffers). New 10.4, the scissor rectangle (what it is for; why it passes through unflipped - the flip is the
  viewport's, the scissor tests the target's own pixels; an 800 x 600 target worked through; the clear is not
  limited by it). Ending a pass and the complete frame renumbered 10.5-10.6. Two code blocks from source. **Next:**
  chapter 12, compute - kompute kernels, how they are built, their bindings.

* **Oct 6 (later) - the tutorial: chapter 12, compute, first part.** Written for the backends' side only, linking to the
  GPU compute tutorial for writing kernels (explained once there). 12.1 kernels (what a file declares; `double_it` from
  source; why a kernel tests `params.count` - 1000 elements in workgroups of 64 launch 1024 threads); 12.2 from Zig to
  each platform (one SPIR-V module per file, one WGSL per entry, the `<entry>_wgsl` imports; `kernels-wgsl` for
  inspecting them; `ComputeOutput`); 12.3 bindings (the rule - Params at 0, each Buffers field one past its position;
  `particle_step` worked through against its generated WGSL; the decoration in the SPIR-V; the web host reading the
  numbers by name). The native compute path is left out until it exists. Noted for the final pass: the GPU compute
  tutorial predates the house style (titles such as "A one-character bug that froze the fluid", "The turn we didn't
  take"; development stories) - to raise with Simon.

* **Oct 6 (later) - the GPU compute tutorial rebuilt (Simon: "Bring it inline. Find a simple, good way to separate the
  content in both tutorials. Then look in readme.html ...").** **The separation:** the GPU compute tutorial is about
  PROGRAMMING with kompute - writing kernels, running them, designing a parallel algorithm, making it fast - and nothing
  in it depends on the platform; the backends tutorial is about how zimr RUNS on each platform. Where one reaches the
  other's subject it links instead of explaining. **The form:** the backends tutorial's - `docfmt` styles, a contents
  list, numbered chapters titled by topic, sketches, every code block generated (the old page's 22 blocks were pasted
  copies, some stale). Written as `gpu-compute-tutorial.draft.html`, registered with `doc-folds`, and swapped in when
  complete. This turn: chapters 1-4 - compute on the GPU; the CPU and GPU builds (`is_gpu`, `atomicAdd`); kernel files
  (buffers and parameters - one buffer per field stated as a rule, the uniform layout rule; the context and the count
  test; entry points); from kernel to shader (the author's rules, links to backends 5 and 12). The old page's stories
  restated as facts or dropped. **Next:** chapters 5-7 (running kernels, the fluid, performance), the swap, the
  backends tutorial's links moved to the new anchors and its 12.1 trimmed to point here; then readme.html.

* **Oct 6 (later) - the GPU compute tutorial: complete, and in place.** Chapters 5-7 written: running kernels (the
  three backends `.cpu`/`.worker`/`.gpu`, "interchangeable in code, not in cost"; dispatch; batching; data staying on
  the GPU; `readLatest`), the SPH fluid (the state; the counting sort worked through on six particles; density,
  pressure, viscosity, gravity, prediction and walls; the eleven-dispatch sub-step), performance (the measured effects
  as a table, coalesced memory, three other techniques, tiling against sorting as a technical comparison - the old
  "road ahead" and its roadmap dropped). 20 code blocks, all generated. The draft replaced the old page (kept in
  /tmp/big); `doc-folds` lists the real page. The backends tutorial's links moved to the new anchors (`#builds`,
  `#kernelfiles`), and its 12.1 now points to the compute tutorial instead of restating the kernel file. Facts checked
  against the code, three of the old page's wrong: the fluid runs ONE sub-step a frame (not three); its files moved
  (`examples/fluid_sort/`); `readLatest` is asynchronous and copies each field's live elements. The example's own
  comment calling `readLatest` "a blocking GPU sync" that copies every buffer, and its "only question that matters
  right now" note, rewritten as a description. **Next:** readme.html - linking the tutorials.

* **Oct 6 (later) - readme.html links every tutorial, and the doc gate keeps it so.** The readme's index ("The long-form
  walkthroughs, in one place": "seven" pages, nine listed, the file atlas among them) had drifted: three tutorials
  unlinked anywhere on the page (backends, robot motion capture, zimrrl), the compute tutorial under its old slogan,
  and a dead link (`notes/tutorials/zimrnum-tutorial.html` - pages are published at the root). Now: a "Tutorials"
  section grouped by subject (graphics; compute and learning; robotics), each group in reading order, each entry the
  topic's plain name and one line on what the page covers, and a reference line (cheatsheet, file atlas); the section
  pointers (`p.tut`) retitled, the shader one's description corrected (both ways are Zig: hand-wired bindings or a
  typed schema), and pointers added under the sections the three unlinked tutorials belong to.
  * **The doc gate's sixth property:** the landing page links every published page, and links no `.html` page that is
    not published. The build passes each page as `<published name>=<path>` (a bare path still works). It reported
    exactly the four problems above before the fix, and passes after. Its tests (`linksPage`, `unpublishedLinks`,
    `pageOf`) - and its older duplicate-id test, which NO step ran - now run in `tools-test`.
  * **A correction to earlier turns:** I reported "the doc gate passes" after running `doc-pages`, which builds the
    pages; the gate is the separate `doc-gate` step (and part of `gate`). Run now, it passes on all 15 pages - the
    tutorial work of these turns included - but it had not been run until this turn.

* **Oct 6 (later) - S5 compute, step 2: real atomics and barriers (Simon: "continue with getting the launcher and all
  examples running on vulkan windows ... avoid having to change anything in example code").** No example changes: kompute
  and spv2wgsl only.
  * **kompute:** the GPU branches of `atomicAdd/Load/Store` are inline assembly - `OpAtomicIAdd`, `OpAtomicLoad`,
    `OpAtomicStore`, Device scope, relaxed semantics (WebGPU's) - probed first (all four instructions present in the
    output); the `noinline` dummies deleted; the CPU branches untouched. The barrier is kompute's own inline
    `OpControlBarrier` (workgroup scopes, acquire-release on workgroup memory): `std.spirv.workgroupBarrier` is an
    ordinary function, so called it left the barrier in a function of its own, where the uniformity check
    (`checkBarrierUniformity`, one function at a time) could not see an early return before it - found when the corpus
    showed calls to a generated `spirv_workgroupBarrier()`.
  * **spv2wgsl:** the four opcodes in `types.Op`; `markAtomicBindings` taints the root of each atomic instruction's
    pointer (operand 2, or 0 for the store); `emitAtomicOp` and `emitControlBarrier` write the same builtins the helper
    lowering wrote; `opShape` learns the four (an unmodelled opcode defaults to "has a result", so the store's pointer
    was taken for a result type - six kernels aborted until then); the barrier check looks at `OpControlBarrier`; the
    helper interception removed (no fixture used it). 60/60 translator tests.
  * **Proof, all 192 kernels:** identical atomic operations, barriers and `array<atomic<u32>>` types, kernel by kernel.
    Text: 149 identical, 10 differing only in id-derived names (removing the helpers renumbers the ids: `_N`, `SN`,
    `pN`, `phiN`, `undef_N`), 33 with compiler scaffolding around the inlined atomics (an identity `bitcast<u32>`, a
    dead-branch ladder) - byte identity was never possible for this change, unlike the bindings. No WGSL validator here:
    naga is built from Rust (`tools/validate_wgsl.sh`, absent binary); the native host running this SPIR-V on lavapipe
    is the next check. kompute's comment citing a `zig build wgsl-validate` step (none exists) that "flags" barrier
    uniformity (naga does not) corrected. **Web risk to note:** every compute example's WGSL changed in this way; worth a
    look on the phone with the launcher.

* **Oct 6 (later) - the fluid_sort standalone for Simon's check; kernels embedded per platform.**
  * **`fluid-sort-standalone`** (release) built for Simon to check the real atomics on a device - its counting sort is
    the heaviest atomic user. Its first build failed one step: the repository-wide `lint-check` (a dependency of every
    standalone) found two findings in the `kernels-wgsl` step I had added to `build.zig` without linting it (an untyped
    `getOrPut` result, a 125-column line). Fixed; 341/341 steps.
  * **Kernels on the native host, no example changed:** `ShaderPipeline.addComputeOutput` returns the whole
    `ComputeOutput` (`addCompute` keeps returning the WGSL); `addComputeImport` and `addComputeKernelImports` take a
    `KernelEmbed` - `.wgsl`, or `.spirv`, the kernel file's SPIR-V holding every entry - under the unchanged
    `<entry>_wgsl` import name; `wireComputeKernels` picks it from `ctx.vulkan_shaders`. The web's 192 kernels are
    byte-identical; the launcher still stops at the 7 compute calls. **Next:** those calls in the Vulkan host, and
    `compute_host` reading binding numbers from kompute's declarations natively (its WGSL scans are text; natively the
    bytes are SPIR-V).

* **Oct 7 - THE WINDOWS LAUNCHER BUILDS (Simon: "Works. Continue" - the fluid_sort standalone with real atomics runs
  on his device).** `zig build launcher-windows` -> `zig-out/windows/launcher.exe` (17.5 MB), all 32 flagships through
  the Vulkan host. No link errors followed the compile errors: the browser-only declarations are not reached natively
  (S2's gating). No example changed.
  * **The Vulkan host's compute:** `RenderPipelineSlot`/`RenderPassSlot` became `PipelineSlot`/`PassSlot`, the pass
    carrying its bind point (`.graphics` or `.compute`), so `bindDirtyGroups` serves both; `compute_pipelines` and
    `compute_passes` pools; `createComputePipeline` (one entry of the kernel file's module, through `entryName`; the
    bindings were all in the generated `vk.zig` subset already); the seven calls - begin (a full barrier, as every
    pass), set pipeline (every group dirty), set group (recorded), dispatch (dirty groups bound, then `cmdDispatch`),
    end (nothing recorded: the next pass's barrier orders what follows), destroy (deferred). 4 stubs remain, none
    reached by the launcher.
  * **`compute_host`, platform-neutral:** the binding numbers now come from kompute's declarations on both platforms -
    `M.g.bindingOf(.field)`, `M.g.uniform_binding`, new in both forms of `Globals` - with the WGSL parse kept on the
    web as an assertion that they agree; a kernel whose bytes are SPIR-V (`isSpirv`: the magic word, not an
    `isWasm()` gate) lists every field in its layout (Vulkan accepts bindings a shader does not use). The module call
    needed no change: the host's `deviceCreateShaderModuleWgsl` takes the embedded bytes as SPIR-V natively, as it
    does for `draw3d`'s shaders.
  * **Checked:** the fluid_sort standalone (341/341, lint-check included - one 121-column comment fixed),
    `hello-world-windows`, `vk-host-test`, lint 0. **Not yet:** any compute running natively. **Next:** a kernel
    (`double_it`) built to SPIR-V and run on lavapipe from `vk-host-test`, its result read back and checked; then the
    run-time `isWasm()` gates the launcher meets, the worker (jobs) backend natively, persistence, the editor.

* **Oct 7 - review of the recent code, part 1: the Vulkan host and kompute (Simon: "Review all recent code. Make it
  perfect and understandable").**
  * **A fourth misplaced doc comment, in my own edit of the previous turn:** `uniform_binding` and `bindingOf` were
    inserted above the LAST line of `Globals.bind`'s doc, so `bind`'s explanation documented `uniform_binding`,
    `bindingOf` had no doc, and `bind` kept one line. Restored, each declaration with its own doc; the explanation
    rewritten without its ticket number ("t1178") and capitals. The rule alone was not enough: edits now go through
    one helper that finds a declaration's doc block and inserts above it (`zigedit.insert_above`, in the scratch tools).
  * **The Vulkan host:** `Pool.find` duplicated `entryOf`'s lookup - both now share `entryAt` (the entry a handle's
    slot names) and `holds` (live, and the same generation); the timeline's counter is read in one place,
    `readCompleted`, which `retireCompleted` and `bufferReadPoll` both use (it also keeps `completed` up to date from a
    poll); `ReadSlot`'s fields documented (`buffer_handle` - a handle, looked up again on completion because the buffer
    may be gone); the copy and read calls given descriptive parameter names (the interface check compares types
    only); the compute pipeline's bare arguments named (`no_pipeline_cache`, "not derived").
  * **kompute:** the atomics' `anytype` argument checked - `requireU32ArrayPointer`, over a tested predicate
    `isU32ArrayPointer` (a single pointer to an array of u32, either address space); capitals in the touched docs
    removed.
  * **Checked:** all 192 kernels compile with the check; 188 byte-identical, 4 differing only in numbers - the
    compiler's dead-branch ladders carry SOURCE LINE NUMBERS (`196u == 196u` became `199u == 199u` when the atomics
    moved down three lines), which also accounts for the "scaffolding" differences of the atomics change; the Windows
    launcher and hello_world; `vk-host-test`; the repository-wide lint. **Next:** spv2wgsl, compute_host and
    shader_codegen; then the input files, build.zig, the doc gate and the host test.

* **Oct 7 - review, part 2: spv2wgsl, compute_host, the shader pipeline.**
  * **spv2wgsl:** the barrier is no longer translated blind - `emitControlBarrier` reads its three operands
    (`constantValue`, from a constant's `extra_a`) and writes `workgroupBarrier()` only for kompute's (workgroup scopes,
    semantics 0x108); any other barrier is refused by name (`error.UnsupportedBarrier`), probed with a storage-memory
    barrier (semantics 0x48). `emitAtomicOp` checks its operand counts (`error.MalformedSpirv`) before reading them.
    The uniformity check's doc rewritten as a statement of the rule and its reason (it opened with a story - "learned
    from the shared-memory smoke FAIL" - and capitals); the barrier lowering's doc no longer names
    `std.spirv.workgroupBarrier`, which kompute no longer uses.
  * **compute_host:** the kernels' form computed once, `kernels_are_spirv` (guarding an empty list), used for both the
    cross-check and the field lists; `KernelWgsl` documented - its `wgsl` field holds SPIR-V natively, named as the
    import is, since 21 examples set it.
  * **shader_codegen:** `ComputeOutput.spv`/`.wgsl` documented; `addComputeImport`'s doc ("wire the WGSL") and
    `addComputeKernelImports`' ("(t1178)") rewritten for the two embeddings.
  * **Checked:** spv2wgsl's 60 tests; the 192 kernels byte-identical (every barrier passed the operand check); the
    Windows launcher; the fluid_sort standalone with the repository-wide lint; lint 0 on the five files. **Next:** the
    input files, build.zig, the doc gate, the host test.

* **Oct 7 - review, part 3: the input files. And a false check corrected.**
  * **`native_input`:** the header said the loop hands the queue "to the engine" (it hands it to the program's input
    function since the import cycle was broken) and that every rule matches the bridge (focus does not: the bridge
    releases nothing on blur) - both corrected; "PHYSICAL" lowercased. The UTF-16 decoder's numbers named
    (`surrogate_half_mask`, the two bases, `first_supplementary_code_point`) with a line on how a pair carries twenty
    bits. The queue's fields and capacity documented - held state is kept even for an event the full queue drops, so a
    focus loss releases everything; `key_number_limit` described as a bound above the highest key (348), not the
    highest key; `keyFromIndex` (the inverse of `keyIndex`, now private) replaces a nested double cast; `keyOf`'s
    nine-bit mask explained.
  * **`win32`:** the system command's `& 0xfff0` explained (Windows keeps the low four bits). `XBUTTON2` is used, by
    the tests. **`native_loop`:** two descriptions said input goes "to the engine"; it goes to the program's input
    function. **`wgpu_app`, `dom_input`:** clean.
  * **Correction:** the "repository lint rc 0" reported in parts 1 and 3 ran an EMPTY command - the command saved from a
    log two turns ago was extracted from a build that had passed, so there was nothing to extract, and the empty
    fallback was saved. Part 2's check was real (the fluid_sort standalone depends on the actual `lint-check` step).
    This turn's edits then failed per-file lint (two lines over 120 columns, from my own rewording), fixed; the real
    `zig build lint-check` (formatting and lint over `src`) passes, 6/6 steps. From now on: the step itself, never a
    command lifted from a log.
  * **Checked:** `native-input-test` 56/56; `hello-world-windows`, `launcher-windows`. **Next:** build.zig, the doc
    gate, the host test.

* **Oct 7 - review, part 4 (the last): build.zig, the doc gate, the host test. Review complete.**
  * **build.zig:** the Windows programs' comment ("Until the port is complete...") and the launcher step's description
    ("incomplete: its compile is the to-do list" - it compiles now) restated as what is true: a call the host has not
    written fails a compile by name. `flagships` is shared (the web launcher's loop follows its declaration).
  * **The doc gate:** its header rewritten as a plain statement of the six properties (it cited a plan file and "the
    turn", told two stories, used capitals throughout, and called the unchecked property "a fifth"); `basename`
    aliased; `Page`'s fields documented.
  * **The host test:** `createRenderTarget` replaces three copies of one texture descriptor; both checks say how they
    fail (the validation layer's messages); `readBack`'s sizes come from its words, and `defer` releases the read and
    the buffers on every path, the early failure included.
  * **Autofix, understood:** `-Dautofix` is on by default (since Oct 3), so every build applies the linter's mechanical
    fixes and `zig fmt` in place before checking. Its lint fix covers `tools/*.zig`, but its `zig fmt` covers only `src`,
    `examples`, `build.zig` and `tools/zimrlint.zig` - so a fix in another tool is half-applied (a trailing comma on a
    one-line signature: `vk_host_test.zig`'s new helper) and the check then fails on it. Reproduced with the real step.
    Two descriptions claimed `zig build fix` is "the only step that edits files" - corrected. **Proposed:** collect the
    lint's walked paths and give `zig fmt` (the apply run and both checks) the same list.
  * **Checked:** the real `lint-check` 6/6 with all 843 sources byte-identical before and after (fingerprinted - a
    clean tree must come out unchanged); `vk-host-test`; `doc-gate` and `tools-test` (3/3); the Windows builds.

* **Oct 7 - the format runs cover what the lint covers.** The gap found in the review: the lint walks `src`,
  `examples`, `tools`, `webtests` and `scripts` (with their exclusions) plus `build.zig`, but every `zig fmt` run
  named fixed directories - `src`, `examples`, `build.zig`, `tools/zimrlint.zig` (and the template) - so 44 linted
  files were never formatted or format-checked, and a lint autofix in one of them was left half-applied. Now the walk
  records its paths (`lint_paths`) and all five fmt runs - `fmt` (the step), `fmt_check`, `fmt_check_install`,
  `fmt_apply_gate`, and the `fix` step's - are built by one helper, `addZigFmt(mode, paths, extra_paths)`, over that
  list (the template's two paths kept as an extra where they were). All 44 were already formatted, so nothing was
  rewritten. Descriptions corrected: `zig build fmt` claimed `tools/`; the `fix` step's comment called it "the ONE step
  that rewrites sources... never implied by any other step" (autofix does it before every build). **Proven:** the
  one-line, three-parameter signature restored in `tools/vk_host_test.zig` - the real autofix gate now completes the fix
  (comma, then format) and passes, the file ending in its correct form; with `-Dautofix=false` an unformatted line in
  the same file fails the gate by name and is left as it was; a clean tree passes with all 851 sources unchanged;
  `hello-world-windows` builds behind the gate.

* **Oct 7 - THE FIRST KOMPUTE KERNEL RUNS NATIVELY.** `vk-host-test` gained a `compute` check: `double_it` from its
  SPIR-V on lavapipe - module, layout, pipeline layout, compute pipeline (`double`), bind group, a pass, a dispatch of
  16 workgroups, a copy, a read - 1000 floats doubled, the 24 past the count untouched (the last workgroup's lanes
  past it take the kernel's early return), no validation message.
  * **No duplicated constants:** the build gives the test the kernel twice - `double_it_spv`, built by the same
    `ShaderPipeline.addComputeOutput` as the apps' kernels, and `double_it` itself compiled for the CPU with a host
    kompute, as `compute_host` sees it - so the test reads `config.max`, `config.workgroup`, `Params` and kompute's
    binding numbers (`g.uniform_binding`, `g.bindingOf(.data)`) from the kernel file.
  * **The blobs** are written by hand (the engine's encoders live in `gpu.zig`, which imports `wgpu.zig` by path - a
    module of its own for the test would hold `wgpu.zig` twice), in the format `gpu_abi`'s decoders read, each value
    named: `wgpu.zig` now re-exports `BindingKind`, `BindingResource` and `TextureViewDimension` beside `ShaderStage`.
    One row per entry (`layout_words[1..6].* = .{ ... }`), since `zig fmt` puts a long literal list one word a line.
  * **Next:** an atomics kernel natively (the counting sort: clear, count with `atomicAdd`, prefix, scatter), then
    `compute_host`'s own native path (`Compute(M).initGpu` with SPIR-V kernels: `isSpirv`, declared bindings, every
    field in each layout) from the same test.

* **Oct 7 - atomics run natively; a pass's dispatches ordered.**
  * **Host bug found while writing the test:** the compute pass recorded its dispatches back to back. WebGPU orders a
    pass's dispatches (each sees what the ones before wrote - Dawn inserts barriers); Vulkan orders nothing by itself,
    so `countGrid` could overlap `clearGrid`, and `compute_host` puts many dispatches in one pass (the fluid's
    sub-step, eleven). Now every dispatch after a pass's first waits behind a full barrier (`PassSlot.has_dispatched`).
  * **The `sort` check:** `sort_min`'s counting sort - clear, count (`atomicAdd`), prefix sum, scatter (`atomicAdd`,
    its returned value the slot) - four dispatches in one pass, 64 particles in 32 cells, checked against the same sort
    on the CPU: each count, each first slot, each particle inside its cell's range, the result a permutation of the
    input. Passes on lavapipe, no validation message: the atomics' SPIR-V runs natively.
  * **Shared test pieces:** `KernelBindings(Kernel)` (the uniform and a storage buffer per `Buffers` field at kompute's
    bindings, one group for every entry - how `compute_host` binds natively), `readBufferInto` (the read check uses it
    too), `workgroupsFor`; `double_it`'s check rewritten on them. The test imports `zm` for `clamp`, as the kernel's
    own `cellOf` does (`std.math` is banned outside zimrmath).
  * **Limitation, unresolved:** with the barrier removed, the sort still passes - lavapipe runs a command buffer's
    dispatches one after another - so the test does not yet guard the ordering it was written for. Synchronization
    validation would (it reports hazards from the command stream, whatever the driver does), but neither
    `VK_KHRONOS_VALIDATION_VALIDATE_SYNC=true` nor `VK_LAYER_ENABLES=VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_
    VALIDATION_EXT` produced a message with the layer (1.3.275, enabled by name, no settings in code). To investigate:
    `VkValidationFeaturesEXT` in the instance's chain, and whether the host's messenger receives those reports.

* **Oct 7 - synchronization validation, investigated; the compute check made an ordering guard for real GPUs.**
  * **Established:** the layer (1.3.275) reads a settings file (`VK_LAYER_SETTINGS_PATH`, `validate_sync = true`, its
    own log file) and confirms "Current Enables: VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION" - yet with
    the barrier removed it reports NO hazard: not for the sort (mostly atomic accesses), and not for a textbook case,
    two non-atomic `double_it` dispatches on one buffer in one pass. So the checker does not see these dispatches'
    buffer accesses at all - its reflection of zimr's SPIR-V, or a limit of this version; not settled. Open item.
  * **Kept:** the `compute` check now dispatches `double_it` twice in one pass and expects x4: on a GPU that overlaps
    dispatches, a missing barrier shows as floats only doubled. lavapipe runs a command buffer's dispatches one after
    another, so there it holds either way (documented in the check); the test builds for whatever machine it runs on,
    so on Simon's Windows machine with the Vulkan SDK it is a real guard.

* **Oct 7 - the road to every platform: `src/notes/platforms_plan.md`** (Simon: "At the end of this we will have zimr
  on all platforms ... make the plan from here to there 3 times more precise ... the best future proof decisions
  regarding ios, macos, linux, android"). Eleven decisions - one native host on Vulkan 1.3 core everywhere; Apple
  through KosmicKrisp (conformant 1.3 on Apple Silicon, 1.4 in Mesa 26.2, iOS expected) with MoltenVK as fallback;
  Android through NativeActivity with Vulkan 1.3 required; system libraries loaded at run time on Linux, linked on
  Apple; one platform contract with a module per system; keys by physical position through one table per key-number
  family; jobs on threads; saved state as files; the engine's mixer with one audio output per system; gamepads as
  the web's standard gamepad; testing by running (Xvfb and weston here) - and phases A to I with numbered steps,
  files, verification and exit criteria. From here this journal records progress; the plan holds the road.

* **Oct 7 - the platforms plan, version 2, after studying raylib and sokol** (Simon uploaded both: "make sure we really
  have the best possible strategy"). Sixteen lessons, each tied to its source (raylib's `rcore_template.c` contract,
  its Android surface rebind and paused-loop wait; sokol's callback model, feature matrix, Android thread handoff,
  Vulkan swapchain notes, drag-loop timer, frame-time filter, X11-only Linux, ALSA audio; GLFW's XKB key names, XIM
  text and controller database). New decisions: an explicit platform contract with a template and `unsupported`;
  sokol's event set in the engine (closing the web's held-key gap); surfaces attached and detached with three
  swapchain states; a filtered frame clock; an engine mixer with a `stb_vorbis` port; a headless platform running
  every flagship; X11 before Wayland. **Proven by probes here:** macOS executables (arm64, x86_64) build with no SDK
  when the Objective-C runtime and AppKit load at run time; an Android NativeActivity library builds with no NDK
  against stub libraries; lavapipe offers headless, Xlib, XCB and Wayland surfaces. **Found in our code:** no drag
  loop on Windows (the window freezes while dragged), the surface made once with the device, one swapchain path that
  panics instead of skipping; native audio needs a mixer, a Vorbis decoder and an analyser before any output.

* **Oct 7 - SDL3 read; the platform API decided (`src/notes/platform_api.md`); the plan's version 3: the web and
  Windows first.** From SDL3: the main callbacks (zimr's shape already: the runner, `update`, the input calls); the
  backend contract's text-input mode (start with properties, the caret's area, composition, the screen keyboard); the
  high-DPI table (which platforms speak physical pixels); gamepad buttons by position; its Windows backend's drag and
  menu loops (releasing held keys on entry), the AltGr rule, focus regained. SDL's web backend reads `keypress` and
  composes nothing, so the web's text follows egui's hidden-input "text agent" instead. The API: the `Event` union
  (keys with modifiers, text and composition, mouse with movement, touch with cancel, lifecycle, the results of
  asynchronous requests, gamepads), the requests and queries (each with its web and Windows implementation), text
  input as a mode, positional gamepads, pushed audio, the GPU host's surfaces, and a nine-step migration. Found on the
  way: the web build delivers no relative mouse motion at all (pointer lock cannot report movement), and has no
  fullscreen request, wake lock or gamepads.

* **Oct 7 - A1 done: the engine's compute path runs natively.** `vk-host-test` gained the `engine` check: `z.Compute(
  double_it)` from the kernel's SPIR-V through `initGpu`, `upload`, a batch of two `run`s, and `readLatest` polled until
  `readGeneration().mirrored` reaches the batch's `submitted` - x4 on every covered float, no leak under a debug
  allocator, no validation message. The test now imports the whole engine built for the host on the native host
  (`zimr_vulkan_mod`: the five Windows options, the C library for `dlopen`) - the first time the engine, not only the
  Vulkan host, compiled for Linux natively. Two module facts learned: a second module rooted at `wgpu.zig` beside the
  engine (which imports `wgpu.zig` by path) is refused, while two modules rooted at the same file (`kompute.zig`, for
  zimrnum and for the kernels) are accepted; and `build.zig` already had a `zimr_native_mod` (the CPU-only engine of
  the PNG tools, web options, no C library), hence the new one's name. Lint: the engine is imported as `z`.

* **Oct 7 - review against Mach; the tutorial's 12.4 to 12.6** (Simon: every second turn, expand the backends
  tutorial and compare with SDL, sokol, raylib and Mach; he uploaded Mach). Mach's findings are in
  `platforms_plan.md` section 8 (gestures for macOS; keysym-mapped X11 keys as the counter-example to XKB names; a
  thinner Windows layer than SDL's; run-time loading and ALSA as ours; pulled audio). The tutorial gained 12.4 Atomics
  and barriers (the lost-update example, kompute's inline instructions, the WGSL translation, uniform control flow),
  12.5 Compute passes (one entry per pipeline, groups bound at dispatch, the dispatch-ordering barrier drawn as a
  timeline) and 12.6 Compute in the engine (the two forms, declared bindings, layouts, reading by generation); 12.3's
  last paragraph corrected (both platforms take the declared numbers). `doc-folds` had failed on four blocks naming
  declarations renamed in the review (`bufferReadPoll(handle`, `RenderPassSlot`, `bindDirtyGroups`, `addWindowsApp`)
  - the review should have run it; fixed, and a second run changes nothing.

* **Oct 7 - A2, first half: the sweep's judge in the engine.** zimrnum's GPU sweep (`zimrnum_field`) judged each
  case against CPU references and inputs built inside the example; a native sweep would have needed a second copy.
  Moved into `src/gpu/zn_conformance.zig` (its header already argued the judge is engine code): `Fixture` - the six
  inputs (`a`, `b`, `positive`, `unit`, `mask`, `tiny`) and one reference per case, carved from one allocation,
  built in three named steps (`fillOperands`, `fillDerivedInputs` with `fillTiny`, `computeReferences`), with
  `inputFor` - and `barFor`. The example holds one `fixture` (its `buildFields`, mask loop, `barFor` and six frees
  gone; its field names renamed mechanically). The moved comments rewritten neutrally, the tiny band's worked numbers
  kept. A new test checks each input's promised domain and the single free; the file's five tests pass (run directly
  with the fast tier's modules); the `zimrnum_field` page builds in release; lint clean.

* **Oct 7 - A2, second half: zimrnum's sweep runs natively; a host bug and a portability bug found.**
  * **Shared:** the four pipelines' parameters moved into `zn_conformance` as `binaryParams`, `matmulParams`,
    `unaryParams`, `rlBinaryParams`, each taking the kernel file's own `Params` type (no kernel import; a wrong field
    is a compile error); the example uses them.
  * **The check:** `vk-host-test`'s `zimrnum` - the four kernel files' SPIR-V and CPU modules, `spirvEntries` (every
    entry of a file on the file's module), `runAndRead` (run, then poll until the generation holds it), all 112 cases
    unrolled (an eval-branch quota of 20 000), judged by `compare` and `barFor`.
  * **Host bug:** `compute_host` releases each pipeline layout once its pipeline exists - correct WebGPU - while the
    host destroyed the `VkPipelineLayout` its pipelines still bind with (A1's single kernel passed by timing; the
    sweep's first kernel crashed). Now the layout's slot counts its pipelines and records the app's release
    (`retainPipelineLayout`, `releasePipelineLayout`); the layout dies when both are gone.
  * **Build: modules per target.** A compile error, then a compiler crash, from the module graph: zimrnum's `kompute`
    declares the web's target, and the test's own `kompute` beside it. **Correction to the A1 entry:** two modules
    rooted at one file are refused once both are analysed - A1 passed only because zimrnum's `kompute` went unused.
    The test now builds its own host `kompute`, zimrnum and zimrrl (plan step A5 for the Windows context).
  * **Result:** 110 of 112 agree; `expm1` and `tanh` on the tiny band fail by a few percent - Kahan's `expm1` needs
    `log(u)` accurate relative to its tiny value, which the Vulkan and WGSL precision rules do not promise near 1
    (absolute 2^-21); the phone's `log` happens to be better. To fix in `zm.expm1` (a polynomial for small `x`).
  * The check fails until then, deliberately. Lint (one long line of mine fixed), the `zimrnum_field` page and
    `hello-world-windows` pass.

* **Oct 7 - `zm.expm1` made portable; all 112 zimrnum cases agree natively; the tutorial's 12.7; the review.**
  `zm.expm1` sums its series below `|x| = 0.5` (nested form, from the innermost term out; 8 terms for f32, 14 for f64)
  and uses `e^x - 1` beyond - no `log`, so no reliance on a bound the specifications state only absolutely near 1.
  Its doc rewritten neutrally (it had capitals and a story); `tanh`'s stale first line corrected. A new test checks it
  against `std.math.expm1` over thirty decades of each sign (relative error under 4e-7 at f32, 1e-15 at f64); zm's
  `tanh`, `mish` tests and zimrnum's `tanh`/`sigmoid` gradient tests pass; all 193 kernels translate (37 changed,
  those built on `expm1`); the `zimrnum_field` page builds; lint clean. `vk-host-test` passes every check, the
  `zimrnum` sweep included. The tutorial gained 12.7 Precision (the specifications' bounds in a table, the worked
  `x = 1e-6` example, the rule). The review (object lifetimes against Mach, SDL and sokol; precision) is in
  `platforms_plan.md`, with a new audit step A6. **For Simon:** the web's GPU sweep (`zimrnum_field`) now runs the new
  `expm1` on the phone too.

* **Oct 7 - A5 and A2 done: numerics modules per target; the host test for Windows.** `build.zig` gained
  `addNumericsModules(target)` (kompute, zimrnum and zimrrl for one target - a null target inheriting the compiling
  root's) and `addVulkanHostTest(target, inputs)`: the test's whole graph - the engine on the native host with the
  target's numerics, the six kernel files from one table (`host_test_kernels`: each as `<name>_spv` and as its CPU
  module), the conformance table - as a function of the target. `vk-host-test` builds it for the build machine and
  runs it; the new `vk-host-test-windows` builds it for Windows (6 MB, debug) - the C library linked only off Windows,
  where the loader opens with `LoadLibraryW`. The Windows context's engine and apps now use Windows numerics modules
  instead of the web's (A5); the launcher and hello_world build. Lint: three long lines of mine split.

* **Oct 7 - A6 done: object lifetimes as WebGPU's; the tutorial's 3.6.** The bridge's release calls: `destroy()`
  for buffers and textures, a table release for everything else. Audited against the host: open encoders keep released
  objects (counted until `queueSubmit`, so a finished but unsubmitted command buffer is covered); the gap was bind
  groups, which did not hold their views and samplers. Now `SamplerSlot` and `TextureViewSlot` count their bind groups
  and record the app's release; `BindGroupSlot` lists what it holds (`HeldBindable`) and drops it on release, its
  descriptor set deferred alone (`DescriptorSetSlot`); one `Holder` enum (`app`, `dependent`) serves layouts, views
  and samplers. The new `lifetimes` check releases both ways round; broken on purpose, the validation layer reported
  the four leaked objects (`VUID-vkDestroyDevice-device-05137`) and the check failed. Lint moved
  `max_bindings_per_group` and `Holder` above their users. The tutorial gained 3.6 Objects that hold others (the two
  ways to let go, the table of what Vulkan needs held, compute_host's pattern step by step).

* **Oct 7 - the Windows launcher handed to Simon** (he asked for it as soon as it had a chance to run). The case for
  a chance: hello_world runs on Windows; the host's rendering, compute, atomics, readback and lifetimes pass headless;
  the four remaining host stubs are compile errors the launcher never reaches; no native branch behind an `isWasm()`
  check panics (scanned: runtime, ui, web, sound, host, jobs, the app and runner); jobs run inline natively
  (`runInline`, when `web.jobs.available()` is false). Two builds: `launcher.exe` (`-Dmode=release`, ReleaseSmall, 9.9
  MB) and `launcher-debug.exe` with its `.pdb` (Debug, 17.5 MB: stack traces). Known absent natively, not bugs: sound,
  saved state, clipboard, text editing beyond typing, pointer lock, gamepads, fullscreen, frames during a window drag.
  The release build first refused to start - the disk 97% full, `.zig-cache` 6.6 GB - and the cache was cleared
  whole, as its guard advises (single entries must not be deleted), with the unpacked references (re-extractable from
  the uploads) and old `/tmp` experiments: 7.3 GB free.

* **Oct 7 - Simon's first launcher run (RTX 5070, Vulkan 1.4, validation on): `shader 'pbr3d_vs' is not SPIR-V`.**
  Apps that embed the engine's shaders (`@embedFile("pbr_vs.wgsl")`, the PBR examples) were wired by `wireEngineWgsl`
  from the context's list, and the Windows context had inherited the web's list: WGSL. (The engine's own module
  already embedded SPIR-V under the same names, which is why hello_world ran.) Fixed: the list is per context -
  `engine_shader_embeds`, records `EngineShaderEmbed`, helper `wireEngineShaders` (33 configure references renamed)
  - the web's from the WGSL paths, the native one from the loop's `engine_spirv`, under the same `<shader>.wgsl`
  names, so no app changes. Audited the other routes WGSL could take: no `.wgsl` files exist; the seven examples
  with inline WGSL are none of the 32 flagships; every other `createShaderModuleWgsl` caller gets embeds. Measured:
  the crashing build held 6 `@vertex` and 17 `@fragment` markers, the fixed debug and release builds none.
  **Guard so it cannot recur:** `tools/native_wgsl_check.zig` reads a linked native program and fails on the first
  WGSL entry marker, quoting the text after it; `addWindowsApp` runs it before every install (the context's new
  optional `native_wgsl_check`), as does the Windows host test's install; its test is in `tools-test`. On the
  crashing build it fails quoting `@vertex fn entry(inputs: entryInputs)...`. **Also:** the debug build's stack trace
  showed only `???` because I renamed `launcher.pdb` - the executable records its symbol file's name; the debug build
  now ships zipped under its own names.

* **Oct 7 - THE LAUNCHER RUNS ON WINDOWS (Simon, RTX 5070, Vulkan 1.4, validation on).** His log: two errors and a
  warning, none seen on lavapipe's older layer.
  * **Compute pipelines invalid after their set layouts went** ("references VkPipelineLayout which became invalid
    because it references deleted object VkDescriptorSetLayout... enabling the maintenance4 allows you to destroy the
    VkPipelineLayout and child objects after being used"): `compute_host` releases each bind group layout at once,
    as WebGPU allows. Fixed by requiring and enabling Vulkan 1.3's `maintenance4` - mandatory for 1.3 devices, so no
    device is lost; lavapipe has it. The count of a layout's pipelines stays (a pipeline layout must still outlive
    the commands recorded with it).
  * **Sets bound against empty layouts** (`mandel_sbs_gpu`: the 2D renderer's `ortho_ring` and `resources_bg` still
    bound in slots 0 and 1, the shader runtime's pipeline layout empty there - it fills the slots below a custom
    shader's groups with empty layouts). WebGPU accepts it; Vulkan requires a bound set to match, and needs nothing
    bound where shaders read nothing. Fixed: each pipeline layout records its empty sets (`empty_sets`, from handle 0
    or a layout with no entries), pipelines carry them, `setPipeline` copies them into the pass, and
    `bindDirtyGroups` binds nothing there.
  * **Warning, left for now:** "vertex attribute at location 2 not consumed by vertex shader" - WebGPU allows
    unread attributes, and the cost is one fetch. Dropping them needs the vertex shader's input locations
    (`spv_vulkan.reflect` gives them), but a reflection that missed an input declared another way would silently
    break rendering; to do with a check that renders every vertex shader (the headless platform, B8).
  * Lint moved `GroupSet` and `max_bind_groups` above their new user. The tutorial's 3.6 and its binding section
    say both. `vk-host-test` passes every check; the launcher rebuilt in debug and release.

* **Oct 7 - Simon's second run: the errors gone; the vertex-attribute warning traced to the fractal demos and
  fixed at its source.** They load their shader through `loadShaderVF`, whose default layout describes all of
  `Vertex2D` - position, UV, color at location 2 - while their vertex schema (`trivial_vs_io`: `Attributes` with
  locations 0 and 1) reads two; the schema's own doc said color was "part of the layout (so the vertex buffer stride
  matches) but not consumed". The stride belongs to the buffer, so the attributes can shrink while it stays 20: the
  runtime's default layout now describes only the locations the vertex schema declares - `loadShader`'s body became
  `loadShaderReading(Schema, read_locations, desc)`, `loadShader` passes null (every attribute), `loadShaderVF` the
  schema's (`AttributeLocations`), and `DefaultVertexAttributes(read_locations).list` keeps those of `Vertex2D`'s three.
  Exact - the schema states what the shader reads - so none of the reflection risk set aside last turn; on the web
  too. The two helpers return types holding static constants (`list`), after lint caught that slices of a local
  would dangle if the helpers ever ran at run time; this Zig's `@typeInfo(...).@"struct"` offers `field_types`, not
  `fields`. A test (run fresh, its single pass confirmed - a cached run reports no counts); the fractal page and the
  launcher build; lint clean.

* **Oct 7 - A3 done: the Vulkan host implements every host call.** The last four stubs: mip-level and array-layer
  views through one `createTextureView(texture, ViewRange)` (bounds checked; a view's extent its base level's,
  since a pass sizes itself from its first view); `adapterInfo` (`Gpu` now keeps the vendor id and Vulkan version;
  the browser's `vendor | ... | description` shape; lavapipe: "Mesa | llvmpipe (LLVM 20.1.2, 256 bits) | Vulkan 1.4");
  `encoderCopyTextureToBuffer` (level 0, layer 0, from the corner; WebGPU's byte pitch as Vulkan's texel row length;
  a full barrier; images in the general layout). The unimplemented-calls heading removed. `vk-host-test` gained
  `copy` (cleared to 0.2/0.4/0.8/1.0, read back as 51/102/204/255 exactly, padding skipped), `views` and the adapter
  line. The tutorial: 8.6's views paragraph, a new 8.8 Copies from textures (the 256-byte pitch drawn), samplers now
  8.9; one block's declaration followed the autofix's multi-line signature. Lint, the Windows test and launcher pass.

* **Oct 7 - B1 done: the platform contract as Zig.** `src/platform/contract.zig` translates `platform_api.md`
  sections 3 and 4: the `Event` union and payloads, the request types, `requests` (name and exact function type, 24
  of them; parameter names do not count in Zig's function types), `problemsOf` (one line per missing request or wrong
  type) and `requirePlatform` (a compile error listing them all). `src/platform/template.zig`: every request refusing
  with `template platform: X is not written`. `src/platform.zig` is the namespace (test roots must sit above the
  files they import). Tried: the template with `log(level: u8, ...)` fails as "breaks the contract: `log` is fn (u8,
  []const u8) void; the contract's is fn (log.Level, []const u8) void", and no refusal fired. Lint split one line.

* **Oct 7 - review of the contract against SDL3, sokol, raylib and Mach; tutorial chapter 13.** Re-extracted only
  the files that define each one's platform surface (SDL3's `SDL_events.h`, `SDL_video.h`, `SDL_keycode.h`;
  `sokol_app.h`; raylib's `rcore_template.c`; Mach's `src/Core.zig`). Recorded in the plan's section 8: no reference
  checks names and types at compile time (SDL3: function pointers, null = unsupported; sokol: one file per platform
  section; raylib: a template file; Mach: an OS switch, its `assertHasDecl` unused). Adopted for B3: `KeyDown` gains
  the layout's character for shortcuts (SDL3 keycode, the DOM's `key`). Deferred: dropped files (B4), the phone life
  cycle, safe area and on-screen keyboard (Phase F), device changes (audio, GPU). Left out: window management. The
  tutorial's chapter 13, The platform layer: who owns the loop, events, requests and queries (asynchronous outcomes
  drawn for the browser and Windows), units (a table, and why time is integer nanoseconds), the contract's check
  (its failure message), starting a platform; four code blocks from `contract.zig` and `template.zig`.

* **Oct 7 - B2, first part: `receiveEvent`, and Windows input through the contract.** `wgpu_app.zig`'s
  `receiveNativeInput` became `receiveEvent(contract.Event)`: an exhaustive switch, the eight events a platform
  reports today mapped to the bridge's `inputPush*` calls (behaviour unchanged), the rest named as reported by no
  platform yet. `native_input.zig`: the queue stores `DomButton` (Windows' own numbering is the DOM's), so
  `engineButton` left it - the engine maps once, through `dom_input` - and its mapping test now checks
  `dom_input.mouseButtonFromDomButton` itself; `ContractEvents` converts queued events (a button at the last move's
  position, a move's movement from the previous one, a character as UTF-8 - one that cannot encode becomes U+FFFD
  instead of `catch unreachable`, which lint refused). `native_loop.zig` hands contract events (`EventFunction`) and
  logs them. 58 native input tests pass (one new); both Windows programs and the web page build; the tutorial's 13.2
  shows `receiveEvent`, and 11.2's block follows `run`'s new signature.

* **Oct 7 - B2, second part: the web's input through `receiveEvent`.** The exports the bridge calls became the
  web's event producers (`webButton` puts a button where the browser's pointer last moved; `web_pointer` gives a move
  its movement; `inputPushChar` encodes UTF-8, dropping a number that is no code point - a range check, since lint
  bans `std.math` outside zimrmath); `receiveEvent` took over their bodies (no app before `App.run`: nothing
  happens; positions through `cssToLogical`; touches, touch cancel as an end, and motion now handled). The bridge's
  `engineButtonOf` became `domButtonOf` (unmapped), and `onPointerUp` passes the release's position. Keys are safe
  as `KeyboardKey` (exhaustive): the bridge only sends members `keyboardKeyFromDomCode` returned. Lint renamed
  `length` (a reserved math word) and split a line. Both Windows programs, the web page and the native input tests
  pass; the tutorial's 11.4 and 13.2 describe the new path.

* **Oct 7 - B2, third part: the two platform modules.** Surveyed what exists: `web.zig`'s `dom` already wraps most
  requests (snake_case names, which a `[a-zA-Z]+` search had missed). `platform/web.zig` maps them (cursor: the
  contract's shapes onto `types.MouseCursor`, `wait` showing the default until the bridge's table gains one; saved
  values: `persistence_size` first, null when the value does not fit - the contract's doc now says so; rumble onto
  `gamepad_vibrate`). `platform/windows.zig`: `now` (`native_os`), `size` (the new `native_loop.size()`, client pixels
  over the scale), `log` (standard error); refusals name the call awaited. `platform.current` by target;
  `requirePlatform(platform.current)` in `wgpu_app.zig`. The signature check leaves bodies uncompiled until called, so
  each module ends with a comptime list of its written requests (`_ = &now; ...`): breaking `openUrl` on purpose
  failed the web build naming the missing member. Lint: decl order (the list moved to the end, `log` to the top),
  `@trunc` for `@intFromFloat`, `zm.float`. Tutorial 13.7 (its id renamed after the gate found `platforms` taken).

* **Oct 7 - B2 continued: the headless platform; the engine's logging through the platform.** `platform/headless.zig`
  (time by `clock_gettime`, a fixed 1280x720 size, standard error; the rest refuse: no window, keyboard, sound or
  gamepads) is `current` off the browser and Windows. `zimrLogFn`, the glTF and JSON warnings and the example panic
  reporter log through `platform.current.log` (`z.platform`). The native loop's input log stays on `web.dom.log`
  until the loop moves into the Windows platform (otherwise an import cycle, which lint refuses).
* **Oct 7 - the XOR failure, studied and fixed.** Cause: the test trained at step 0.5, beyond gradient descent's
  stability limit (sharpness above 2/eta); over 100 seeds 57 diverged, and 8 (new math) or 9 (old math) met its
  bounds - the seed had been a lucky one, and the `expm1` change only reshuffled its trajectory. Replaced by two
  tests: the backward pass against central differences (`numericalGradWorst`: worst 7e-11, bound 1e-6) and training
  at step 0.1 from eight starts (every one of 100 seeds converges; margins of 10 to 16 orders; unchanged when every
  transcendental moves one step). Faults injected in a harness - gradient ascent, `tanhGrad` at the pre-activation,
  the skipped non-linearity gradient, wrong-sign updates - each fail the eight-start test. The softplus tape test's
  tail check moved from -745 (the smallest subnormal, one step above zero) to -740 (85 steps above). A one-step
  perturbation of seven transcendentals over the fast suite found only these two tests fragile.
* **Testing, from now on (Simon: "maybe we don't need all these long tests for now").** Per change: one `zig build`
  invocation naming only what the change can affect (steps run in parallel), never a chain. The fast suite is not
  run routinely; a change to `zimrmath`, `zimrnum` or `kompute` runs the affected tests by `-Dtest-filter`. Long
  training tests (the robot's PPO test runs for minutes inside `test-fast`) are for milestones. Experiments only in
  `/tmp` harnesses, never in the tree.

* **Oct 7 - `zimrnum_field` joins the launcher** (Simon's suggestion): the page computing a zimrnum field on the CPU
  and on the GPU, drawing both and their difference, is now a flagship - zimrnum's conformance on a real GPU at a
  glance, in place of long tests. The launcher's menu is its own list (`examples/launcher/launcher.zig`, one
  `z.eraseApp` per page) beside the build's `flagships`: the page needs both, and was missing from the menu until the
  second was added. Both launchers, web and Windows, built in release mode in one command.

* **Oct 7 - Simon's phone ran `zimrnum_field` in the web launcher: every case OK, CPU and GPU fields identical, then
  `assert failed at compute_host.zig:638: the WGSL's binding numbers differ from kompute's declared ones`.** A false
  alarm: `parseBindings` gave a field absent from the WGSL a made-up number above the parsed ones (left from when
  parsed numbers were the layout's), and the page builds only some of a kernel file's entry points, so some buffers
  are absent. `wgslBindingsAgree` replaces it: each binding present in the WGSL must carry its declared number; an
  absent buffer or uniform has nothing to compare (the layout uses the declared numbers either way). The `kbuf_`
  naming trap stays. The web launcher rebuilt (one command, with its lint gate).

* **Oct 7 - B2 closed: one native log.** `platform/console.zig` (standard error, the level prefix; nothing but `std`)
  is the Windows and headless platforms' `log` and the native loop's input log, which no longer reaches `web.dom`.
  A first try put it in `native_os.zig`, which pulls in the C library the headless platform must not need. One
  command checked lint, the contract and native input tests and `hello_world.exe`.

* **Oct 7 - B3, focus.** The rule "losing focus releases what is held" moved from the Windows translator into the
  engine (`receiveEvent` -> `input.releaseHeld`), so the web gets it too (the bridge listens for the window's `blur`
  and `focus`). Native: `WM_SETFOCUS` added and forwarded; `focus_gained`/`focus_lost` queued and converted. Two
  surprises, each caught by one build: `key_number_limit` has another user (a test's key set), and PrintScreen's
  swallowed press needed the held record - now one `print_screen_held` flag. Tutorial 11.8 rewritten. One command
  checked lint, the native input tests and both hello_world builds; one more the docs.

* **Oct 7 - review of the platform and input work (Simon: "verify the last few turns deeply").** Found and fixed:
  one idea defined twice (the DOM's mouse button: native_input's `DomButton`, `enum(i32)` with `x1`/`x2`, and the
  contract's raw `u8`) - now one `contract.Button`, `enum(u8)` non-exhaustive, `back`/`forward`, which the translator
  aliases; casts in the web input path that could trap on what JavaScript sends - keys now `std.enums.fromInt` (an
  unknown number is dropped), touch ids `@bitCast` both ways (an id only names a finger), buttons range-checked
  (`webButton` returns null outside a byte); `wgslBindingsAgree` now names a `kbuf_` binding that matches no Buffers
  field instead of skipping it; the contract's `quit_requested` no longer promises a behaviour not built. References
  rechecked: SDL3 resets the keyboard in its shared layer on focus loss (`SDL_SetKeyboardFocus` ->
  `SDL_ResetKeyboard`), as zimr now does; sokol and Mach only report the event - cited in `input.releaseHeld`. One
  command checked lint, the native input and contract tests, hello_world on Windows and the web; one the docs.

* **Oct 7 - B3, key labels.** Checked first how shortcuts are matched: the runtime's `isKeyChordPressed` and the UI
  derive modifiers from key states, so filling event modifiers would change nothing anyone reads, while chords
  matched letters by position (Ctrl+Z was the key printed W on AZERTY). Labels added end to end (contract, Windows,
  web, engine), letter chords now by label with a position fallback; tests: the translator carries a label, and
  the chord test (French Ctrl+Z matches, the Z position does not, an unlabelled platform falls back). One command
  for lint, input and contract tests and both hello_world builds; the chord test by filter; the docs (13.4 explains
  labels; 11's `translateKeyDown` block followed its new signature).

* **Oct 7 - B3, hidden, shown, resized; `WindowState.focused`.** Looked for consumers first: `runtime.zig`'s
  `isWindowFocused`/`isWindowResized` belong to its raylib-style layer, which no app uses; the engine's per-frame
  `WindowState` is what apps read, so it gained `focused`. Platform reports for all three events; the engine's
  reasons for keeping hidden and resized nowhere are written where it receives them. Errors one build each found: a
  method's app is `self`; the bridge's export helpers lived inside its input namespace, out of reach of the WebGPU
  one - hoisted to file scope rather than qualified (lint would refuse the forward reference anyway).

* **Oct 7 - B10 begun: every example native, and the native gallery** (Simon's design: one executable per example,
  a gallery that starts them, one build step for all). `build.zig`: a `<example>-windows` step per example from
  `wgpu_apps` (the old `hello-world-windows` folded in), `all-examples-windows`, `zimr-gallery-windows`;
  `windows_pending` with reasons, passed to the gallery as build options. `examples/zimr_gallery`: the manifest
  parsed with `std.json`, rows by module, `CreateProcessW` with four kernel32 externs of its own (the standard
  library's bindings have moved on), the run polled each frame with `WaitForSingleObject(…, 0)`. Built alone, not
  run; configuring it created every example's step without a collision. Three WGSL examples deleted (folders,
  `example_steps`, the app registry, the manifest's entries, the notes' table); `example_steps` rewritten one name
  per line after `zig fmt`'s column alignment pushed two rows past 120 columns.

* **Oct 7 - B11, the platform option and one step per app (first part).** Facts first: `zig build -l` listed 1,053
  steps, and the standalone page was a second packaging of the same wasm (`addWgpuStandalone` took `exe`). The web
  outputs stay built-and-gathered whatever the platform - `serve`, `dist` and the discovery pass walk a hidden
  `web_examples` step - and only each app's one step chooses. This Zig's build steps have fixed tags (no `custom`):
  a gathering step is a `Step.TopLevel` tagged `top_level`, made as `std.Build.step` makes one but left out of
  `top_level_steps`. Slips one build each caught: the option first landed after the `Project` API's `mode` (two
  `mode` options in the file), and lint asked for the vocabulary above its first user, `Step.init` spelled out and
  typed key iterators.

* **Oct 7 - B11, projects.** Projects edit an app's module after `addApp` (the template documents
  `game.module.addAnonymousImport`), and a module has one target and one import table - so a project builds the
  one platform its invocation names, and `addApp` returns that platform's module and program. `addWindowsApp`
  installed with the context's builder, which for a project is zimr's (the dependency): split into
  `windowsAppExe` and `installWindowsApp(install_builder, ...)`. Two patch anchors missed (a field's doc
  comment, a blank line before a `return`) - each stopped the script before it wrote anything.

* **Oct 7 - B11 done: editor configs and docs.** `gen_editor_configs.zig`: the per-example build task names
  `-Dplatform=web` (its Chrome debug config opens the page; the default is now native), and the standalone task
  became a release web task. Regenerated: 420 web tasks, no `standalone` left, four valid JSON files. Journals and
  dated measurements keep the old step names - they record what was run.

* **Oct 7 - the WGSL examples, checked for redundancy first** (Simon: before converting, look for an example that
  already shows the same thing). The catalog's descriptions searched by topic: two of the four were covered
  elsewhere and are deleted; the mip-chain and texture-array demos are unique and merge into one example of
  texture views. Zig shaders sample at an explicit level (`textureSampleLevel`) but declare no array textures, so
  the merged example shows each layer through its own 2D view.

* **Oct 7 - the texture-views example, its foundation.** Reading `pipeline_rendertarget`, `WgpuRenderTexture` and
  `beginTextureMode` showed the merged example needs no shader: a view wrapped as a render texture is a target
  for the 2D renderer. The one missing piece, a 2D view of one array layer, added to the wasm externs, the bridge
  and the Vulkan host (`ViewRange.base_layer`: a 2D view whatever the texture's layer count, base array layer set).

* **Oct 7 - `texture_views`.** The mip chain (256 down to 1, nine levels) painted once, level by level, through
  views wrapped as render textures; the four-layer array painted every frame through its layer views; shown as
  each level magnified, the whole chain at five sizes and a breathing one through a nearest-mip sampler, and the
  four layers. One lint finding (`@intFromFloat` where `@trunc` converts directly). Built for both platforms; not
  yet seen running - Simon's eyes on the web page and the native gallery are its test.

* **Oct 7 - B3, movement.** Found by asking what reads the events: `getMouseDelta` was a position difference, zero
  under the browser's pointer lock. Now the summed motion of the move events, as SDL's relative motion is. Touch
  drags keep working because the unlocked motion stays the position step (browsers disagree on `movementX` for
  touch pointers). The old test of the position-difference definition removed; the new one checks a delta while
  the position stands still.

* **Oct 7 - B3, enter and leave.** The consumer was `isCursorOnScreen`, whose flag nothing wrote (its doc
  described something else). Windows: the arrival is the first WM_MOUSEMOVE after a departure - the window
  procedure keeps `is_pointer_inside`, re-arms `TrackMouseEvent` there and forwards `message_pointer_entered`
  (WM_APP + 1), so the translator stays pure. Web: the canvas's `mouseenter`/`mouseleave`. sokol, read for the
  review, does the same on both platforms, and takes `movementX` only while locked, as zimr now does.

* **Oct 7 - B4, pointer lock's Windows mechanics.** Raw input (WM_INPUT, `GetRawInputData`) for motion,
  `ClipCursor` and a hidden cursor for confinement, focus loss ending the lock; the translator stays pure, the
  window procedure keeping the lock's state. Lint asked for a literal in place of `std.math.maxInt` (banned outside
  zimrmath) and typed locals in place of `@as(f32, @floatFromInt(...))`. `lockPointer` itself is not yet reached
  by any build - the engine's wiring next is its compile check.

* **Oct 7 - B4, pointer lock wired; `input_pointer_lock`.** The runtime cannot import the platform (a cycle through
  `native_input`), so `wgpu_app` holds `disableCursor`/`enableCursor`: input state, then `platform.current`. The
  engine's test build, compiled for the headless platform, refused - the headless lock became a decline (no pointer,
  nothing granted), a correct answer rather than a compile error. A local named `document` shadowed the bridge's
  `document()`. Reading sokol's lock moved the confinement to one point at the client centre and restored the
  cursor's position on release. The Windows build of the new example was `lockPointer`'s first compile.

* **Oct 7 - B4, title and cursor.** The UI calls `runtime.input.setMouseCursor` directly, so moving the platform
  call into a `wgpu_app` wrapper (as for pointer lock) would have dropped UI cursors; instead every cursor function
  records, and the engine applies the frame's last wish between `update` and `endFrame` (children of the launcher
  share the main input state, so they are covered). Simon's screenshot of `input_pointer_lock` showed position 0, 0
  under lock: the export now holds the position while locked.

* **Oct 7 - B4, fullscreen, keep awake, open an address; `window_requests`.** No app reached the runtime's old
  browser-only `toggleFullscreen`/`openUrl` (zimr.zig never exported its window layer), so the public API is new.
  `openUrl` on Windows passes only http/https/mailto to `ShellExecuteW`, whose `open` would also run programs. The
  browser's wake lock is released by the browser on hiding: the bridge keeps the wish and asks again on
  `visibilitychange`. The disk guard stopped a build at 98% (cache 6.7 GB): `zig-out` and the cache cleared, the
  cold rebuild of the example for both platforms under five minutes.

* **Oct 7 - B4, clipboard text and saved values.** Found while moving `state_persistence`: the browser's plain
  `persistence_save` stores bytes as text (corrupting binary), so the platform's `saveValue` became the base64
  path. Slips: Python read the Windows paths in a replacement as escapes (the code moved to a file, inserted
  literally); a local `size` shadowed the platform's `size()`; lint asked for the helpers above their users. The
  Windows clipboard was first compiled by `window_requests`' new copy button.

* **Oct 7 - two failures on Simon's phone.** A wasm import with no bridge function fails at instantiation,
  never at build time - hence the import check next. The Claude app's viewer is a sandboxed frame where reading
  `localStorage` throws; storage reads are tried now. The bridge's `new` takes at most three arguments (a guarded
  `setItem` passes the key and value as one object's properties).

* **Oct 7 - unhandled rejections.** Third failure from the viewer: a rejected `writeText`. Every browser request
  that answers with a promise can be refused; `ignoreRejection` now handles the refusals the bridge did not.

* **Oct 7 - the bridge import check.** The web's counterpart of the native no-WGSL check, from the prototype's three
  registration forms. Proven both ways: the real bridge passes, a copy without the `js_is_fullscreen` registration
  fails naming it. Tutorial 2.6 describes it.

* **Oct 7 - B4, paste.** Designed so the UI never requests on Ctrl+V: both platforms report the system's paste
  command themselves (the browser's event; Windows' keys), so a request and the browser's own paste can never both
  land. Lint caught `length` twice (a reserved math word) and an accented letter in a comment.

* **Oct 7 - the UI's native text fields.** Looking for where to insert a paste found that native fields never
  received typed characters (the snapshot's queue was filled only by tests). Reading the engine's queue without
  taking it needed it emptied each frame - otherwise every undrained character would be inserted again.

* **Oct 7 - text input studied against Dear ImGui 1.93.** The browser path is the browser's editor and matches
  or exceeds ImGui, two small gaps aside; the native path was a caret over ASCII. B5 rewritten as T1-T5 (an editing
  core, native fields on it, multiline, input methods, the browser's gaps). Taken at once: ImGui's pasted line break
  as a space in one-line fields.

* **Oct 7 - T1, the editing core.** Written from ImGui's rules (word starts from `is_word_boundary_from_right`, its
  separator list, password fields without words) and better than stb_textedit at one: typing undone a word at a
  time. All twelve tests passed on the first run; the lint then moved three helpers above their users, swapped
  `std.debug.assert` for zimrmath's, and renamed `clamp` (a reserved math word) to `keepWithinText`.

* **Oct 7 - the editing core moved into `ui.zig`** (Simon prefers large files): a `pub const text_edit = struct`
  namespace before the fields, its names checked against the file's top level first. The aliases the lint's autofix
  had added to the separate file (`copyForwards`, `eql`) clashed with the file's own and went; two lines grown past
  120 columns by the indentation were rewrapped. Its twelve tests pass among `ui.zig`'s.

* **Oct 7 - T2, the native field's keys.** The single-line widget's native block rewritten on `text_edit`; the
  patch applied all-or-nothing, and two anchors had comments my reading had filtered out (the click lines, which the
  multiline widget shares, were then found by position). The P9 tests passed unchanged - Escape's revert keeps an
  unedited field's text, so the old "leaves buffer intact" test still holds.

* **Oct 7 - compound conditions in the new code.** A scan (every `if`/`while` with two or more `and`/`or`, every
  named `bool` with three) over the text-editing core, the native field, and the session's Windows and runtime code
  found 15. Rewritten: parts named (`collapses_selection`, `continues_typing`, `copies_selection`); edits taken
  out of conditions (cut, undo, redo, deletes, Escape); labeled blocks where later parts depend on earlier ones
  (`begins_word_step`); guards in sequence for raw input; two helpers (`isInsideCharacter`, `filterKept`) and a
  third, `cutsCharacter`, for the runtime's and the example's paste cuts. The re-scan finds none. A lint rule for it
  is proposed in lint_opinionated_plan.md, not yet written.

* **Oct 7 - T2 complete: the mouse and the scroll.** Two lessons from the tests. Text measures nothing in tests
  without a loaded font, so the scroll test first passed nothing real - and a readout of ten lines hid its failure
  behind two others'; the tests now build a monospace font in place (`MonospaceTestFont`). And test frames must lay
  the field out afresh each frame: without it the second click of a double-click fell outside the moved box and
  deactivated the field. Neither was a fault in the widget.

* **Oct 7 - T3, the multiline field's keys.** The single-line native block's common part moved out unchanged
  into `editFieldNatively` (its tests passed untouched), and the multiline field now calls it. The patch stopped
  once more on an anchor whose comment lines my filtered reading had hidden; fixed by anchoring on the comment.

* **Oct 7 - T3 complete: the multiline field's mouse and scroll.** The scroll lives in the UI's per-id storage
  rather than the one-field edit state, so inactive fields keep their place and take the wheel. A test found a real
  gap: a field activated with its caret already at the end (the editor's `begin`) never scrolled to it, since the
  caret had not moved; a field beginning to edit now brings its caret into view.

* **Oct 7 - the `ui_text_editing` example, and a gap in the import check.** Building the example for the web,
  the bridge import check reported `js_set_overlay_textarea_ctrl_enter_for_newline` unregistered - but the bridge
  registers it, in a `.set(` call split across lines with the name on a line of its own, a form the check did not
  read. Every page with a multiline field had been failing its web build since the check was added. The check now
  skips spaces and line breaks after `.set(`, and its test covers the split form.

* **Oct 7 - T4, input methods on Windows.** The contract's three text-input requests now flow from the UI's active
  native field through the engine (a per-frame request, compared with the last) to IMM. Headless's compile errors
  for them became no-ops, since the engine calls them every frame, as it does the cursor. Review: SDL has the same
  three requests and inline composition events; sokol, raylib (GLFW) and Mach have no input method support.

* **Oct 7 - a turn cut off mid-build, and a full disk.** The turn that wrote T4 (input methods) applied its whole
  patch, then stopped while verifying it: the sandbox's disk was 98% full (the build cache at 6.7 GB of about
  19.5 GB), and the build's guard refuses to start below a margin. The cache, the build outputs and stale /tmp work
  were cleared (7.5 GB free); the patch, checked from a cold cache, passed its tests and both builds after one long
  line in the example was split. Turns that write and verify a patch this size are better split in two.

* **Oct 7 - T5, the browser's gaps.** Written and verified in one turn after all - small enough. The scratch
  allocations first used `catch assertUnreachable(...)`, which returns void, where a slice was expected; `@panic`
  instead, as the per-id storage does. Only builds that analyze the web branch (the web build, the tests) saw it.

* **Oct 7 - files, U1: the contract.** Touch cancel turned out done where touches exist (the browser's
  `pointercancel`, the engine's `touch_cancel`; Windows has no native touch yet), so B3's remainder became the
  asynchronous results - files chosen and saved. The ten requests' refusal bodies for Windows and the template were
  generated from one list of signatures, so the four modules cannot drift apart.

* **Oct 7 - files, U2: Windows.** The press check lives in the loop's `deliverInput`, the files' state beside it:
  the platform module imports the loop, so the loop could not call back into it without an import cycle. The lint
  asked for literals instead of `std.math.maxInt` (banned outside zimrmath), bottom-up order, and two names off its
  reserved list (`dot`, `length`). `geno_ppo`, `getup_train` and `mocap_viewer` build for Windows; only
  `net_rtc_smoke` (WebRTC) and the two WebSocket examples remain pending.

* **Oct 7 - one WebSocket protocol for the servers and the native client.** Removing the servers' copies by
  their attached comments went wrong once: the GUID's line ended in a trailing comment, so the search for its end
  ran on and took the next declaration (`default_port`) with it; a before-and-after list of each server's
  declarations caught it. Verified by tests (RFC 6455's accept example, masked and unmasked frames of short and
  extended lengths) and live: a raw client's handshake got the RFC's accept, its masked JOIN was read, and the
  unmasked WELCOME came back.

* **Oct 7 - the native WebSocket client.** Built on this Zig's `std.Io` (a `Threaded` I/O made at the first
  open, `Io.Mutex`, `HostName.connect`, `io.random`), after websocket.zig's client and sharing the servers' protocol.
  A patch script failed on its last anchor after the lint's autofix had rewritten `std.testing.expectEqual` to its
  alias, which lost the whole batch: the edits were redone with flexible matches, each applied on its own.

* **Oct 7 - a deep review of the WebSocket code.** The worst fault had passed every test and the live run: the
  live messages were short, and `take(n)` asserts the reader's buffer holds n bytes, so any frame over 16 KB would
  have crashed the client - the servers escaped only by sizing their buffers to their largest message. A regression
  test now reads a 300-byte frame through a 64-byte buffer (`std.Io.Reader.Limited`). Also learned of this Zig: the
  `**` operator is gone (`@splat` instead), and `std.ascii.indexOfIgnoreCase` is now `findIgnoreCase`.

* **Oct 7 - the WebSocket client wired in.** Importing zimrmath into `platform/windows.zig` (the lint's autofix,
  for one `@floatFromInt`) switched on its reserved-names rule for the whole file, flagging old `length` locals; a
  typed local instead, and the import dropped. Found the mesh test stale in `tests/`, its imports written for the
  repository's root.

* **Oct 7 - the mesh test back in the build.** It had fallen out when it moved to `tests/` (its imports assumed
  the repository's root, and nothing ran it). Kept outside the lint's roots and given its two modules by the build,
  it runs with `zig build test`; its `pump` became `pumpSessions` over a comptime session type for the new
  relay-only sessions, the old name kept for the existing tests.

* **Oct 7 - one thread owns each WebSocket connection.** Reading std's TLS client before writing `wss://` found
  that a key update, handled in the read path, rewrites the write keys - so the review's two-lock design (reads
  unlocked, writes from the app's thread) could not carry TLS. The library from Simon has the same race. Restructured
  first, verified over `ws://` (live, and cross-compiled for Windows), before any TLS: one change at a time.

* **Oct 7 - the second WebSocket review.** The latency fault (two writes a frame, against Nagle's algorithm and
  delayed acknowledgements) had been in the servers since before this work - every browser message from them paid
  it. Also found: this Zig's enum reflection is `field_names` and `field_values`, no longer `fields`.

* **Oct 7 - a review for blind spots.** Two findings no line review would have made: mixed browser and native
  rooms could not talk (fixed, with a mesh test that failed first as predicted), and this std's Windows sockets are
  AFD handles, on which the client's `WSAPoll` cannot work - found by reading how std makes a socket on Windows,
  since nothing native has run there. The full list is in platforms_plan.md.

* **Oct 7 - the WebSocket client from first principles.** With no Windows to test on, every Windows path was
  checked in std's source instead: sockets are AFD handles; cancellation reaches a thread blocked in their I/O by
  `NtCancelSynchronousIoFile`, but only for tasks std runs - so the client's work moved from `std.Thread` into
  `io.concurrent` tasks. One live run then caught what reading had not: connect with a timeout is an unimplemented
  panic in this std, on every platform. The happy-path-only live test grew a burst, a leave, and a refusal.

* **Oct 7 - TLS for the native client.** Three facts read in std's source before writing: the TLS writer's flush
  stops at the stream's buffer (a second flush sends), a read can rewrite the write keys (the turn), and Windows
  certificates come from the ROOT store. Then std's TLS was probed live against github.com, and the client run over
  wss://github.com/ through a copy with two diagnostic prints. A burst run that received 0 of 50 was the test's
  own fault - it assumed ids by join order, but the server numbers connections as it accepts them.

* **Oct 7 - the frame clock's filter, and a misremembered check.** D9 is sokol_app's filter, read in its source.
  Looking for the headless frame comparison to guard it, none existed: B8's "Done: all 32" is the plan's way of
  stating an acceptance criterion - finished work says "**Done <date>:**" - and B8 was never built. The plan was
  right; the recollection was wrong. A claim about the code is checked in the code, not in a summary of it.

* **Oct 7 - the first look through the loop.** Clicking and typing into ui_text_editing worked; Shift+Left and
  Ctrl+A did nothing. The keys reached the engine's input state, but the UI read its keys from a per-frame
  snapshot the host never filled - a population loop that existed only in a unit test describing it. Every
  keyboard path in the UI had been tested with hand-built snapshots, so all of them passed. A run through the real
  event path found in two scripts what the unit tests could not.

* **Oct 7 - review: one clock cannot be two.** A deep review of the headless driver found its clock wrong in kind:
  scripting `nowMs` made frame time deterministic, but the same clock measured work, and inside a frame it stood
  still - cartpole_duel's "learn until the budget is spent" loop would never have ended headless. Frame time is now
  an input from whoever drives frames; the engine's clock measures work, and stays real.

* **Oct 9 - the first sweep.** Simon ran the ray tracer and the text fields on Windows: they work. Here, the
  launcher built headless ran all 32 flagships in 73 seconds - every one drew, validation clean - and its debug
  allocators reported 411 leaks, which nothing had ever counted: the run still exited 0. Now a logged error fails
  a run; the leaks were three examples' and one engine function's, fixed the same hour.

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
