# vulkan_backend.md — native platforms via a Vulkan backend (plan, not started)

Status: **PLAN ONLY** — investigation done (mach-main studied in depth, zimr's seams
inventoried), no implementation. Web stays the first-class platform; this plan is
about making native backends possible without complicating the web path.

---

## 0. Goal, non-goals, constraints

**Goal.** Run zimr examples as native executables — Windows first (Vulkan), Linux
second (same Vulkan file, different window host) — while the browser remains the
primary, best-supported target. One `examples/<name>/<name>.zig` source produces
both the standalone HTML and (later) a `.exe`.

**Non-goals (for this plan).**
- Not a general WebGPU implementation. We implement exactly zimr's own 51-call
  `extern "wgpu"` surface, nothing more. (mach's sysgpu implements the full spec
  in 3,682 lines of vulkan.zig + 15k lines total; our subset is much smaller.)
- No Metal yet. The seam this plan creates makes Metal a third impl file later,
  but Metal cannot consume SPIR-V — it needs MSL, i.e. a future `spv2msl` sibling
  of `spv2wgsl`. Priced separately, out of scope here.
- No D3D12, no OpenGL.
- No new dependencies. The Zig compiler stays the only build dependency; Vulkan
  is loaded at **runtime** via `std.DynLib` (vulkan-1.dll / libvulkan.so), exactly
  as mach does — no import lib, no SDK needed to build, no headers.

**Constraints (Simon's, restated so the plan is judged against them).**
1. **Web first.** Nothing in this plan may regress, complicate, or slow the wasm
   path. The native seam must be `comptime`-selected and cost zero on web.
2. **Simple.** Big flat files, few of them. One `wgpu_vulkan.zig` monolith
   (mirroring how `bridge.zig` is THE browser host monolith), not a directory of
   twenty small files.
3. **Everything in Zig, in-repo.** Hand-written Vulkan declarations for the
   subset we call (the `win32.zig` model mach itself uses: 4,212 hand lines for
   all of win32), not the generated vulkan-zig binding (~300k lines).

---

## 1. What we already have (the seam inventory — all verified in-tree)

The architecture is **already backend-shaped**. The findings that make this plan
cheap:

**1a. The GPU seam is 51 scalar-only functions.** `src/wgpu.zig` declares
`extern "wgpu" fn js_*` — **51 unique functions** (declared twice in-file: the
top extern section ~lines 224–470 and a nested `wgpu_externs` re-export struct
~line 1461 feeding the `wgpu_js` pass wrappers — P0 handles both), every argument `u32`/`f32`/`f64`/ptr+len.
No structs cross. Typed `enum(u32)` handles (`BufferHandle`, `TextureHandle`, …,
0 = invalid) on the Zig side; the host keeps a handle table. Complex descriptors
cross as **zimr-owned little-endian byte blobs** encoded by `src/gpu.zig`
(`encodeRenderPipelineDescriptor`, `encodeBindGroupLayoutEntries`,
`encodeBindGroupEntries`) and decoded by the host (`src/bridge.zig` decoders,
"byte-for-byte the TS bridge's formats"). A native backend decodes the **same
blobs** — the format is ours, not JavaScript's.

**1b. Native stubs already exist.** Every wrapper in `wgpu.zig` starts with
`if (comptime !is_wasm) return .invalid;` (52 `is_wasm` sites) so host tests
link. The comptime backend switch exists in embryonic form; this plan grows the
stub branch into a real backend.

**1c. Shaders are already compiled FOR Vulkan.** The shader pipeline is
`zig build-obj -target spirv32-vulkan -mcpu vulkan_v1_2` → `shader.spv` → `zspv`
rewrite (splits combined image+samplers into separate texture+sampler — a
WebGPU-ism that is **also valid Vulkan**, stamps DescriptorSet/Binding
decorations) → `shader.rewritten.spv` → `spv2wgsl` → `.wgsl` `@embedFile`d.
**For native we stop at `shader.rewritten.spv` and feed it to
`vkCreateShaderModule` directly. The entire spv2wgsl step is web-only plumbing.**
The rewritten `.spv` files already exist in the build cache
(`.zig-cache/o/*/shader.rewritten.spv`); the build's `ShaderPipeline.addShaderEx`
already returns per-shader outputs and wires `.wgsl` as anonymous imports — the
native variant wires the sibling `.spv` LazyPath as `<name>.spv` the same way.

**1d. `-mcpu vulkan_v1_2` ⇒ SPIR-V 1.5 ⇒ device baseline Vulkan 1.2** at
minimum. See D1 for why we choose 1.3.

**1e. The bind-group model maps 1:1 to descriptor sets.**
`shader_interface.uniformGroupForSchema` is the single source of truth: group 0 =
VS UBO + storage, group 1 = samplers, group 2 = FS UBO (+ explicit pins). Three
groups ⇒ three `VkDescriptorSetLayout`s in one `VkPipelineLayout` —
under every driver's minimum of 4 bound sets. `@group(n)` ≡ `set = n`,
`@binding(n)` ≡ `binding = n`; zspv already stamps these decorations into the
SPIR-V, so the native path needs no re-decoration.

**1f. The host contract is small and poll-based.** The host owns the loop
(web: rAF → calls the wasm's `pub export fn update(dt_seconds: f32)`); input
arrives via `input_push_*` exports; async is polling, not callbacks
(`js_buffer_read_start/poll/into/release`, `js_fetch_start/poll`), which maps
directly to Vulkan fences. `js_queue_submit(queue, cmd_buffer)` takes **one**
command buffer — multiple submits per frame are legal (the RTT encoder split
uses this), and same-queue submission order gives the WebGPU-implicit ordering
for free.

**1g. The frame-lifecycle work already tamed the hard Vulkan problem.** The
offscreen-first migration (all 26 RTT examples; `manages_own_frame`,
`frame_phase`, `ensureFrame`, encoder split) means render-target textures
transition write→read at **known, few, engine-controlled points** per frame.
mach needs a general `StateTracker` (WAW/WAR hazard tracking per resource per
pass) because arbitrary WebGPU programs demand it; zimr's own discipline lets a
per-texture `current_layout` field + coarse pass-boundary barriers be correct.
This is the single biggest simplification vs mach.

**1h. The other extern namespaces (the native host's second half).**
- `extern "dom"` — 68 unique functions (window/canvas size, loop, clipboard, cursor,
  fullscreen, persistence, fetch, dropped files, overlay text inputs, screenshot,
  timers). A native window host implements these against win32.
- `extern "audio"` — 20 functions (context, buffer load/decode-ogg/play/pause/
  volume). Native = WASAPI (or a later cross-platform mixer).
- Wasm exports the host calls: `update(dt)`, `input_push_mouse_move/button/
  wheel/key/char`, `zimr_input_push_touch_*`, `input_push_motion`. Natively these
  stop being exports — the host layer is the same binary and calls them directly.

---

## 2. What mach teaches (studied: mach-main @ sysgpu/vulkan.zig 3,682 lines)

Adopted:
- **Runtime dynamic loading** + three-tier proc tables (Base → Instance →
  Device function pointers via `vkGetInstanceProcAddr`/`vkGetDeviceProcAddr`).
  No SDK, no import libs, no linking. (mach `vulkan.zig:init` + `vulkan/proc.zig`.)
  **Verified mechanics for OUR toolchain** (this dev-Zig's `std.DynLib` has no
  Windows arm — comptime error): on Windows hand-declare the two loader externs
  (`extern "kernel32" fn LoadLibraryW/GetProcAddress`, `callconv(.winapi)`) —
  house style anyway; on Linux `std.DynLib` works (Zig's own `ElfDynLib`, even
  static/no-libc). **Proven in-sandbox**: `vkprobe.exe` (425KB) cross-compiled
  green with exactly this shape — see §9.
- **A `conv.zig`-style mapping section**: pure functions WebGPU-enum →
  Vulkan-enum (blend factors, formats, image layouts, usage flags…). mach's is
  512 lines for the full spec; ours will be smaller. Lives as a banner section
  inside `wgpu_vulkan.zig`, not a separate file.
- **Swapchain handoff**: keep the old `VkSwapchainKHR` and pass it as
  `old_swapchain` on resize recreation (mach `Surface.old_vk_swapchain`).
- **Hand-written platform bindings**: mach's `win32.zig` (4,212 lines, 865
  decls, leaning on `std.os.windows` for the base types) proves the no-deps
  windowing layer is a bounded, one-time cost.
- **Per-submit retirement objects**: mach's `SubmitObject` (fence + a list of
  resources to release when the fence signals) is the right shape for deferred
  destruction; ours is simpler with 2 frames in flight (see §6.2).

Rejected / not needed:
- **The general StateTracker** (hazard tracking per bind group across arbitrary
  passes) — replaced by zimr's frame-phase-anchored minimal tracker (§6.3).
- **Classic render passes + framebuffer cache** — mach targets Vulkan 1.1 and
  caches `VkRenderPass`/`VkFramebuffer` by key (`createRenderPass(rp_key)` at 3
  call sites). We baseline 1.3 and use **dynamic rendering**
  (`vkCmdBeginRendering`) — no render-pass objects, no framebuffers, no cache.
  This deletes an entire subsystem. (Decision D1.)
- **Their WGSL compiler** (`sysgpu/shader/*` — Tokenizer/Parser/AstGen/CodeGen
  to SPIR-V): mach compiles WGSL→SPIR-V at runtime because users hand it WGSL.
  We already HAVE build-time SPIR-V. Zero shader compilation at runtime.
- **gpu_allocator sub-allocation**: mach mostly calls plain `vkAllocateMemory`
  per resource anyway. We start there too (zimr's resource counts are small:
  tens of textures/buffers, not thousands). Sub-allocation is a later
  optimization if `maxMemoryAllocationCount` (min 4,096) ever threatens.
- **Reference-counted lifetime managers** (`utils.Manager`) — zimr's ownership
  is simpler (engine owns almost everything; explicit destroy calls exist:
  `js_buffer_destroy`, `js_texture_destroy`).

---

## 3. The structural decision: comptime backend seam, three host files

### 3.1 The seam (this is the P0 prep, cheap, do-able now)

`wgpu.zig` keeps its role — typed handles + Zig-friendly wrappers — but the
extern block and the `is_wasm` stubs are replaced by one comptime-selected impl
module exposing the same 51 functions (names without the `js_` prefix):

```zig
// src/wgpu.zig (after P0)
pub const Backend = enum { web, vulkan, none };
pub const backend: Backend = if (is_wasm) .web
    else if (@import("build_options").gpu_vulkan) .vulkan
    else .none;                      // host tests keep linking, as today

const impl = switch (backend) {
    .web    => @import("wgpu_web.zig"),     // the extern "wgpu" decls, moved
    .vulkan => @import("wgpu_vulkan.zig"),  // the new monolith
    .none   => @import("wgpu_stub.zig"),    // today's `return .invalid` bodies
};
// wrappers change `js_device_create_buffer(...)` → `impl.deviceCreateBuffer(...)`
```

Same pattern at the other two seams:
- `web.zig`'s `extern "dom"` block → `host_web.zig` / `host_win32.zig` /
  `host_stub.zig` behind a `host` switch.
- `sound.zig`'s `extern "audio"` block → `audio_web.zig` / `audio_wasapi.zig` /
  `audio_stub.zig`.

Properties: **zero web-path change** (wgpu_web.zig is a mechanical move of the
extern block — same symbols, same JS import namespace, byte-identical wasm);
**everything above the seam untouched** (gpu.zig blobs, gpu_iface, renderer_2d,
draw3d, wgpu_app, all examples); adding Linux/Metal later = new file in one
switch arm.

### 3.2 New files (all big-and-flat, per house style)

| file | role | est. size |
|---|---|---|
| `src/vk.zig` | hand-written Vulkan declarations: the ~55 structs, ~30 enums, ~86 function-pointer types + the 3 loader tables our subset touches (exact inventory: Appendix A). Pure decls, zero logic. | ~2,000–2,800 |
| `src/wgpu_vulkan.zig` | THE native GPU monolith: instance/device/swapchain init, handle tables, blob decoders (mirroring bridge.zig's, section-per-decoder), the 51 impl fns, the conv section, frame sync, minimal layout tracker, debug-messenger. | ~3,000–3,800 |
| `src/host_win32.zig` | win32 window + message pump + input translation → `input_push_*`; the `dom` impl subset; `pub fn main` loop for native builds. Hand-declared win32 subset inline (we need far less than mach's 4,212 — no COM UI, no shell). | ~1,200–1,800 |
| `src/audio_wasapi.zig` | WASAPI render client + zimr's existing mixer/ogg decoder (decode is already pure Zig in codecs.zig — `js_audio_decode_ogg_bytes` exists because *web* offloads to the browser; native decodes in-process). | ~600–900 |
| `src/wgpu_web.zig`, `host_web.zig`, `audio_web.zig` | today's extern blocks, moved verbatim. | tiny |
| `src/wgpu_stub.zig`, `host_stub.zig`, `audio_stub.zig` | today's `.invalid` stubs, moved. | tiny |

No subdirectories. `vk.zig` is separate from `wgpu_vulkan.zig` only because
declarations-vs-logic is a real boundary (same reason `win32.zig` is separate in
mach); everything else folds into the monolith as banner sections.

---

## 4. Shader path on native (the part that's nearly free)

1. Build: for every engine/example shader the pipeline already produces
   `shader.rewritten.spv` before spv2wgsl runs. Add to `ShaderPipeline.addShaderEx`
   an `emit_spv` output and wire `b.fmt("{s}.spv", .{name})` anonymous imports on
   the **native** module variant only (web modules keep embedding `.wgsl` and
   never pay for the twin).
2. `wgpu_vulkan.zig`'s `deviceCreateShaderModuleWgsl(device, bytes, len, …)` —
   note: the *name* says wgsl but on native the bytes ARE the `.spv` (the caller
   in gpu.zig picks which embed to pass via the same comptime backend switch;
   rename the wrapper to `createShaderModule` during P0 to stop lying).
   Implementation: `vkCreateShaderModule{ code = bytes }`. Done.
3. Entry points: zimr names them per stage (the blob carries
   `vs_entry_point`/`fs_entry_point` strings) — pass through to
   `VkPipelineShaderStageCreateInfo.pName` unchanged.
4. Descriptor sets: groups 0/1/2 (+ pinned) → `VkDescriptorSetLayout[set]`;
   the **same** `encodeBindGroupLayoutEntries` blob drives
   `vkCreateDescriptorSetLayout` (type map: uniform_buffer→UNIFORM_BUFFER,
   storage read/rw→STORAGE_BUFFER, sampler→SAMPLER, texture→SAMPLED_IMAGE —
   zspv's split-sampler rewrite means we never see COMBINED_IMAGE_SAMPLER).
5. Validation hook: dev builds enable `VK_LAYER_KHRONOS_validation` when the
   env var `ZIMR_VK_VALIDATE=1` is set + a debug-utils messenger that prints via
   the existing log path. This is our native "Tint strictness" analogue.

**Risk retired by construction:** the WGSL-specific work (uniformity analysis,
Tint quirks, `spv2wgsl` edge cases) simply does not exist on this path. The
SPIR-V that Tint already accepts (post-zspv, post-spirv-val in the corpus gate)
is what Vulkan consumes.

---

## 5. The 51-call mapping (by group; ✓ = trivial, ● = real work)

**Device/surface/queue (10):** `init_device` ✓→ instance+physical-device pick
(discrete>integrated)+device+queue (one graphics+present queue; assert
presentable); `device_get_queue` ✓; `get_surface` ● → win32 HWND via
`vkCreateWin32SurfaceKHR` + swapchain create (format: prefer BGRA8_UNORM —
matches web's canvas format enum already in `surface_get_format`); 
`surface_get_current_texture` ● → acquire (see §6.2) returning the image's
pre-created view handle (web returns a VIEW handle here too — verified);
`surface_present` ● → `vkQueuePresentKHR` + frame-slot advance;
`surface_get_format/get_size/get_css_size` ✓ (css_size = window client rect;
dpi via `GetDpiForWindow`); `now_ms` ✓ QPC; `gpu_ms_last` ✓ (timestamp queries,
or 0.0 stub first).

**Buffers (3+4):** `device_create_buffer` ✓ usage-map + allocate + bind
(HOST_VISIBLE|COHERENT for upload-flagged, DEVICE_LOCAL else);
`buffer_destroy` ✓ deferred to fence (§6.2); `queue_write_buffer` ● staging ring
+ `vkCmdCopyBuffer` on the frame's transfer segment (or direct memcpy for
host-visible); readback quartet ● `read_start` = alloc host-visible staging +
copy cmd + fence, `read_poll` = `vkGetFenceStatus`, `read_into` = memcpy from
persistently-mapped, `read_release` = free. Poll model == fence model, 1:1.

**Textures/views/samplers (7):** `device_create_texture` ✓ usage/format map +
allocate + bind, layout=UNDEFINED recorded in tracker;
`texture_create_view/_mip/_array` ✓ `vkCreateImageView` (2D / mip-ranged /
2D_ARRAY); `texture_destroy` ✓ deferred; `device_create_sampler` ✓;
`queue_write_texture` ● staging + layout to TRANSFER_DST +
`vkCmdCopyBufferToImage` + back (bytes_per_row already in the signature).

**Pipeline objects (5):** `create_bind_group_layout` ✓ blob→
`vkCreateDescriptorSetLayout`; `create_pipeline_layout` ✓;
`create_bind_group` ● blob→ descriptor-pool alloc + `vkUpdateDescriptorSets`
(pool: one big pool, `FREE_DESCRIPTOR_SET`, grow on OOM — zimr's BindGroupCache
above the seam already dedupes, so churn is low); `create_shader_module` ✓ (§4);
`create_render_pipeline` ● the big blob→ `VkGraphicsPipelineCreateInfo` with
**dynamic rendering** (`VkPipelineRenderingCreateInfo` lists color format(s) +
depth format from the blob's state ints + MRT tail) + dynamic viewport/scissor;
`create_compute_pipeline` ✓.

**Encoders & passes (18):** `create_command_encoder` ✓ allocate CB from the
frame slot's pool + begin; `begin_render_pass` ● tracker-transition the
attachment images, then `vkCmdBeginRendering` (clear/load/store map 1:1;
`resolve_view` → color attachment's `resolveImageView`, MSAA mode RESOLVE);
`begin_render_pass_mrt` ● same with N attachments from views_ptr;
`render_pass_set_pipeline/bind_group/vertex_buffer/index_buffer/scissor` ✓
direct vkCmd*; `draw/draw_indexed` ✓; `render_pass_end` ✓ `vkCmdEndRendering`;
compute sextet ✓ (dispatch + set_*; barrier before first storage use via
tracker); `copy_buffer_to_buffer` ✓; `copy_texture_to_buffer` ● layout dance;
`command_encoder_finish` ✓ end CB; `queue_submit` ● (§6.2).

**Info (1):** `adapter_info` ✓ from `vkGetPhysicalDeviceProperties`.

Nothing in the surface requires: multiple queues, sparse/protected memory,
secondary command buffers, render-pass compatibility rules, pipeline caches
(add `VkPipelineCache` later as a free win), push constants (zimr's
`constants` in the pipeline blob are **WGSL override constants** — on the
SPIR-V path they are OpSpecConstants ⇒ map to `VkSpecializationInfo`, ●,
verify zspv keeps SpecIds — flagged in §10 Q4).

---

## 6. The three hard parts, designed

### 6.1 Swapchain & resize
Create at `get_surface` with the window's client size; images → engine
`TextureHandle`s + pre-created views. On `VK_ERROR_OUT_OF_DATE_KHR` /
`SUBOPTIMAL` from acquire/present, or a size change from the message pump:
`vkDeviceWaitIdle` (zimr resizes are rare; simplicity beats smooth-resize) →
recreate with `old_swapchain` → refresh the handle table entries **in place**
(same handles, new backing — the engine's cached surface handles stay valid,
mirroring how the web bridge re-configures the canvas context invisibly).
`js_window_resized_take` (dom) delivers the new size to the engine exactly as
on web.

### 6.2 Frame sync (2 frames in flight)
Per slot: `{ command_pool, fence, sem_acquire, sem_render_done }`.
- `surface_get_current_texture`: wait+reset slot fence → retire that slot's
  deferred destroys and staging allocations → `vkAcquireNextImageKHR(sem_acquire)`.
- Non-final `queue_submit`s in a frame (RTT encoder split): plain submits, no
  semaphores, no fence — same-queue order suffices.
- The submit that wrote the swapchain image (detected: its CB touched the
  acquired image — tracker knows): wait `sem_acquire` at
  COLOR_ATTACHMENT_OUTPUT, signal `sem_render_done`, signal the slot fence.
  Edge: if `surface_present` arrives with no such submit yet (shouldn't per
  frame_phase, assert), submit an empty CB to bridge semaphores.
- `surface_present`: `vkQueuePresentKHR(wait = sem_render_done)`; slot = (slot+1)%2.
Deferred destruction: `buffer/texture_destroy` and per-frame staging append to
the current slot's retire list; freed after that slot's fence next signals.

### 6.3 Minimal layout/barrier tracker (the anti-StateTracker)
Per texture: `current_layout: VkImageLayout` (+ per-mip only for the mip-view
users: bloom's chain — store per-level when `mip_levels > 1`). Rules:
- `begin_render_pass(_mrt)`: for each attachment, if layout ≠
  COLOR_ATTACHMENT_OPTIMAL (or DEPTH_*), emit one `vkCmdPipelineBarrier2` and
  update. Store-op done ⇒ layout stays ATTACHMENT until someone samples.
- `render_pass_set_bind_group` / `compute_pass_set_bind_group`: bind groups
  remember their sampled textures (recorded at `create_bind_group` from the
  entries blob). Any bound texture not in SHADER_READ_ONLY_OPTIMAL gets a
  barrier **before the pass begins** — implemented by buffering the pass-begin
  until first draw/dispatch? No — simpler: zimr's engine sets bind groups
  after pass begin, and Vulkan forbids barriers inside rendering. Resolution:
  transition at `begin_render_pass` time for the PREVIOUS frame's known set is
  fragile; instead the engine seam gives us the answer — `frameEncoder`'s
  offscreen-first ordering means every texture sampled in pass N was written in
  a pass that already **ended**. So: at `render_pass_end` / `compute_pass_end`,
  transition every attachment/storage-written image of that pass straight to
  SHADER_READ_ONLY. Cost: one barrier batch per pass end; correctness by the
  engine's own ordering invariant, asserted (`assertf(layout == SHADER_READ_ONLY)`
  at bind time in debug).
- Buffers: one coarse `vkCmdPipelineBarrier2(memoryBarrier ALL→ALL)` at each
  compute-pass end and after transfer segments. Coarse ≠ slow at zimr's pass
  counts (single digits/frame), and it is exactly the strength WebGPU's
  implicit model guarantees.

---

## 7. Window / input / dom triage (host_win32.zig)

Message pump (`PeekMessageW` loop, mach `core/Windows.zig` is the reference) →
direct calls into the existing `input_push_*` functions (natively they're just
functions, not exports). Mapping: WM_MOUSEMOVE→mouse_move (client coords, same
top-left origin as web), WM_*BUTTON*, WM_MOUSEWHEEL (lines→pixels ×
scroll-lines), WM_KEYDOWN/UP (VK→zimr keycode table; zimr keycodes are the
web's — one translation table), WM_CHAR→input_push_char (UTF-16 pair
handling), WM_POINTER* → touch_* (touch screens), WM_SIZE→resized flag,
WM_SETFOCUS/KILLFOCUS→set_window_focused, WM_DPICHANGED→dpi.

The 68 `dom` externs triaged (name-exact table: Appendix B):
- **Real implementations (~30):** canvas/window size + set_size (client-rect /
  `SetWindowPos`), dpi (`GetDpiForWindow`), title, fullscreen toggle
  (borderless style flip), cursor style/set_mouse_cursor (`SetCursor` table),
  pointer lock (`ClipCursor`+hide+raw input), clipboard text get/set
  (`OpenClipboard` CF_UNICODETEXT), clipboard image (CF_DIB→RGBA), now_ms/
  epoch_ms/tz_offset (QPC/`GetSystemTime*`), open_url (`ShellExecuteW`),
  window icon (png→`CreateIcon` via existing codecs decoder), opacity
  (`SetLayeredWindowAttributes`), crypto_random (`std.crypto.random`),
  persistence read/save/remove/size (`%APPDATA%/zimr/<app>/kv` files — the web
  contract is localStorage-synchronous with typed return codes 0=ok / 1=quota /
  2=unavailable, verified in web.zig; files map those codes 1:1),
  fetch quartet (std.http on a thread + poll flag — or P4, stub first),
  dropped files (WM_DROPFILES), screenshot (readback the swapchain image via
  the existing copy_texture_to_buffer machinery), start/stop_loop (flag the
  main loop), log/panic (stderr + MessageBox on panic).
- **No-ops with a fallback story (~20): the overlay text inputs.** On web,
  `ui.zig` text fields raise DOM `<input>`/`<textarea>` overlays (IME, mobile
  keyboards). Natively the overlays no-op and text entry must ride the
  WM_CHAR→`input_push_char` path that `ui.getCharPressed` already consumes
  (`ui.zig:1302`). **P3 investigation item:** verify ui's internal editing path
  is complete without the overlay (cursor/selection/edit state) or scope the
  gap; IME (`WM_IME_*`) explicitly deferred.
- **Trivial constants (~5):** is_fullscreen, overlay_*_is_visible→false, etc.

Entry point: `host_win32.zig` provides `pub fn main()` — create window, init
audio, call the engine's existing boot (the same init the web preamble
triggers), then `while (running) { pump(); update(dt); }`. The example's
`app: z.AppSpec(State)` is untouched; `build.zig` selects the host main for
native targets the same way it selects bridge/c2js for web.

---

## 8. Audio (audio_wasapi.zig — P4, after pixels)

The extern surface is a **buffer/voice model, not a sample callback** (verified:
load/unload_buffer + play/pause/stop/resume_buffer(+at/with_offset) +
is_playing/current_time/volume; there is NO stream-push extern — zimr streams,
e.g. `audio_stream_synth`, are wasm-side chained buffers already). So the native
impl is: a PCM buffer store + active-voice list + ONE WASAPI shared-mode render
thread mixing voices to f32 (hand-declared COM vtable subset:
IMMDeviceEnumerator→IAudioClient→IAudioRenderClient, ~25 slots).
`decode_ogg_bytes` runs zimr's own pure-Zig decoder in-process on the mixer
thread (poll shape kept). Until P4: `audio_stub.zig` (silence) so everything
else ships.

---

## 9. Build integration & testing (GPU-less sandbox reality)

- New per-example steps: `zig build <name>-windows` → `zig-out/native/<name>.exe`
  (`-target x86_64-windows-gnu`; cross-compiles from this Linux sandbox — the
  runtime loading means **no** Vulkan SDK or import libs at build time).
  **The P1 proof already exists**: `vkprobe.exe` (425KB, probe source shown in
  the planning conversation) cross-compiled green from this sandbox —
  hand-declared kernel32 loader + `vkGetInstanceProcAddr` +
  `vkEnumerateInstanceExtensionProperties`. Simon can run it today for the
  earliest possible signal (prints the instance extension count). Later
  `<name>-linux` (std.DynLib ElfDynLib path — also compile-verified).
- The native module variant reuses `buildAppModule` with backend build options +
  the `.spv` anonymous imports; web targets are untouched.
- Verification ladder (this sandbox has no GPU or display):
  1. **Compile gate here** — every native target must cross-compile green; wire
     `native-typecheck` into `tier-a-check` once P2 lands.
  2. **Simon device-runs the .exe** — same screenshot loop as HTML standalones.
     `ZIMR_VK_VALIDATE=1` turns on the validation layer + messenger; first-run
     instructions land in readme.html's building section.
  3. **Software Vulkan later** — lavapipe (Mesa CPU Vulkan) would let the
     sandbox actually execute frames + reuse the smoke gate natively; depends on
     getting the package in (network policy) — investigate at P5, not load-bearing.
- Golden-image cross-check: the CPU rasterizer verify targets already render
  reference pixels; a native `--screenshot-and-exit` flag (screenshot dom fn +
  stop_loop) gives Simon a one-shot compare artifact per example.

---

## 10. Open questions (each with a recommendation)

- **Q1 Vulkan baseline.** 1.3 (dynamic rendering + synchronization2, core) vs
  mach's 1.1 + render-pass cache. **Rec: 1.3.** Deletes the render-pass/
  framebuffer subsystem; Windows drivers since ~2022 qualify (NV 470+/AMD
  21.x+/Intel Xe). Fallback for old GPUs = a later
  `VK_KHR_dynamic_rendering`-on-1.1 arm, only if real hardware demands it.
- **Q2 Bindings.** Hand-written `vk.zig` subset vs vendoring generated
  vulkan-zig. **Rec: hand-written** (the mach-win32 precedent; ~2.5k lines,
  grows only when we call something new; zero generator in the tree).
- **Q3 BGRA vs RGBA swapchain.** Web canvases are BGRA-preferred and the format
  enum already flows through `surface_get_format`. **Rec:** prefer
  `B8G8R8A8_UNORM`, fall back to RGBA8 and report it — engine already branches
  on the reported format.
- **Q4 Override constants — RESCOPED after verification.** The typed engine
  path passes **zero** constants (`gpu.zig`'s non-empty case is a unit test);
  constants flow only through the raw-shader escape hatch
  (`shader_runtime_wgpu.zig`, `material.zig` opts, and the
  `pipeline_constants` example). Those escape-hatch examples author shaders in
  Zig too, so `.spv` twins exist — native escape hatch = embed the `.spv`.
  Remaining spike (P1, small): how does `pipeline_constants` declare its
  overrides in Zig, do SpecIds survive zspv, and map name→SpecId
  (parse OpName+OpDecorate once) into `VkSpecializationInfo`. Worst case:
  mark the constants feature web-only with a loud assert and fold the one
  example's constants into a UBO — the typed engine path is unaffected either
  way.
- **Q5 MSAA.** `sample_count` + `resolve_view` exist in the surface. Dynamic
  rendering handles resolves natively. **Rec:** implement in P2 (it's one field
  + one image), don't defer — pipeline_msaa is an existing example.
- **Q6 Text/IME.** §7's overlay fallback. **Rec:** P3 verify + basic WM_CHAR
  path; real IME is post-plan.
- **Q7 Where does `js_str`-style logging go?** `log` → stderr; keep the
  on-page-log parity by mirroring into a ring the screenshot flag can dump.

## 11. Phases (each ends green-on-web + compiling natively; sizes in turns)

- **P0 — seam prep (2–3):** the §3.1 mechanical split (wgpu_web/stub, host_web/
  stub, audio_web/stub + comptime switches); rename the shader-module wrapper;
  `.spv` anonymous-import plumbing behind the backend option; web wasm must be
  **byte-identical** (compare build hashes) — that's the acceptance gate.
- **P1 — vk.zig + boot spike (3–4):** hand bindings for instance/device/
  swapchain/clear; the cross-compiled enumerate + clear-screen exe Simon runs;
  the Q4 spec-constant spike.
- **P2 — the 51 calls (6–8):** §5 in dependency order (buffers→textures→
  pipelines→passes→sync); milestone = `shapes-showcase-windows` renders (2D
  batch exercises: pipeline, UBO group0/2, sampler group1, draw_indexed).
  Then the RTT set (render_texture, bloom = mip views), compute (fluid_gpu),
  MSAA, readback (texture_readback).
- **P3 — host_win32 (3–4):** window/pump/input/dpi/clipboard/cursor; the ui
  text-input verification; `launcher-windows` usable.
- **P4 — audio_wasapi (3).**
- **P5 — parity + gates (3–4):** native-typecheck in tier-a; example sweep;
  readme.html "native" section; lavapipe investigation; retro the plan.

Total ≈ 20–26 turns to a Windows launcher at parity minus IME. Linux after =
host_linux.zig (xlib or wayland surface + evdev/x11 input) reusing
wgpu_vulkan.zig unchanged — est. 4–6 more.

## 12. What we deliberately keep NOT doing
No runtime shader compilation, no general WebGPU semantics beyond our 51 calls,
no descriptor-indexing/bindless, no multi-window, no multi-queue, no pipeline
derivatives, no sub-allocation until counts demand it, no Metal until spv2msl
is priced. Every one of these is *absent from the seam*, so saying no costs
nothing later.


---

## Appendix A — vk.zig declaration inventory (P1 becomes mechanical)

Functions (~86; grow-only, add when a call is first needed). Loader externs
(`LoadLibraryW`/`GetProcAddress`) live in host_win32.zig, not here.

- **proc roots:** vkGetInstanceProcAddr, vkGetDeviceProcAddr
- **instance:** vkCreateInstance, vkDestroyInstance, vkEnumeratePhysicalDevices,
  vkGetPhysicalDeviceProperties, vkGetPhysicalDeviceQueueFamilyProperties,
  vkGetPhysicalDeviceMemoryProperties, vkGetPhysicalDeviceFeatures2,
  vkEnumerateDeviceExtensionProperties
- **debug (dev only):** vkCreateDebugUtilsMessengerEXT, vkDestroyDebugUtilsMessengerEXT
- **surface:** vkCreateWin32SurfaceKHR (later: Xlib/Wayland), vkDestroySurfaceKHR,
  vkGetPhysicalDeviceSurfaceSupportKHR, …SurfaceCapabilitiesKHR,
  …SurfaceFormatsKHR, …SurfacePresentModesKHR
- **device/queue:** vkCreateDevice, vkDestroyDevice, vkGetDeviceQueue, vkDeviceWaitIdle
- **swapchain:** vkCreateSwapchainKHR, vkDestroySwapchainKHR,
  vkGetSwapchainImagesKHR, vkAcquireNextImageKHR, vkQueuePresentKHR
- **memory:** vkAllocateMemory, vkFreeMemory, vkMapMemory, vkUnmapMemory,
  vkGetBufferMemoryRequirements, vkGetImageMemoryRequirements,
  vkBindBufferMemory, vkBindImageMemory
- **resources:** vkCreateBuffer, vkDestroyBuffer, vkCreateImage, vkDestroyImage,
  vkCreateImageView, vkDestroyImageView, vkCreateSampler, vkDestroySampler
- **pipeline objects:** vkCreateShaderModule, vkDestroyShaderModule,
  vkCreateDescriptorSetLayout, vkDestroyDescriptorSetLayout,
  vkCreatePipelineLayout, vkDestroyPipelineLayout, vkCreateDescriptorPool,
  vkDestroyDescriptorPool, vkAllocateDescriptorSets, vkFreeDescriptorSets,
  vkUpdateDescriptorSets, vkCreateGraphicsPipelines, vkCreateComputePipelines,
  vkDestroyPipeline
- **commands:** vkCreateCommandPool, vkDestroyCommandPool, vkResetCommandPool,
  vkAllocateCommandBuffers, vkBeginCommandBuffer, vkEndCommandBuffer
- **sync:** vkCreateFence, vkDestroyFence, vkWaitForFences, vkResetFences,
  vkGetFenceStatus, vkCreateSemaphore, vkDestroySemaphore, vkQueueSubmit2
- **recording:** vkCmdBeginRendering, vkCmdEndRendering, vkCmdBindPipeline,
  vkCmdBindDescriptorSets, vkCmdBindVertexBuffers, vkCmdBindIndexBuffer,
  vkCmdSetViewport, vkCmdSetScissor, vkCmdDraw, vkCmdDrawIndexed, vkCmdDispatch,
  vkCmdCopyBuffer, vkCmdCopyBufferToImage, vkCmdCopyImageToBuffer,
  vkCmdPipelineBarrier2
- **timestamps (P5, `gpu_ms_last`):** vkCreateQueryPool, vkDestroyQueryPool,
  vkCmdWriteTimestamp2, vkGetQueryPoolResults

Structs (~55): the CreateInfo/Descriptor for each of the above +
VkPipelineRenderingCreateInfo, VkRenderingInfo/VkRenderingAttachmentInfo,
VkImageMemoryBarrier2/VkMemoryBarrier2/VkDependencyInfo,
VkSubmitInfo2/VkCommandBufferSubmitInfo/VkSemaphoreSubmitInfo,
VkSpecializationInfo(+MapEntry), VkPhysicalDeviceVulkan13Features (chain:
dynamicRendering + synchronization2), plus the enums/flags each field needs
(~30 enums, declared as `enum(i32)`/packed flag structs, values copied from
vulkan_core.h — cite the header version in a comment).

## Appendix B — dom extern triage (all 68, exact)

**Group W — real win32 impls (35):**
canvas_css_width/height + canvas_drawing_width/height (client rect; drawing =
css × dpi) · canvas_set_size (SetWindowPos, AdjustWindowRect) · get_dpi_scale
(GetDpiForWindow/96) · set_title (SetWindowTextW) · is_fullscreen +
toggle_fullscreen (borderless style flip + saved placement) ·
set_window_focused (SetForegroundWindow) · set_window_icon_png (codecs decode →
CreateIconIndirect → WM_SETICON) · set_window_opacity (WS_EX_LAYERED +
SetLayeredWindowAttributes) · set_cursor_style/set_mouse_cursor (SetCursor,
LoadCursorW table) · set_input_mode · request/exit_pointer_lock +
pointer_lock_active (ClipCursor + ShowCursor + raw input deltas) ·
set_clipboard_text (OpenClipboard/CF_UNICODETEXT) · get_clipboard_text_start
(same, synchronous → result ready immediately; keep the poll shape) ·
get_clipboard_image_start (CF_DIB/CF_DIBV5 → RGBA) · now_ms (QPC) · epoch_ms
(GetSystemTimeAsFileTime) · tz_offset_min (GetTimeZoneInformation) · open_url
(ShellExecuteW) · crypto_random_fill (std.crypto.random) ·
persistence_save/read/remove/size (%APPDATA%\zimr\<app>\<key> files; return
codes 0/1/2 per web contract) · dropped_files_count/clear +
dropped_file_name/name_len/bytes/byte_len (WM_DROPFILES + DragQueryFileW; bytes
read via std.fs) · take_screenshot (§9 readback path) · window_resized_take
(WM_SIZE latch) · start_loop/stop_loop (main-loop run flag) · log (stderr +
ring) · panic (stderr + MessageBoxW + abort).

**Group F — fetch quartet (4):** fetch_start/poll/data_len+data_ptr/release —
std.http.Client on a worker thread, poll flag + buffer handoff. P4 (stub → P4
impl; only asset-from-URL examples need it).

**Group O — overlay text inputs (17, no-op + fallback):**
show/hide_overlay_input, show/hide_overlay_textarea, get_overlay_input_text,
get_overlay_textarea_text, overlay_input_is_visible (→0),
overlay_textarea_is_visible (→0), update_overlay_input_rect,
update_overlay_textarea_rect, set_overlay_input_allow_tab/char_filters/
escape_clears/password/read_only, set_overlay_textarea_allow_tab/char_filters/
ctrl_enter_for_newline/escape_clears/read_only. Natively text rides
WM_CHAR→input_push_char (ui.getCharPressed path, ui.zig:1302). **P3 gate:**
open ui_code_editor + text_field natively and verify editing works without the
overlay; scope any gap then.

**Group N — trivially native (2):** gamepad_vibrate (XInput later; no-op first) ·
js_now_ms dup with wgpu's (one impl).

## Appendix C — the three blob formats (decode targets, byte-exact)

All little-endian u32 unless noted; strings = u32 len + bytes.

**C1 render pipeline** (`gpu.zig encodeRenderPipelineDescriptor`, order):
vbl_count, per-vbl { array_stride, step_mode, attr_count, per-attr { format,
offset, shader_location } }, str vs_entry, str fs_entry, topology, cull, blend,
depth, color_format, depth_format, sample_count, str depth_compare (resolved
string, e.g. "less-equal"), u32 depth_write_bool, const_count, per-const { str
name, f64 value }, extra_color_count, per-extra u32 format (MRT tail).

**C2 bind-group-layout entries** (`encodeBindGroupLayoutEntries`): count,
per-entry { binding, visibility (packed bits: vertex|fragment|compute),
type_tag, extra (uniform: min_size; storage: 0/1 rw; sampler/texture: 0),
view_dim }.

**C3 bind-group entries** (`encodeBindGroupEntries`, verified): count, then a
**uniform 28-byte record per entry**: u32 binding, u32 resource_type
(0=buffer 1=sampler 2=texture_view), u32 handle, u64 a, u64 b — where a/b =
offset/size for buffers and zero-padding for sampler/texture. (Bridge decoder
twin: bridge.zig:1722.)

## Appendix D — P0 edit list (the seam prep, file-exact)

1. **wgpu.zig:** move the top `extern "wgpu"` section (~224–470) verbatim into
   new `src/wgpu_web.zig` (same symbol names — wasm imports unchanged). Replace
   every `if (comptime !is_wasm) return …; js_X(…)` wrapper body (52 sites) with
   `impl.X(…)` where `X` = js-name minus prefix. Replace the nested
   `wgpu_externs` struct (~1461) the same way (its `wgpu_js` wrappers call
   `impl.*`). Add the `Backend` enum + `impl` switch (§3.1). New
   `src/wgpu_stub.zig` = the 51 functions returning 0/void (today's stub
   semantics, one place).
2. **web.zig:** same treatment for the `extern "dom"` block (first decl line 4,
   last 1517; 26 is_wasm sites) → `host_web.zig` / `host_stub.zig` + switch.
3. **sound.zig:** same for `extern "audio"` (7 is_wasm sites) →
   `audio_web.zig` / `audio_stub.zig`.
4. **build.zig:** `-Dgpu=web|vulkan|none` option (default web on wasm, none on
   host) exposed via build_options; native app-module variant gains the
   `<shader>.spv` anonymous imports (ShaderPipeline `emit_spv`).
5. **gpu.zig / callers:** rename `createShaderModuleWgsl` wrapper →
   `createShaderModule`; the bytes passed are backend-selected
   (`@embedFile(name ++ if (backend==.web) ".wgsl" else ".spv")` at the few
   embed sites).
6. **Acceptance:** web wasm byte-identical (hash compare) + `zig build test`
   green + a `-Dgpu=none` host typecheck of one example.

## Appendix E — frame-sync pseudocode (2 slots)

```
slots[2] = { pool, fence(signaled), sem_acquire, sem_render_done, retire[] }
surface_get_current_texture:
    s = slots[frame&1]
    waitFences(s.fence); resetFences(s.fence)
    for r in s.retire: destroy(r); s.retire.clear(); s.staging.reset()
    resetCommandPool(s.pool)
    img = acquireNextImageKHR(sem = s.sem_acquire)   // OUT_OF_DATE → §6.1 recreate, retry
    return view_handle_of(img)                        // handles pre-made at swapchain create
queue_submit(cb):
    touched_swapchain = tracker.saw(acquired_image, cb)
    if touched_swapchain:
        QueueSubmit2(cb, wait = s.sem_acquire@COLOR_ATTACHMENT_OUTPUT,
                     signal = s.sem_render_done, fence = s.fence)
        s.submitted_final = true
    else: QueueSubmit2(cb)                            // same-queue order = WebGPU implicit
surface_present:
    assert(s.submitted_final)                         // frame_phase guarantees; loud if not
    QueuePresentKHR(wait = s.sem_render_done)         // OUT_OF_DATE → recreate
    frame += 1
buffer/texture_destroy, transient staging → slots[frame&1].retire
```

## Appendix F — conv tables (zimr enums, verified values → Vulkan)

- **TextureFormat(12):** rgba8_unorm(_srgb), bgra8_unorm(_srgb), rgba16_float,
  rgba32_float, r8_unorm, rg8_unorm → same-named VK_FORMAT_*;
  depth16_unorm→D16_UNORM; depth24_plus→D32_SFLOAT (universal; X8_D24 optional
  probe); depth32_float→D32_SFLOAT; undefined_→UNDEFINED. (`map_read` is a
  BufferUsage flag, not a format — it selects the HOST_VISIBLE readback staging
  path of §5.)
- **BlendMode(5), the exact presets (bridge.zig:1838, copy verbatim):**
  0 none → blending disabled; 1 alpha → color(SRC_ALPHA, ONE_MINUS_SRC_ALPHA),
  alpha(ONE, ONE_MINUS_SRC_ALPHA) — the alpha channel is deliberately "over",
  not replace (replace punched holes in render-textures; the comment there
  documents the bug); 2 additive → color(SRC_ALPHA, ONE), alpha(ONE, ONE);
  3 multiply → color(DST_COLOR, ZERO), alpha(DST_ALPHA, ZERO);
  4 premultiplied → color(ONE, ONE_MINUS_SRC_ALPHA), alpha(same). All op=ADD.
- **DepthMode(9):** compare op from the blob's resolved string + write bool —
  decode strings {"never","less","less-equal",…}→VkCompareOp (the blob already
  did the semantics; native just maps names).
- **PrimitiveTopology(5), CullMode(3), IndexFormat(2), LoadOp/StoreOp(2):** 1:1.
- **VertexFormat(8):** float32{,x2,x3,x4}→R32{,G32,B32,A32}_SFLOAT;
  uint32{,x2}→R32{,G32}_UINT; uint8x4→R8G8B8A8_UINT; uint8x4_unorm→_UNORM.
- **Sampler:** create_sampler passes 4 scalars (mag/min linear, address_mode
  enum {clamp_to_edge,…} @wgpu.zig:1024, mipmap linear) → VkSamplerCreateInfo
  1:1.

## Appendix G — audio externs → native voice mixer (20)

create/close/resume_context → WASAPI init/teardown/no-op ·
get_sample_rate/current_time/master volume get+set → mixer state ·
load_buffer/unload_buffer → PCM store (id table) ·
play_buffer/_at/_with_offset → spawn voice {buf, pos, when, loop?} ·
pause/resume/stop_buffer + is_buffer_playing → voice ops ·
decode_ogg_bytes/is_decode_ready/take_decoded_buffer/cancel_decode → job on the
mixer thread using zimr's pure-Zig ogg decoder (poll shape identical to web).
