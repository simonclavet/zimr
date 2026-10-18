# zimr on every platform - the plan

Version 3, Oct 7, 2026: after studying raylib (its ten platform files), sokol (`sokol_app.h`, `sokol_audio.h`) and
SDL3 (its main callbacks, its video backend contract, its Windows backend). **The web and Windows come first**, and
the API every platform implements is decided now, in `platform_api.md`, so that each later platform is that API
implemented once more. The Vulkan port's journal (`vulkan_port_plan_v2.md`) keeps the history; this file is the road
ahead. Each step names its files, how it is verified, and when it is done.

## 1. The goal, and the principle that gets us there

zimr runs on the web (WebGPU), Windows, Linux, macOS, iOS and Android, from the same app code: no example changes
for a platform, ever. Every platform difference lives in the build, the engine or a host.

**Done, for a platform**, means all 32 flagships run from the launcher with rendering, compute, input (keys, typed
text, mouse or touch, wheel, focus), audio, jobs, saved state, clipboard, cursor shapes, pointer lock (desktop),
gamepads, high-DPI scaling, resizing, minimizing and the app lifecycle - each as the browser build behaves, except
where a platform cannot, which its code states by name.

**And the code reads like a course**: every platform file explains its mechanism in full; the backends tutorial
gains a chapter per platform; each phase ends with a review like Oct 7's.

**The principle: proven code, verified here.** Few things will be tried on devices, so confidence has to come from
two other places:

1. **Port, do not invent.** Each platform file follows a named, mature implementation - GLFW, sokol, raylib, Google's
   `android_native_app_glue`, SDL's controller database, `stb_vorbis` - translated faithfully into zimr's Zig with
   its edge cases kept, and cites what it follows (as the Windows input already cites RGFW's three scancode
   corrections). A behaviour no reference has is a red flag, not a feature.
2. **Verify everything that can run here.** The engine and every example run headless on lavapipe (a headless
   platform, decision D12); Linux runs in real X servers (Xvfb); every platform's binaries are built here on every
   change - Windows, Linux, macOS and Android all compile in this sandbox (macOS and Android proven by probes on
   Oct 7: no Apple SDK, no NDK). What is left for devices is the thin layer of system calls each platform makes,
   and checklists cover it.

**Minimum versions:** Windows 10 1703 (per-monitor DPI v2); Linux with glibc 2.31; macOS 15 on Apple Silicon
(KosmicKrisp), macOS 13 on Intel (MoltenVK); iOS 17; Android 13 (API 33) with a Vulkan 1.3 driver.

## 2. Where things stand

| Area | State (Oct 15; the Oct 7 table below it) |
|---|---|
| Web | complete (WebGPU); sound on the engine's own mixer, rendered in an audio worklet - music decoded by the engine's Vorbis decoder, the analyser computed from the renderer's frames; the browser's audio graph removed (7e3) |
| Native GPU host | Vulkan 1.3 core: rendering, readback, compute, checked headless on lavapipe (`vk-host-test`) |
| Windows | window, input, monitors and window state, cursor shapes, `keyName`, gamepads (XInput), the frame loop, every example as an executable and the native gallery; sound - the mixer, music and the analyser as on the web, out through WASAPI on its own thread - compiled and tested headless, **not yet heard on a Windows machine** |
| Headless | the contract without a window: every flagship scripted and captured, sound captured as WAV |
| Not done natively | jobs on threads and saved state as files (C4), loading by path (C10), text editing's clipboard and input-method composition (C6), pointer lock (C7), the drag and menu loops (C2), the surfaces' states (B7), the build matrix for the next platforms (B9) |

The table as it stood on Oct 7:

| Area | State |
|---|---|
| Web | complete (WebGPU) |
| Native GPU host | Vulkan 1.3 core: rendering, readback, compute (real atomics, a pass's dispatches ordered), checked headless on lavapipe (`vk-host-test`: clear, targets, read, compute, sort, churn, large writes) |
| Windows | window, input (keys, text, mouse, wheel, focus), frame loop; `hello_world` runs; the launcher compiles and links, not yet run |
| Not started natively | audio, jobs, saved state, clipboard, cursor shapes, pointer lock, gamepads, window state, monitors |

**Found while studying the references** (each scheduled below):

- **The window freezes while dragged or resized on Windows**: Windows runs its own loop inside `DefWindowProc` during a
  drag, so ours stops. sokol keeps rendering from a timer (`WM_ENTERSIZEMOVE` starts it, `WM_TIMER` renders,
  `WM_EXITSIZEMOVE` stops it). `win32.zig` has none of this.
- **The surface is made once, with the device.** Android destroys and recreates an app's window while the app
  lives; raylib then rebuilds only the surface and keeps every resource ("context rebind"). The host needs to attach
  and detach surfaces.
- **One swapchain path panics** ("no swapchain - the window is zero-sized") where sokol skips the frame and retries;
  sokol also records that creating a swapchain can fail while a window is minimized (Windows with NVIDIA).
- **Audio is more than an output.** `sound.zig` drives the browser's audio graph: a buffer-source node per sound,
  gain nodes, analyser nodes - and the browser decodes OGG (`decodeAudioData`). Natively that is a mixer, a Vorbis
  decoder and an analyser to write before any system's output.
- **The engine's input contract lacks events** sokol's apps rely on: focus and unfocus as events, suspend and resume,
  resize, minimize and restore, quit requested, relative mouse motion, mouse enter and leave, modifiers, touch
  cancel. (The browser build has the same gap: a key held while a page loses focus stays down.)

## 3. What raylib and sokol teach

| # | Lesson | Where it comes from |
|---|---|---|
| L1 | One explicit contract every platform implements, with a template for a new one | raylib's `rcore_template.c`: about fifty functions - window state, monitors, cursor, clipboard, time, `PollInputEvents`, `InitPlatform`, `ClosePlatform` |
| L2 | The platform owns the loop and calls the app; the app never owns it | sokol's `sapp_desc` callbacks - iOS (`CADisplayLink`), Android (its own thread), the web (`requestAnimationFrame`), macOS (`CADisplayLink` too) all require it |
| L3 | A matrix of which feature each platform has, kept honest | sokol's "FEATURE/PLATFORM MATRIX": touch only on mobile, no screen keyboard on Android, no window icon on macOS |
| L4 | Keep the device, rebuild the surface | raylib's Android `APP_CMD_TERM_WINDOW`/`APP_CMD_INIT_WINDOW` ("contextRebindRequired") |
| L5 | Android: the app on its own thread; every callback hands over and waits for the app's acknowledgement | sokol's `_sapp_android_msg_set_native_window` (pipe, mutex, condition variable) and `android_native_app_glue`; `onNativeWindowDestroyed` returns only once the app has stopped using the window |
| L6 | A paused app sleeps in its event wait, rendering nothing | raylib's `ALooper_pollOnce(appEnabled ? 0 : -1, ...)` |
| L7 | Recreate the swapchain when the window's size changes, not only on `OUT_OF_DATE`; tolerate a failed creation while minimized | sokol's `_sapp_vk_swapchain_next`: on Linux+Intel, Windows+Intel and Windows+NVIDIA acquire "essentially always succeeds" |
| L8 | Keep rendering during a window drag on Windows | sokol's `WM_ENTERSIZEMOVE` timer; its guard against messages during `CreateWindow` |
| L9 | Linux: X11 first; it runs everywhere, Wayland desktops included (XWayland) | sokol has no Wayland at all; GLFW (raylib's default) does both |
| L10 | X11 keys by XKB key names (`TLDE`, `AE01`): physical positions, robust to X servers whose keycodes are not evdev's | GLFW's `createKeyTables` and sokol both use `XkbGetNames`; sokol falls back to keysyms |
| L11 | X11 text through XIM (compose, dead keys) | GLFW (`XOpenIM`, `Xutf8LookupString`); sokol's plain `XLookupString` composes nothing |
| L12 | Audio: one small backend per system, the app's samples pulled on an audio thread or pushed into a ring | sokol_audio: WASAPI, ALSA's `default` device (PipeWire and PulseAudio serve it), CoreAudio, AAudio |
| L13 | Gamepads need a mapping database, not only per-OS code | GLFW compiles in SDL's community database (`mappings.h`: 929 mappings, 257 KB) over XInput/DirectInput, evdev and IOKit backends |
| L14 | Smooth the frame time: average recent frames, clamp the spikes | sokol's `_sapp_timing_*` (`sapp_frame_duration` filtered, `_unfiltered` raw) |
| L15 | A platform with no window, for running without a device | raylib's `rcore_memory.c` (memory framebuffer, no OS); sokol's NOAPI |
| L16 | A platform layer can be swapped behind its contract | raylib's desktop backends: GLFW, SDL, RGFW, native Win32 |
| L17 | Four entry points - init, iterate (a frame), event, quit - each able to end the app; faked with a loop where a platform does not need them | SDL3's main callbacks (`SDL_AppInit`, `SDL_AppIterate`, `SDL_AppEvent`, `SDL_AppQuit`; `docs/README-main-functions.md`) |
| L18 | Text input is a mode: started with properties (the field's kind, capitalization, autocorrect, multiline), placed at the caret, stopped | SDL3's `SDL_StartTextInputWithProperties`, `SDL_SetTextInputArea`, `SDL_ClearComposition`; the backend's `StartTextInput`, `UpdateTextInputArea` |
| L19 | Platforms disagree on what a coordinate is: physical pixels (Windows, X11, Android) or logical points (macOS, iOS, Wayland) | SDL3's `docs/README-highdpi.md` and its table |
| L20 | Gamepad face buttons named by position (south, east, west, north), labels queried separately; confirm and cancel remappable | SDL3's `SDL_GamepadButton` |
| L21 | Windows: the drag and menu loops (`WM_ENTERMENULOOP` too), nested, releasing held keys on entry; AltGr's synthesized Left Ctrl dropped; focus regained re-reads buttons, lock keys and the pointer's confinement | SDL3's `SDL_windowsevents.c` (`SkipAltGrLeftControl`, `WIN_UpdateFocus`) |
| L22 | On the web, text needs a focused hidden input element: SDL reads `keypress` and composes nothing | SDL3's `SDL_emscriptenevents.c`; egui's "text agent" and Flutter's web engine do it right |

**Considered and set aside: building on SDL3.** SDL3 is the most battle-tested single layer (X11, Wayland, Win32,
Cocoa, UIKit, Android, input methods, gamepads, audio). It would cut risk most - and give up what zimr is: pure Zig,
no C dependency, and platform code a reader can learn from. Kept instead: SDL's controller database (L13), its source
as a reference for the hardest cases (input methods, Android text), and the contract (L16) leaves room for an SDL3
platform later as a fallback, should one ever be needed.

## 4. Decisions

**D1 - One native GPU host: Vulkan 1.3 core.** Every native platform runs `wgpu_vulkan.zig` and the same SPIR-V; the
web keeps WebGPU. The host interface stays backend-neutral (it is what the browser bridge implements), so a Metal
or Direct3D host remains possible behind it, unplanned.

**D2 - Apple through a Vulkan-on-Metal driver.** KosmicKrisp (LunarG's Mesa driver: conformant Vulkan 1.3 on Apple
Silicon, macOS 15 and later on Metal 4; Vulkan 1.4 in Mesa 26.2; iOS expected within the year); MoltenVK for Intel
Macs and for iOS until then. The host enables `VK_KHR_portability_enumeration` (with the enumerate-portability flag)
on Apple, and `VK_KHR_portability_subset` whenever a device offers it. MoltenVK's support for each 1.3 feature the
host uses is checked at bring-up.

**D3 - Android through NativeActivity, Vulkan 1.3 required.** Android supports 1.3 from Android 13 and 1.4 from 16,
but the driver decides: the host refuses a device below 1.3 by name. NativeActivity: no Java to build. Threading
exactly as L5, lifecycle as L4 and L6. Text: hardware keys and the soft keyboard's plain text through JNI; full
input-method composition is a stated limitation (sokol's Android has no screen keyboard at all).

**D4 - System libraries loaded at run time, everywhere it is allowed.** Linux: libX11, libXi, libwayland-client,
libxkbcommon, libdecor, libasound, the Vulkan loader - one binary for every distribution, and a missing library is a
message. **macOS too** (new): the Objective-C runtime (`/usr/lib/libobjc.A.dylib`) and the frameworks (AppKit,
QuartzCore, AudioToolbox, GameController) are loaded at run time and their classes looked up by name - so macOS
binaries build here with no SDK (proven Oct 7: arm64 and x86_64 executables, AppKit's `NSApplication` looked up at
run time). **Android**: built here against stub libraries named as the system's (`libc.so`, `liblog.so`,
`libandroid.so`, `libdl.so`) - the device's own are loaded (proven Oct 7: a NativeActivity library exporting
`ANativeActivity_onCreate`, needing `liblog.so`). **iOS** links its frameworks (the App Store path; built on a Mac,
with the SDK and signing).

**D5 - The platform contract (L1, L2, L16).** `src/platform/contract.zig` lists every declaration a platform
provides; a comptime check names any missing one (as the GPU host interface is checked); a platform that cannot do
something declares it - `pub const setWindowIcon = unsupported("macOS has no window icons; the dock's changes")` -
so what is missing, and why, is visible. Selected at compile time by the target's OS; on Linux, Wayland or X11 at
run time. The contract: start (the platform calls the app's frame function - L2), the window (title, icon, size and
limits, position, fullscreen and borderless, maximize, minimize, restore, focus), monitors (count, current, position,
size, refresh rate, name, scale), the cursor (shape, show, hide, lock), the clipboard (text), time (monotonic),
`openUrl`, key names (`keyName`: a key's label in the current layout), gamepads, audio output, files (saved state),
threads (jobs).

**D6 - Events: sokol's set, in the engine's calls (L3).** The engine's input contract gains, on every platform and
the web: focus and unfocus (releasing held keys and buttons - closing the web's gap), suspend and resume, resize,
minimize and restore, quit requested, mouse enter and leave, relative motion (`dx`, `dy` - pointer lock), modifiers on
key and mouse events, and touch cancel. The bridge sends the same from the browser (`blur`, `visibilitychange`,
`pointerlockchange`, ...), so the engine sees one stream.

**D7 - Keys by physical position, one table per family, each tested.** DOM `KeyboardEvent.code` names, then the
bridge's own table (`dom_input.keyboardKeyFromDomCode`). Families: Windows set-1 scancodes (done); XKB key names,
shared by X11 (`XkbGetNames`) and Wayland (`xkb_keymap_key_get_name`) (L10); macOS `kVK_*`; Android `AKEYCODE_*`;
iOS HID usages. Typed text always from the system's text path (L11).

**D8 - The device lives, the surface comes and goes (L4, L7).** The Vulkan host gains `attachSurface(native
window)` and `detachSurface()`; the swapchain has three states - absent, valid, invalid (retried each frame) - and is
rebuilt when the window's size changes, on `OUT_OF_DATE` and `SUBOPTIMAL`, and on Android's rotation; a failed
creation marks it invalid and the frame is skipped, never a panic.

**D9 - Frame time filtered (L14).** The engine's frame clock averages recent frame durations and clamps spikes for
animation; the raw duration stays available. On the web too.

**D10 - Audio: one engine mixer, run each frame, pushed to one output per system (L12; revised Oct 9).** The engine
gains what the browser does today: a mixer (voices with volume, pitch, pan, looping), decoders (WAV; Vorbis, a port of
`stb_vorbis`, as raylib uses), an analyser (FFT). The mixer runs on the main thread, once per frame, mixing just
enough to keep a margin queued (`render_ahead`); each system's output drains that queue - a single-producer,
single-consumer ring - on its own thread: WASAPI; an AudioWorklet in the browser, replacing its audio graph from the
start; ALSA's `default` device later (sokol's choice, working under PipeWire and PulseAudio both); CoreAudio; AAudio.
Why on the main thread, studied against five systems (below): wasm has no threads without cross-origin isolation, so
the browser can only mix on the main thread anyway; a frame-driven mixer is deterministic - a headless run captures
its sound byte-identical, as it captures its frames; and one thread owning the voices needs no lock. The price is
latency - about 50 ms queued against Mach's 16 ms - acceptable for games, not for a rhythm game or a music tool.
The mix format is fixed: 48 000 Hz, stereo, 32-bit float, interleaved; each output converts (WASAPI's
`AUTOCONVERTPCM`, an AudioContext opened at 48 000 Hz). Time is exact, in frames at that rate.

The six systems studied, and what is taken from each:

| | where it mixes | taken |
|---|---|---|
| sokol_audio | nowhere - the program does; a callback, or pushed into a ring of packets | the push model (`saudio_expect`); WASAPI shared, event-driven, `AUTOCONVERTPCM` |
| Mach (`sysaudio`, `Audio`) | its `Audio` module, on the audio thread, SIMD, 16 ms ahead | SIMD accumulation; render-ahead as a named setting |
| raylib (`raudio`, miniaudio) | the device callback, under a mutex its own comment calls not real-time | the API names apps already use (`sounds`, `music`, `streams`, `waves`) |
| zoto / oto | a mux pulling players (readers): audio thread natively, main thread on the web | sources as readers; volume ramps; the worklet; `NOPERSIST` |
| Groove Basin (Andrew Kelley) | one stream decoded in PulseAudio's write callback, under its main loop's lock | the idioms: exact durations, optional-index enums, labeled-switch state machines, fallible work behind an infallible callback |
| miniaudio (and zaudio, its Zig binding) | a node graph, on the audio thread; parameters changed by atomic stores, smoothed | sample-accurate scheduled starts (4d); changes as quick (4c); a low-passed resampler (9); in the browser, a script processor unless built with wasm workers - the same constraint as ours |

The design weighed against them, property by property:

| | an audio-thread mixer (Mach, raylib, miniaudio) | zimr's frame mixer |
|---|---|---|
| a new sound starts | within a device period (~10 ms) | within a frame (up to 16.7 ms at 60 Hz), then 10 ms (4b) |
| a change to a playing voice | within a device period | after the margin (50 ms and up); within a frame and 10 ms with 4c |
| scheduled to the sample | miniaudio | with 4d |
| a main-thread hitch | the sound plays on | the sound plays on for the margin, then is silent |
| the same run, the same sound | no | yes: headless captures compared sample for sample |
| the browser | a script processor, or threads with cross-origin isolation | a worklet, else a script processor, no threads needed |
| the voices' state | shared by two threads: atomics, locks | one thread's; the threads share one ring |
| size | miniaudio ~96 000 lines of C | mixer ~800 lines, outputs ~300 each |

The frame mixer is the better fit for the engine: one model on every platform, the browser's included; determinism;
one owner for the voices. Its cost is the hitch row - a frame slower than the margin is heard - which the adaptive
margin answers, and which only an audio-thread mixer avoids. The change and scheduling rows are not costs of the
design: 4c and 4d bring them level.

**D11 - Gamepads: the web's standard layout (L13).** SDL's controller database compiled into tables at comptime (as
GLFW embeds it); backends after GLFW's: XInput and DirectInput on Windows, evdev on Linux, the GameController
framework on Apple (which maps itself), Android's keycodes.

**D12 - A headless platform (L15).** `src/platform/headless/`: no window; frames render into an offscreen image;
input comes from a script; frames are captured. Every flagship runs here on lavapipe for a fixed number of frames
with scripted input, and its frames are compared with stored references - the engine's behaviour, the same on every
platform, checked on every change without a device.

**D13 - Jobs on threads; saved state as files.** Jobs on a `std.Thread` pool with the web's worker semantics (a job
owns its inputs and returns its outputs). Saved state: one key-value store over files in the system's app-data
directory, written to a temporary file and renamed.

**D14 - Packaging.** Windows `.exe`; Linux ELF; macOS `.app` assembled here (`Info.plist` written by the build, the
Vulkan libraries in `Contents/Frameworks`, an ad-hoc signature); Android `.so` built here, the APK assembled with the
SDK's `aapt2`, `zipalign` and `apksigner` on Simon's machine (an APK writer in Zig is a later option); iOS on a Mac.

## 5. The phases

In this order: compute (shared by all); then the web and Windows - the platform API (`platform_api.md`) moved in on
both, its gaps filled on both, Windows completed (Simon tests it next); only then Linux on X11 (verified here), macOS
and Android (built here, run by Simon), iOS (on a Mac), Wayland last (XWayland covers it until then).

### Phase A - Native compute, end to end

- **A1. `compute_host` natively** - done Oct 7: `vk-host-test`'s `engine` check runs `Compute(double_it)` through
  `initGpu` (the SPIR-V path), `upload`, one batch of two `run`s and `readLatest`, waiting on `readGeneration`; on
  lavapipe, no leak (a debug allocator), no validation message. The test now imports the engine itself, built for the
  host with the native host's options (`zimr_vulkan_mod`), and reaches the Vulkan host through `z.wgpu`.
- **A2. zimrnum on the native host**: its GPU operations (tiled matmul and sum with barriers, the elementwise ones)
  headless, against its CPU results; plus a Windows build of the test. Done: within tolerance; compiles for Windows.
  First half done Oct 7: the sweep's judge - its six inputs, every case's reference (`Fixture`) and its bar
  (`barFor`) - moved from the `zimrnum_field` example into `zn_conformance`, so the web sweep and the native one
  judge by one definition; the example uses it, unchanged in behaviour. Second half, Oct 7: `vk-host-test`'s
  `zimrnum` check runs all 112 cases natively; 110 agree, and `expm1` and `tanh` on the tiny band do not (a few
  percent): `zm.expm1`'s Kahan formula needs `log(u)` accurate relative to its tiny result, which Vulkan and WGSL
  bound only absolutely (2^-21) on [0.5, 2] - a driver-dependent result on the web too. Fixed Oct 7: `zm.expm1` sums
  its series below `|x| = 0.5` (8 terms for f32, 14 for f64) and uses `e^x - 1` beyond, with a test against
  `std.math.expm1` over thirty decades of each sign; all 112 cases agree. The Windows build: `zig build
  vk-host-test-windows` (zig-out/windows/vk_host_test.exe), the same test from the same function
  (`addVulkanHostTest`), for a Windows machine's GPU. **A2 done.**
- **A5. The numerics modules per target**: the build's `kompute_mod` declares the web's target, and zimrnum and
  zimrrl import it - so every native compilation analysing them (the Windows engine included) holds a `kompute` built
  for another target, and a second `kompute` beside it is refused (or crashed the compiler). `vk-host-test` now has its
  own host `kompute`, zimrnum and zimrrl; the Windows context needs the same. **Done Oct 7:** `addNumericsModules(target)`
  builds the three for one target; the Windows engine and the Windows apps' context take Windows ones, the test takes
  its target's.
- **A3. The four host stubs** any example reaches (mip-level and array-layer views, adapter info, texture-to-buffer
  copies), each with a check. **Done Oct 7, all four:** `createTextureView` takes a `ViewRange` (base level, level
  count, layer count; null as WebGPU's defaults) and sizes a view by its base level; `adapterInfo` writes `vendor |
  device | Vulkan x.y`; `encoderCopyTextureToBuffer` copies level 0 from the general layout, its byte pitch turned
  into texels. Checks: `copy` (every texel of a 4 by 4 texture read back exactly - a clear color of exact 8-bit values),
  `views` (a pass into each of four mip levels, an array view; the validation layer judges), the adapter line. The
  host has no stub left: every call the engine makes is written.
- **A4. Synchronization validation** (open): why the layer reports no hazard for two writes without a barrier.
  Time-boxed.

### Phase B - The platform API, on the web and Windows

The migration of `platform_api.md` (section 8), each step leaving both platforms working:

- **B1. The contract**: `src/platform/contract.zig` - the event types, the function list, the comptime check - and a
  template platform (every function unsupported) that compiles, the starting point of each new platform. **Done Oct 7:** `contract.zig` holds the events (`Event` and its payloads), what requests take (`Cursor`,
  `TextInputOptions`, `TextInputArea` - one struct, not five arguments - `AudioFormat`, `Gamepad`, `Rumble`), the
  `requests` list (24 functions, each a name and its exact type) and `requirePlatform`, which lists every missing
  request and every wrong type in one compile error; refusal bodies are never analysed, so a platform's declared
  refusals pass. `template.zig` has every request refusing with its name. `src/platform.zig` names both (a module
  cannot import outside its root's directory, so the namespace sits in `src/`); `platform-contract-test` runs the
  check's tests and the template against the contract.
- **B2. The move**: `src/platform/web/` and `src/platform/windows/`, today's code behind the contract, behaviour
  unchanged; `receiveEvent`, the engine's one place for events. Done: the web's pages and `hello_world.exe` behave as
  before; the input tests pass unchanged. **Oct 7, first part:** `receiveEvent(contract.Event)` in `wgpu_app.zig` is
  the engine's one place for events (each mapped to the bridge's `inputPush*` calls; DOM buttons mapped there, text
  handed over a code point at a time); Windows reaches it through `native_input.ContractEvents`, which converts the
  queue's events (a button where the pointer last moved, a move's movement, a character as UTF-8). The queue now
  stores DOM buttons, the engine mapping them once. **Oct 7, second part:** the web too - the exported
  `input_push_*` calls build contract events (positions in CSS pixels, a button where the browser's pointer last moved,
  a character as UTF-8, touches and device motion) and call `receiveEvent`, which now does the work the exports did
  (the app's input state, `cssToLogical`, the button mapping). The bridge passes `event.button` unmapped and a
  touch's release position. **Oct 7, third part:** `src/platform/web.zig` (14 requests written through
  `web.dom` - the time, size, title, fullscreen, cursor, pointer lock, clipboard text, URLs, saved values, rumble, the
  console - the rest refusing with what the bridge lacks) and `src/platform/windows.zig` (the time, the window's size
  from `native_loop.size()`, the log; the rest naming the Win32 call it waits for); `platform.current` chosen by target
  (the template elsewhere); `wgpu_app.zig` checks it in every build; each module compiles its written requests in a
  comptime list at its end (a broken one fails the build - tried). **B2 done, Oct 7:** the headless platform
  (`current` off the browser and Windows; no C library); the engine's logging through `platform.current.log`; one
  standard-error log for the native and headless platforms and the native loop, `platform/console.zig` (no import
  cycle). Deliberately later: the engine's title, cursor, clipboard and saved-value calls move onto the platform as
  B4 writes each request on Windows (moved earlier, they would hit the Windows refusals); moving today's files into
  `src/platform/web/` and `src/platform/windows/` waits until it buys more than churn.
- **B3. The missing events** on both: modifiers, movement, focus, hidden and shown, resized, enter and leave, touch
  cancel, the asynchronous results. Tested from synthetic events on any host. **Focus done, Oct 7:** Windows queues
  `focus_gained`/`focus_lost` (`WM_SETFOCUS`, now forwarded, and `WM_KILLFOCUS`); the browser reports the window's
  `blur` and `focus` (`input_push_focus`); `receiveEvent` releases every key and button on `focus_lost`
  (`input.releaseHeld`). The translator's held-key record went with its own release - PrintScreen, whose press
  Windows usually swallows, keeps one flag. This fixes a stuck key on the web, where a key held as the page lost the
  focus stayed down. **Key labels done, Oct 7** (the review's adoption): `KeyDown.label`, what the key types
  on the current layout without modifiers, lowercased - Windows from `MapVirtualKeyW(MAPVK_VK_TO_CHAR)` in the window
  procedure (the translator stays pure), the web from `KeyboardEvent.key` when one character. The engine records
  each key's label (`input.setKeyLabel`) and matches a LETTER chord to the key that types the letter
  (`letterKeyPressed`); other keys, and keys with no label, match by position. Ctrl+Z is undo on AZERTY. Modifiers
  in events stay empty for now: the engine derives Ctrl, Shift, Alt and Super from those keys' own states. **Hidden,
  shown and resized done, Oct 7:** Windows reports them from the native loop (minimized is hidden; a change of
  logical size or scale is a resize), the web from `visibilitychange` and the `ResizeObserver`. The engine keeps the
  focus (`app.window_focused`, copied into each frame's `WindowState.focused`, a launcher child's too); hidden and
  shown are received and kept nowhere (no frame runs while hidden), resized likewise (each frame reads the surface).
  The bridge's `ex`, `callIfPresent` and `numArg` moved to file scope: every namespace calls the module's exports. **Movement done,
  Oct 7:** `getMouseDelta` is the motion the move events carried, summed per frame (`InputState.mouse.movement`,
  cleared by `endFrame`), not the step between positions - the same while the pointer is free, and correct while it
  is locked, when browsers hold the position still: the delta was zero then, which broke mouse-look after
  `disableCursor`. The bridge reports `movementX`/`movementY` (scaled as positions are) with the lock state; the
  export takes them while locked and the position step otherwise, which every browser reports alike for touches.
  **Enter and leave done, same day:** `isCursorOnScreen` reads what the platform last reported - the canvas's
  `mouseenter`/`mouseleave` on the web; on Windows the first WM_MOUSEMOVE after a departure, which asks
  `TrackMouseEvent` for the next WM_MOUSELEAVE and forwards zimr's own `message_pointer_entered` (from WM_APP).
- **B4. The missing requests** on both: cursor shapes, fullscreen, pointer lock, keep awake, open URL, clipboard,
  saved state.
- **B5. Text input as a mode**: the web's text agent, the Windows IME, the UI's text fields using them.
  **Studied against Dear ImGui 1.93 (Oct 7)** - `InputTextEx` (imgui_widgets.cpp), `ImGuiInputTextState`,
  imstb_textedit.h, and the Win32 and SDL3 backends. ImGui's field is a whole editor: UTF-8 text; char, word, line
  and text-end moves; selection by Shift+moves, mouse drag, double-click (a word) and triple-click (a line), Ctrl+A;
  cut, copy and paste with the Windows alternatives (Shift+Delete, Ctrl+Insert, Shift+Insert), copy and cut refused
  for a password; undo and redo (Ctrl+Z, Ctrl+Y, Ctrl+Shift+Z), Escape reverting the field to its text at
  activation (or clearing it, `EscapeClearsAll`); Ctrl+Backspace/Delete deleting words; the caret kept in view
  (horizontal scroll); typed characters filtered - control characters, DEL, the private-use range - and a pasted
  line break in a one-line field turned into a space; full-width digits made half-width in numeric fields. For input
  methods it draws nothing itself: each frame the active field reports the caret (`ImGuiPlatformImeData`:
  `WantVisible`, `InputPos`, `InputLineHeight`), and the backend places the system's composition window there
  (Win32: `ImmSetCompositionWindow` with `CFS_FORCE_POSITION`, `ImmSetCandidateWindow`; SDL3:
  `SDL_SetTextInputArea`); committed text comes as `WM_CHAR`/`WM_IME_CHAR` UTF-16, surrogates paired
  (`AddInputCharacterUTF16`).

  zimr in the browser is the browser's own editor (the DOM overlay), at or above ImGui - inline composition, phones'
  keyboards - with two gaps: a field's `char_filter` callback never runs on what the overlay typed, and an edit that
  keeps the length is not reported as one. zimr natively had only a caret: no selection, no undo, no word moves, no
  copy or cut, no horizontal scroll, ASCII only. Done the same day: typed characters reach native fields at all
  (`charsTyped`), paste (both widgets), a pasted line break as a space in one-line fields. The steps, in order:
  - **T1. The editing core, `text_edit` in `ui.zig` - done Oct 7** (first written as its own file, then moved into
    `ui.zig` beside the fields that use it, at Simon's preference for large files). UI-independent and fully tested: a caret and a selection anchor
    over the field's buffer, UTF-8 aware (insertions and deletions at character boundaries); moves by character, word
    (ImGui's boundary rule), line end and text end; select all; delete a word; undo and redo as a bounded stack of
    records (position, text removed, text inserted), typing runs grouped; the text at activation kept for Escape;
    characters filtered on the way in, as above. Written: `Text` (storage and bytes used) and `Editor` (caret, anchor, history,
    the text to revert to); moves, `selectAll`, `placeCaret`, `selectWord`, `selectLine`, `insert` and
    `insertCharacter`, `deleteBackward`/`deleteForward` by character or word, `deleteSelection`, `undo`, `redo`,
    `revert`, and `admit`. Undo groups typing a word at a time (stb_textedit undoes per character) in 128 steps over
    8 KB, forgetting the oldest; Escape keeps 16 KB. Twelve tests, run with `ui.zig`'s; tutorial 13.9.
  - **T2. Native single-line fields on the core - keyboard, clipboard and drawn selection done Oct 7:** typed
    characters through the filters and `admit` (any UTF-8 character now), a paste as one undo step, Ctrl+A, copy
    and cut (never from a password), undo and redo, Backspace/Delete by character or word, moves by character or
    word with Shift extending, Home/End, Shift+click; Escape reverts (as ImGui) unless the field clears; the
    selection drawn in the style's new `text_selected_bg`; the core moved above `InputTextState`, which holds the
    editor. Three widget tests, and the existing P9 series unchanged. **Mouse and scroll done Oct 7:** clicks
    counted (0.3 s, 6 px: one places the caret and drags, two select a word, three the line); a drag extends the
    selection past the field's ends; `keepCaretInView` scrolls by a quarter of the field, never past the text's
    end; drawing clipped to the field. Three more tests, with a monospace test font. **T2 complete.** Was still to
    do: every key above, the clipboard (copy and cut through
    `z.setClipboardText`, refused for passwords), the mouse (click, drag, double- and triple-click, Shift+click),
    the selection drawn, the caret placed at measured glyph widths, horizontal scroll following the caret.
  - **T3. Multiline on the same core - keyboard done Oct 7:** the editing both widgets share extracted
    (`editFieldNatively`, `escapeFieldNatively`); the multiline field adds Enter (a line break, undoable as a step),
    tab where allowed, Up/Down/Page Up/Page Down keeping a remembered x (`moveCaretVertically`), Home/End by line
    and Ctrl+Home/End by text, a click placing the core's caret, and the selection drawn across lines
    (`drawSelectionLines`); `insertAtCursor` removed. **Mouse and scroll done Oct 7:** clicks counted and dragging
    by (x, y) in the scrolled text (`multilineOffsetAt`); the scroll kept per field in the per-id storage
    (`MultilineScroll`), following the caret only when it moves (or when the field begins editing), clamped to the
    text, and scrolled by the wheel over any field whose text is taller than it shows; drawing clipped to the field.
    **T3 complete.** The example `ui_text_editing` (Oct 7) shows T1-T3: fields of one line (a long line, accents,
    a password, digits only, Escape clearing, Enter committing) and of several (notes, a read-only log for the
    wheel), with the keys listed. Was planned as: line starts, Up/Down and PageUp/PageDown keeping the column,
    Ctrl+Home/End, the parent's vertical scroll following the caret.
  - **T4 - done Oct 7: input methods on Windows.** The frame's request for text input (`wantTextInput`, cleared by
    `endFrame`), made by an active native field with its kind and area; the engine applies it (`applyTextInputWish`,
    the fit mode mapped back); Windows associates the input method only while a field takes text and never for a
    password (`ImmAssociateContextEx`), off from the window's opening, and places the composition at the caret and
    the candidates outside the field (`ImmSetCompositionWindow`, `ImmSetCandidateWindow`); the web and headless
    platforms do nothing for these requests. To try on Windows with an input method. Was planned as:
    **T4. Input methods natively:** the active field reports its caret each frame through the contract's
    `setTextInputArea` (with `startTextInput`/`stopTextInput`), as ImGui's `PlatformImeData`; Windows places the
    composition and candidate windows there (IMM, as ImGui's default); committed text from `WM_CHAR` and
    `WM_IME_CHAR` with surrogates paired.
  - **T5 - done Oct 7:** the browser's text compared whole with the field's, so an edit keeping the length is
    seen; the inserted characters (between the shared start and end) through the field's filters, the
    `char_filter` callback included (`filterBrowserEdit`); the filtered text given back to the page's input or
    text area with its caret (`js_set_overlay_input_text`, `js_set_overlay_textarea_text`, the caret converted
    from bytes to UTF-16 units). **The text-editing plan, T1-T5, is complete.** Was: **T5. The browser's two gaps:** the `char_filter` callback run on the overlay's text, and any change of its
    bytes reported as an edit.
  An example exercising all of it on both platforms: `ui_text_editing`.
- **B6. The frame clock's filter** (D9), on both. **Done Oct 7:** `runtime.core.FrameTimeFilter`, after sokol_app's
  (held to 1 us .. 100 ms; an exponential moving average, a fortieth a frame; a change of pace over 4 ms adopted at
  once); `f.time.delta_time` is filtered and `raw_delta_time` measured, in the frame driver every platform shares,
  and `getFrameTime` likewise; three tests - jitter smoothed to within 0.2 ms with the totals in step, a change of
  pace adopted at once and a spike held to 100 ms, a constant duration passed through unchanged. Animation in every
  example is now filtered, by design; no stored frames exist to compare against yet - that is B8's to build.
- **B7. The GPU host's surfaces** (D8): attach, detach, the three swapchain states; `vk-host-test` detaches and
  reattaches a headless surface (`VK_EXT_headless_surface`, which lavapipe offers).
- **B8. The headless platform** (D12): the contract implemented without a window; `zig build examples-check` runs
  every flagship with scripted input and compares its frames. Done: all 32, under five minutes.
  Steps: (1) the host's headless screen; (2) a headless frame driver, on a scripted clock; (3) scripted input;
  (4) frames captured and compared with stored references; (5) the step over every flagship. **(1) done Oct 7:**
  `startHeadlessWithScreen(width, height)` in the Vulkan host - an RGBA8 texture the surface calls serve as a
  swapchain image (cleared to zeros as each frame first asks, the frame slot advanced by the present, the view the
  host's), read back from `headlessScreenTexture()`; `vk-host-test`'s `screen` check draws a frame of an exact color
  and a cleared one, and reads both back, on lavapipe under the validation layer. **(2) done Oct 7:** the host kind
  `headless` (`host.zig`; `drives_own_frames` for the runner), the Vulkan host's scripted clock (`setClock`, which
  `nowMs` answers), and `native_loop.headless` - start with a screen of the window's size, 60 frames at exactly
  1/60 s from a clock at 1 s (zero means "no previous frame" to the frame driver), report frames run against frames
  drawn on the screen; the headless engine module and app context in the build (the Windows context's twin for the
  build's machine, libc for `dlopen`), `nativeAppExe` (was `windowsAppExe`). `zig build hello-world-headless`: 60
  frames run, 60 drawn on the screen, validation 0 errors and 0 warnings, on llvmpipe. **(4), capture half, done
  Oct 7:** `-Dcapture=0,30` (`ZIMR_CAPTURE`, `ZIMR_CAPTURE_DIR`) saves frames as PNG into zig-out/headless/<name>/ -
  the host's `readHeadlessScreen` (copy, read, wait on the timeline), the driver's capture call, `wgpu_app`'s PNG
  writer (`codecs.png`); `<name>-headless` for hello_world and every flagship (`addHeadlessRun`). rt_sidebyside:
  frame 0 saved, 60 drawn, validation clean. Comparing with stored references remains. **(3) done Oct 7:** scripted input
  (`native_loop.headless.readScriptLine`): `frames`, and per frame `move`, `press`, `release`, `wheel`, `key_down`,
  `key_up`, `text`, `capture`, delivered as the contract's events before the frame; modifiers from held keys; a bad
  line stops the run with its number. `ZIMR_SCRIPT`/`ZIMR_FRAMES`/`ZIMR_CAPTURE`, `-Dscript`/`-Dframes`/`-Dcapture`;
  every example has `<name>-headless`, installed as zig-out/headless/bin/<name> for direct reruns. Determinism
  checked: rt_sidebyside's frames 0, 30 and 59 byte-identical across two runs. **First finding, fixed:** the UI
  host never filled the UI snapshot's keys - in the engine, on every platform, the UI saw no first key press and no
  held modifier (only repeats, through a fallback); unit tests built their snapshots by hand. `ui.fillSnapshotKeys`
  from the engine's input state each frame, tested through it. **Second finding, fixed:** ui_text_editing's Accents
  field drew "?" for accented letters - on every platform where the engine draws the text: `z.loadFont` loaded
  printable ASCII only. It now loads ASCII and Latin-1's upper half (160..255), as the built-in bitmap font covers;
  seen through the loop, and a double-click on "Ångström" selects the whole word (UTF-8 word boundaries). Seen, not
  yet looked into: the selection highlight is faint on an active field; rt_sidebyside's "CPU rt_fs" label sits
  under its info panel's title. **The headless platform, a person's side (Oct 7):** a clipboard
  (`setClipboardText`, `requestPaste`), pointer lock and fullscreen granted, saved values, title, cursor and text
  input kept - all in memory, for the run; outcomes wait as events (`takeEvent`), delivered by the driver before
  each frame; the paste command (Ctrl+V without Alt, Shift+Insert) followed by the clipboard's text, as on Windows;
  a script's `paste` line; the platform's size set to the screen's. Seen through the loop: a copy from Name, a
  Ctrl+V into Clears, a system paste of "12ab34" into Digits keeping "1234".
- **B8, redesigned (Oct 7, after review).** The first driver planned a whole run up front - absolute frame
  numbers, lines in order, read in full before the first frame - so it could not pause and resume; it tangled
  parsing with acting; it exited the process on a bad line; and its scripted clock was wrong in kind. The best form:
  1. **Time is an input.** Whoever drives frames gives each frame its time - the browser's frame tick, the Windows
     loop's clock at a frame's start, a headless run's script - through `update`'s argument, and the engine derives
     `f.time` from it. `wgpu.nowMs()` stays a real clock everywhere, for measuring work: a scripted clock standing
     still within a frame hangs any "work until the budget is spent" loop (cartpole_duel's learner has one). The
     Vulkan host's scripted clock goes.
  2. **A command stream, executed as it arrives.** No plan: each line runs when read. Input lines queue events for
     the next frame; `advance [n]` draws frames - the only thing that moves time - so a run is paused whenever it is
     waiting for its next line, and resumed by more lines. One language for files and for live sessions: a session
     is a command file appended to while the program reads it (`tail -f commands | program`), so its transcript is
     itself a replayable script, and a replay draws the same frames.
  3. **Parse, then act.** `parseCommand(line) -> Command` is a pure function, tested on its own; executing a
     command updates the person's model (pointer, held buttons and modifiers) and delivers events.
  4. **Observations reply on stdout**, logs stay on stderr: `capture [path]` replies with the file written; `sync
     <token>` replies once everything before it has run, which a session's caller waits for.
  5. **Errors are values.** A bad line is reported with its number and skipped - a session survives a typo - and the
     run's exit status is non-zero at the end when any line failed or the validation layer reported anything, so a
     script still fails as a test.
  6. **Arguments, not settings.** `zig build <name>-headless -- --script s.txt --captures dir` passes run arguments
     (`b.args`); the -D options and environment variables go.
  **(1) done Oct 7:** `update(frame_ms: f64)` - the bridge passes its tick's `performance.now()`, the Windows loop
  its clock at the frame's start, the headless driver its scripted time; `makeFrame(?f64)` (null for the frame an app
  initializes with); elapsed time counts from the first frame's time; the Vulkan host's scripted clock removed.
  cartpole_duel runs headless (its learner's budget loop ends); rt_sidebyside's frames stay byte-identical.
  **(2) done Oct 7:** the command stream. The language is a type - `native_input.Command`, a tagged union, one value
  per line written in ZON and read by `std.zon.parse` (unknown names and missing fields explained, with their
  position; strings with escapes) - `advance`, `move`, `press`, `release`, `wheel` (`Notches`), `key_down`,
  `key_up`, `text`, `paste`, `capture`, `capture_to`, `sync`, `quit`. `ScriptedPerson.eventsFor` turns a command
  into events; `isPasteCommand` is shared with the driver. `native_loop.headless.Session` executes lines as they are
  read: from the file `ZIMR_SCRIPT` names, standard input for "-", a second of frames without either; replies on
  stdout, log on stderr; a bad line reported with its number and skipped; exit status 1 when a line failed or the
  validation layer reported anything (`finishNative` returns the verdict; the runner exits with it). Seen live: a
  session paused and resumed through `tail -f` (typed "Ada", then select-all and "Grace"); a bad line reported, the
  session going on; the transcript replayed from scratch drew both captures byte-identical to the session's.
  **Scripts in a window (Oct 9):** the session is `native_loop.script`, shared by both loops through `Loop` (how a
  frame is drawn, how the paste command is answered); on Windows, `ZIMR_SCRIPT` plays a script in the window - frames
  at the script's times, `serviceWindow` pumping messages between them, the window closing at the script's end -
  with `vulkan_host.keepPresentedFrames` copying each frame before its present for `capture` (`readLastFrame`, BGRA
  swapped, alpha made opaque) and replies in `<script>.replies`. Built and linted for Windows, not yet run there; a
  test package went to Simon with two scripts and their headless reference frames. **Following (Oct 9):**
  `ZIMR_FOLLOW` - `script.ScriptFile` reads a growing file at its offset, takes whole lines only, and at the file's
  end waits through the loop (`Loop.wait`: a window keeps handling its messages; headless sleeps); a byte order mark
  at a script's start is skipped. Seen: a session with no external tool, one line appended in two halves and run
  whole; the session file replayed without following drew its capture byte-identical.
  **(5) done Oct 9 - every flagship, swept.** `launcher-headless` builds the launcher with all 32 flagships for the
  build's machine; `zig build flagships-check` runs `examples/launcher/sweep.zon` - each flagship 40 frames, switched
  by a click on the pill's "next" zone, captured into zig-out/headless/launcher/ - in about a minute, failing on any
  leak, validation message or failed line: a run is clean only with no error logged (`console.errorLineCount`, in
  `finishNative`'s verdict). The first sweep: every flagship drew, validation clean, and 411 leaks in three -
  `sph_fluid_2d` and `four_ways` freed neither their font (one image per glyph) nor, in `sph_fluid_2d`, its ten
  particle and grid arrays, and `four_ways` not its UI host; `helmet_sw` through `pbr3d.buildCpuMesh`, whose
  "known leak" of the glTF's mesh arrays had its free (`unloadMesh`) in the same file all along. All fixed; the
  sweep is clean. Comparing the captures with stored references is what remains of (4).
- **B8b. Recording a person's input** (later): the Windows and web platforms write what a person does as the same
  commands - `std.zon.stringify` of each `Command`, with `advance` lines between frames - so a bug found by hand
  reaches a headless run as a script that reproduces it.

- **B9. The build matrix**: `zig build platforms-check` compiles the launcher for the web, Windows, Linux, macOS and
  Android here on every change - the later platforms' code compiles before it runs anywhere.

- **B10. Every example as a native program, and the native gallery.** The web stays the default target; a native
  build is the web step's name with `-windows`: `zig build <example>-windows` for one example, `zig build
  all-examples-windows` for all of them - each its own executable, compiled in parallel as the web's standalone
  pages are - and `zimr_gallery.exe`, the native gallery (`zig build zimr-gallery-windows` alone). The gallery reads
  the web gallery's catalog (`src/web/manifest.json`), grouped by module; a click starts the example as its own
  process, so a crash belongs to it alone, and the row shows running, closed, or failed with the exit code.
  `windows_pending` in `build.zig` lists every example without a native build, with the reason the gallery shows.
  **Oct 7: the steps and the gallery written; the gallery built (1.2 MB); the full build left to Simon's machine.**
  The examples that used WGSL directly: `fluid_gpu` (superseded by `fluid_sort`), `pipeline_constants` (WGSL's
  `override`; Zig's `comptime` specialises on every backend) and `shader_inspection` (reflected pasted WGSL)
  deleted. The other four, checked against the catalog for an example already showing the same thing: deleted
  `pipeline_storage` (render-to-texture is `pipeline_rendertarget`, `split_screen`, `texture_readback` and
  `textures_framebuffer_rendering`; what was unique - a compute shader writing a texture - is what Zig kernels
  cannot do) and `forward_kinematics` (kinematic chains are `chain_ik`, `mocap_viewer`, `skinned_mesh`;
  instancing is `instancing` and `pipeline_instancing`, and instances reading a storage buffer is `fluid_sort`).
  `pipeline_mipmap` and `pipeline_array` - unique, and both views of one part of a texture - merge into one
  example with Zig shaders: a mip chain painted level by level through each level's view, shown level by level
  (`textureSampleLevel`) and on a surface where the GPU picks the level; a four-layer texture painted through
  each layer's view, shown through a 2D view of each layer (Zig shaders declare no array textures, and need none
  here). It needs no shader of its own: a level's or a layer's view wrapped as a `RenderTexture` is a render
  target for `beginTextureMode`, and the 2D renderer paints it; a view of one level, or the whole chain through a
  nearest-mip sampler, is drawn as a texture. **Done first:** `createTextureViewLayer` - a 2D view of one layer, at
  its first level - on both backends (the bridge's `createView` with `baseArrayLayer`; the Vulkan host's
  `ViewRange.base_layer`, whose views carry no range the barriers read, so the addition is local). **Done, same day:**
  `texture_views` (no shader of its own; built for the web and for Windows) replaces `pipeline_mipmap` and
  `pipeline_array`; the catalog has 298 examples, and `windows_pending` lists only networking and file saving.
  Tutorial 8.6 gained the layer view and how the GPU picks a level.
  Testing stays manual (Simon, Oct 7): the gallery starts each example for him to try, with no automatic closing
  or sweep. Remaining: the four conversions; then the pending facilities (a WebSocket client, file saving) under C3
  and C4.

- **B11. One step per app; the platform an option.** `zig build <app>` builds the app for `-Dplatform=web|windows`
  (default: the building machine's platform when zimr has one - Windows today - and elsewhere a step that fails
  naming the choices). A web build always produces both packagings from its one wasm: the served page
  (`web/<n>/`) and the single file (`standalone/<n>.html`). `all-examples` follows the platform (natively with the
  gallery); `serve`, `dist` and `test-all-examples` always reach the web builds through a hidden gathering step.
  **Oct 7, in `build.zig`:** 1,053 steps became 441 (the `-standalone` and `-windows` steps gone); `appBuildFor`
  picks an app's build or a failing step with the reason; the lint gate covers the apps' steps by the list the
  registration keeps. Checked: `hello-world` for the web (wasm, served page, standalone page), for Windows (the
  executable, after its no-WGSL check), and with no platform (the message). **Projects, same day:** zimr
  publishes its Windows context beside the web's; `Project.init` reads `-Dplatform` and builds the apps with the
  chosen context (host tests keep the web's numerics); `addApp` makes one step - the web build with both
  packagings, or the Windows program installed by the project's own builder (`installWindowsApp`; `addWindowsApp`
  split into making and installing) - and a project's `serve` names `-Dplatform=web` when asked under another
  platform. The template's and the test project's commands rewritten; `check` asks the test project for `basic`,
  `shaded` and `four_ways` with `-Dplatform=web`. Checked: the test project for the web (three apps, both
  packagings) and `basic` for Windows (its `.exe` in the project's zig-out). **Done, same day:** the editor
  configs' generator emits, per example, the web debug build (`-Dplatform=web`) and a release task in place of the
  standalone one - regenerated, all four files valid; the tutorials' commands (backends 11.9, the robot's
  single-file build) and the working guide's probe commands rewritten; dated records keep the names they ran.

- **B4 progress - pointer lock on Windows, the mechanics (Oct 7).** `win32.Window.lockPointer`: the mouse
  registered for raw input (its own motion, unaccelerated, whatever the cursor does), the cursor confined to the
  client area (`ClipCursor`, again on WM_MOVE and WM_SIZE) and hidden (WM_SETCURSOR); positions held still while
  locked, as browsers hold them; WM_KILLFOCUS ends the lock before the focus change is reported. Raw motion and the
  outcome travel as zimr's messages (`message_pointer_motion`, `message_pointer_lock_changed`), become queue
  events, and convert to a `mouse_move` at the held position carrying the hand's motion, and to
  `pointer_lock_changed`. The platform module carries out `requestPointerLock`/`releasePointerLock`. Absolute
  reports (tablets, remote desktops) carry no motion and are left out. **Wired, same day:** `disableCursor` and
  `enableCursor` (now `wgpu_app`'s) ask `platform.current`; the web reports `pointerlockchange`; `isPointerLocked`
  answers from `pointer_lock_changed`. The headless platform declines every lock (no pointer) rather than refusing
  to compile, since a declined lock is a correct answer. After reading sokol: the cursor is held at the client
  centre (a one-point confinement) and put back where it was on release. New example `input_pointer_lock`.

- **B4 progress - the title and the cursor (Oct 7).** `z.setWindowTitle` (new) asks `platform.current.setTitle`:
  `document.title`, or `SetWindowTextW` with the title cut at a character boundary to fit the window's UTF-16
  buffer. The cursor is a wish: `setMouseCursor`, `hideCursor`/`showCursor` and `disableCursor`/`enableCursor`
  only record in the input state, and the engine shows it once a frame after the update
  (`wgpu_app.showWantedCursor`) through `platform.current.setCursor`, when it differs from the one shown - so the
  UI, which asks the runtime directly, works on every platform, and the runtime needs no platform import. Windows
  shows system cursors (IDC_*), kept by WM_SETCURSOR over the client area; the borders keep Windows' own. The
  headless platform keeps no title and shows no cursor. A locked move in the browser keeps the held position (some
  browsers report zero while locked - seen on Simon's device). New example `input_cursor_shapes`.

- **B4 progress - fullscreen, keeping awake, opening an address (Oct 7).** `z.requestFullscreen(on)` with the
  outcome in `f.window.fullscreen` (`fullscreen_changed`, the browser's `fullscreenchange`); Windows: borderless,
  the frame removed and the window over its monitor, the placement saved and restored (Raymond Chen's method).
  `z.keepAwake(on)`: `SetThreadExecutionState`; the browser's Screen Wake Lock, asked again when the page returns
  (the browser releases it on hiding). `z.openUrl(url)`: `ShellExecuteW`, http/https/mailto only. Headless declines
  all three. New example `window_requests`. Tutorial 13.8. The build cache had reached 6.7 GB and the build's disk
  guard stopped it; a cold rebuild took under five minutes.

- **B4 progress - the clipboard's text and saved values (Oct 7).** `z.setClipboardText`, `z.loadValue`,
  `z.saveValue`, `z.removeValue`. Windows: CF_UNICODETEXT in movable global memory, the clipboard opened for the
  window (with no owner, `SetClipboardData` fails); values as files, `%APPDATA%\zimr\<program>\<key>.value` (key
  bytes outside [A-Za-z0-9._-] as %XX), written to `.new` and moved over in one step. The browser's values are now
  binary-safe (base64 through the `_bytes` functions, scratch from the wasm page allocator) - so layouts the UI saved
  earlier as text start fresh once. Headless keeps nothing. The UI's copy and its layout persistence go through the
  platform (UI persistence now works natively); `state_persistence` moved off `z.web.dom` onto the public API;
  `window_requests` gained a copy button. **Next:** paste as the contract's `paste` event on both platforms, and the
  UI's text fields on it - then B5.

- **Found on Simon's phone, Oct 7, fixed.** `window_requests` failed to load: the wasm imported
  `dom.js_is_fullscreen` and `dom.js_toggle_fullscreen`, declared in `web.zig` and never registered by the bridge -
  reached for the first time by `z.requestFullscreen`, and caught only when a browser instantiated the page. Both
  written (the request's rejection swallowed, as the pointer lock's). `state_persistence` crashed in the Claude
  app's viewer: a sandboxed frame without same-origin access throws on the mere read of `window.localStorage`; the
  bridge's `localStorage()` now tries the read (null when refused - values not kept, nothing fails), and `setItem`
  answers status 1 when storage is full instead of throwing. **Next: the import check** - a build-time tool, as
  `native_wgsl_check` is for Windows: every function a page's wasm imports must be registered by the bridge. A
  prototype (in /tmp, not kept) confirmed the bridge's three registration forms: `.set("name", funcNum(&...))`,
  `.set("name", func(&...))`, and `ZimrWasi.install`'s string arrays; with all three, the two rebuilt pages import
  nothing unregistered. **Then, same day:** `window_requests`' copy button took the page down in the viewer -
  `navigator.clipboard.writeText` rejects under the viewer's permissions policy, and an unhandled rejection is
  fatal. The bridge's `ignoreRejection` (file scope) gives a promise a do-nothing rejection handler; applied to the
  clipboard write, the audio context's `close` and `resume`, and the user-file reader - the bridge's audit of
  promise-returning calls found no others outside its own promise wrapper. **The import check, done the same day:**
  `tools/bridge_import_check.zig` reads a page wasm's import section and the names `src/bridge.zig` registers (all
  three forms) and fails the build on an import without a function. Every app's web build depends on it - zimr's
  through `finishWgpuApp`, projects' through `AppContext.bridge_import_check`. Checked: its tests; both pages pass;
  against a bridge without `js_is_fullscreen` it names exactly that import; the test project's `basic` runs it.

- **B4 progress - paste (Oct 7).** The contract's `paste` event on every platform, from two routes. The system's
  paste command: the browser's `paste` event (its text readable without the Clipboard API's permission, so it works
  in the Claude app's viewer); on Windows, Ctrl+V (not with Alt: AltGr types) and Shift+Insert read in WM_KEYDOWN,
  the key still forwarded. And `z.requestPaste`: `navigator.clipboard.readText` (its refusal ignored), or the
  clipboard read on Windows. Text reaches the engine through `inputPasteBuffer` (the bridge's `encodeInto`, cut at a
  character boundary) or the window's paste buffer (UTF-16 to UTF-8, whole characters); the input state keeps a
  copy for the frame (`z.getPastedText`, 32 KB). `window_requests` pastes. **The UI's text fields, same day:** in
  the browser they are DOM elements laid over the canvas, which paste (and type, and compose) by themselves; the
  native path read typed characters only from the snapshot's `chars_typed`, which nothing but the tests filled - so
  native UI text fields took no typing at all. `beginFrameRaw` now fills `chars_typed` (`runtime.input.charsTyped`,
  read without taking them from `getCharPressed`) and `pasted`; the engine's character queue empties at
  `endFrame`, as raylib's does at each frame's start; both widgets insert typed and pasted characters through one
  `insertAtCursor` (printable ASCII; line breaks in multiline fields); `Ui.getClipboardText` returns the latest
  paste. UTF-8 and input methods in native fields are B5.

- **B3/B4 progress - files the person hands the app, and saves (Oct 7).** The browser's overlay model, kept for
  every platform: the app draws its own Load and Save buttons and gives their areas each frame (`ButtonArea`, app
  pixels); a press there opens the platform's dialog; chosen and dropped files wait in a queue. **U1 done:** ten
  requests in the contract (`pendingFileCount`, `nextFileSize`, `nextFileName`, `readNextFile`, `discardNextFile`,
  `setFilePickerArea`, `hideFilePicker`, `offerFile`, `setSaveArea`, `hideSave`); the web forwards to `web.userfile`,
  headless answers nothing, Windows and the template refuse with a `@compileError`; `z.userfile` keeps the browser
  module's names, and `geno_ppo`, `getup_train` and `mocap_viewer` use it. **U2 done Oct 7:** a left press inside
  an area is held back from the app (and its release) and opens `GetOpenFileNameW` or `GetSaveFileNameW` once the
  frame's input is delivered; chosen and dropped (`WM_DROPFILES`, `DragQueryFileW`) files are read whole into a
  queue of 16 in the loop; the offered file is copied and written with `CreateFileW`; the three examples build for
  Windows and left `windows_pending`. Was planned as: on Windows, a press inside
  the picker's area opens `GetOpenFileNameW` (its filter from `accept`) and queues the file; inside the save area,
  `GetSaveFileNameW` with the offered name, then the file written; `WM_DROPFILES` queues dropped files; the three
  examples leave `windows_pending`.

- **B4 progress - a native WebSocket client (Oct 7).** Two pending examples need one: `net_ws_smoke` (`z.web.ws`)
  and `net_cursors` (`z.net.Session`, bound today to `Net(web.ws, web.rtc)`: introductions over the WebSocket,
  game data over WebRTC, which has no native counterpart - so natively a session must run on the server's relay).
  Shaped by Simon's pointer to `websocket.zig` (karlseguin): the protocol written in Zig over `std.Io` sockets,
  in as few files as possible, sharing code with the web side. **S1 done:** the protocol - `readFrame`,
  `writeFrame` (now with an optional client mask), `findHeaderValue`, `computeAccept`, the opcodes - moved out of
  `tools/signal_server.zig` and `tools/render_server.zig` (each had its own copy) into `net_core.websocket`, both
  servers using it; tested on RFC 6455's example and frame round trips, and live against the running server.
  **The client done Oct 7:** `net_core.native_websocket` - a detached thread per socket (connect through
  `std.Io.net.HostName`, the handshake with a random key checked against `computeAccept`, then frames: messages
  queued under the socket's lock, fragments gathered, pings answered, a close answered and ending it); sends masked
  from the app's thread under the same lock; closing shuts the stream down, and whichever of the thread and the app
  finishes last frees the socket, so closing never waits on a slow connect. `websocket.readHead` shared too (the
  signal server's handshake uses it). Live: open in one 10 ms wait, JOIN sent, WELCOME received, closed.
  **Reviewed Oct 7**, ten faults fixed: payloads read with `readSliceAll` (a `take` of the whole payload asserted
  the reader's 16 KB buffer could hold it, so larger frames crashed); `readHead` refusing a head that fills the
  buffer (`fillMore` asserted room) and waiting with `fill` (a zero-byte read is not an end); two locks, state and
  write, the reader never waiting on a write (one lock held through a blocking send could deadlock both ends); the
  stream closed only under the write lock; a message's parts gathered strictly (`MessageGatherer`); addresses with a
  query and no path, IPv6 in brackets, and over-long URLs (refused, no longer truncated); a close frame on close;
  `Upgrade` and `Connection` checked with the accept (`isAcceptedAnswer`); lengths in 64 bits. Opcodes became an
  enum; each fault has a regression test. **Wired in Oct 7:** the contract's `SocketState`, six socket requests and
  `epochMillis` (Windows: `GetSystemTimePreciseAsFileTime`); the web forwards to `web.ws`, Windows uses the native
  client with `ws://127.0.0.1:7777` as its origin, headless has no network and a clock at the epoch; `z.ws` (in
  `net.zig`) with the browser module's names, `z.net.Session` bound to it; a transport that cannot make direct
  connections relays every peer from the start (`net_core`, the session's `addPeer`). `net_ws_smoke` and
  `net_cursors` build for Windows and left `windows_pending`; only `net_rtc_smoke` (WebRTC) remains. The mesh test
  (`tests/net_mesh_test.zig`) is now part of `zig build test` - its own artifact, given `net_core` and `net_typed` as
  modules - with a case for a transport with no direct connections: peers relay from the start, messages flow both
  ways through the server (10 tests). **One thread owns each connection (Oct 7)**, for `wss://`: std's TLS client
  changes its write keys from within a read (a server's key-update request), so a read and a write must never
  overlap. The socket's thread now does all I/O - writes the queued sends, then reads a frame when `waitReadable`
  (`std.posix.poll`, or `WSAPoll` bound locally on Windows) says one is there, within 5 ms - and `send` only queues,
  returning at once as the browser's does (which also ends the blocking send). One lock, for the state and the two
  queues. **Next:** TLS under it - `std.crypto.tls.Client` over the stream's reader and writer, the system's
  certificates (`Bundle.rescan`) loaded once per process, the readiness check counting a whole TLS record already
  buffered. **Reviewed again Oct 7:** frames now leave in one write, client and both servers (a header written
  alone held its payload back for the other end's delayed acknowledgement - Nagle's algorithm - tens of
  milliseconds a message); the handshake waits for its answer in 5 ms steps, so closing ends the wait even against
  a server that never answers (its thread had been held forever); Windows' origin URL refuses a buffer too small
  rather than cutting it to another port; compile-time checks that `web.ws.State` and `native_websocket.State`
  carry `contract.SocketState`'s values; constants documented one by one; `sayGoodbye` named. Still documented as
  a limit: a server stalling mid-frame, or not reading, holds its socket's thread until the connection ends.
  **Next:** the contract's socket requests (open, state, send, poll, close, origin URL) with the shared
  `contract.SocketState`; `z.ws` with the browser module's names; `z.net.Session` bound to `z.ws`; the native
  client in `net_core` - a thread per socket owning the connection (handshake, then reads with a short timeout,
  sends from a queue), messages to the app through a locked queue, as the browser's handlers fill theirs; `wss://`
  through `std.crypto.tls` after `ws://`. Also noted: the two servers duplicate their rooms (join, signal, relay,
  cleanup) as they did the protocol.

- **Blind spots found Oct 7** (a review of what had not been verified, rather than of lines):
  1. **Fixed - mixed rooms.** A native peer relays from the start, but ignored a browser's offer, so the browser
     waited for an answer that never came and never relayed: a browser and a native app in one room could not talk.
     Now a relay-only session says `relay` to each peer it adds; a session hearing it relays that peer at once
     (`switchToRelay`, shared with the failure path). The servers forward signals untouched, so `relay` passes.
     Mesh test: a mixed room, messages both ways (11 tests).
  2. **Resolved Oct 7 - the client on `std.Io`'s own tasks.** Reads block in the system until bytes arrive (no
     polling, which this std's AFD sockets could not do on Windows); a writing task, woken by an `Io.Event`, writes
     each pass's frames in one write (resolving 3 for the client - no `TCP_NODELAY` is reachable through std's
     connect, and batching is the portable fix); closing asks for a goodbye, then a closing task cancels the socket's
     tasks after a second - cancellation verified in std's source to reach blocked I/O (Windows:
     `NtCancelSynchronousIoFile`; Linux: `tgkill`). Idle sockets wake never (resolving 4). Found live: this std's
     connect panics on a timeout ("TODO implement netConnectIp... with timeout", POSIX and Windows alike), so none is
     passed. Live: open, a 50-message burst received whole and in order, the other peer hearing LEFT on close, a
     refused connection closed in one 10 ms wait. Was: **Open, first - the Windows client cannot wait for
     readiness.**
  7. **Resolved Oct 7 - `wss://`.** `Connection` (net_core): the stream, its reader and writer, and the TLS client
     (`std.crypto.tls.Client`) for secure addresses (port 443 by default); the system's root certificates loaded
     once (`Bundle.rescan` - on Windows the ROOT store through crypt32, checked in std's source); the two tasks take
     turns with the TLS client (`tls_lock`), the reader waiting for encrypted bytes outside the turn; two-step flush
     (std's TLS flush only encrypts into the stream's buffer - read in its source); close_notify last on goodbye.
     Live: std's TLS API probed against github.com first (148 certificates, handshake verified, a decrypted answer),
     then the client itself over `wss://github.com/` (connected, certificate verified, the server's 502 read, closed
     as not accepted). The burst test's own flaw found on the way: ids are given at accept, not at join. This std drives sockets on Windows through the
     AFD driver, not Winsock: a stream's handle is an AFD handle, `WSAPoll` fails on it, so `waitReadable` always
     says readable and the thread blocks in reads - queued sends would wait until the server speaks. Compiled is not
     working: nothing native has run on Windows. Redesign with std's own concurrency, which cancels blocking calls on
     every platform: the socket's reads and writes as `io.concurrent` tasks, sends through an `Io.Queue`, close by
     cancelling - and for TLS, reads and writes serialized by a lock taken only once bytes are there (the raw
     stream's `fill` waited on outside it). No polling, no 5 ms wake-ups (blind spot 4).
  3. **Open - back-to-back frames still meet Nagle's algorithm.** One write per frame does not help the second of
     two frames written in a row: it waits for the first's acknowledgement. Batch each pass's frames into one write
     (client), and set `TCP_NODELAY` (browsers do; std reaches it through its socket options, AFD on Windows).
  4. **Open - idle wake-ups.** Each socket's thread wakes every 5 ms: 200 a second, kept from deep sleep on laptops
     and phones. Gone with 2.
  5. **Open - runtime coverage.** Never run: anything native on Windows (text editing, input methods, file
     dialogs, the WebSocket client); live tests covered only the happy path (open, one send, one receive, close) -
     not a refused connection, a server's ping or fragments, a burst, or a close mid-connect. The tests' monospace
     font hides proportional text and kerning.
  6. **Process.** The lint's autofix rewrites files between a read and a patch (four patch scripts failed on it);
     the build cache filled the disk once. Read files right before patching; watch the disk before long builds.

### Phase C - Windows, complete

- **C1.** The `isWasm()` audit (65 uses), each classified: a native equivalent to write (naming the step), browser-only
  by nature, or a mistake. **Done Oct 9** - 145 checks of the architecture, in nine files:
  - *Right as they are* (79): what a wasm build must choose by its architecture - the default host, the heap, the
    platform (`host.zig`, `platform.zig`); wasm's linear memory (`memwatch.zig`); `zimrmath`'s scalar colour
    conversions for wasm; the runtime's libc shim, wasm having no libc; and `web.zig`'s 65 guards, which let the
    browser's own module compile into host tests.
  - *Mistakes, fixed:* `runtime.zig`'s title, address and clipboard-writing requests reached the browser directly -
    now through `platform.current`, so they work on Windows and headless; its three clocks and a per-OS monotonic
    clock of its own, with a fake 60-frame tick for tests, are one: `platformMilliseconds`, the contract's `now()`;
    `ui.zig`'s 19 checks - the browser's text agent, and the fields choosing it or native editing - asked about the
    CPU and meant the browser: `host.is_browser`; `draw3d.zig`'s debug log went to the browser's console alone -
    now `std.log`.
  - *Native equivalents still to write:* `sound.zig`'s 12 (C5, audio); gamepad vibration (C8); reading the clipboard
    as text, through `requestPaste` and the paste event (C6), and as an image (browser-only for now); window opacity
    and focus (C3); `takeScreenshot` - natively, the frame read back (`readLastFrame`) and written as PNG (C3); dropped
    files through the contract's file requests (C3); the UI's saved window layout through the contract's saved
    values (C4).
  Found on the way: the frame clock's filter (B6) had broken a runtime test - `getFrameTime` asserted equal to the
  measured duration - unnoticed, since only the filter's tests ran; the test now asserts `raw_delta_time`.
  **Guarded by the linter (Oct 9):** four zimrlint rules keep the audit's answers: `arch-check` (the processor asked
  in src/ - ask `host.zig`'s facts), `own-clock` (a system clock read outside the platform layer - the platform's
  `now()`, or `f.time`), `process-exit` (only an entry point exits) - all on, each exception an explained directive:
  pending sites name their step (C3, C6, C8), `web.zig` and `sound.zig` opt out whole - and `browser-call` (`web.zig`
  imported outside the browser's layer), on like the others: its 27 sites carry directives naming their step (C3,
  C4, C5, C6, C8, C10) or why only a browser can (WebRTC, a clipboard's image, the browser's text agent, `z.web`).
  A rule, once on, stays on: what the tree does not yet follow is marked where it is, not by making the rule
  advisory. `getWindowScaleDPI` now reads the contract's scale. The runtime's raylib-style window, dropped-file, clipboard-read
  and screenshot functions turned out dead - exported nowhere, called only by their own host tests - while the
  engine's API covers each through the contract (`z.requestFullscreen` and `f.window.fullscreen`, the `resized`
  event, `z.userfile`, the paste event): they are deleted, 308 lines with their tests and directives. What the
  directives still mark: C10 (4), C5 (2), C8 (2), C4 (1). Their `web.zig` externs and page functions are unused now,
  to clear with the bridge's next pass.
- **C2.** The drag and menu loops, focus regained, AltGr (L8, L21; `platform_api.md` section 6).
- **C3.** Window state, monitors, cursor shapes, `keyName`, `openUrl` (D5), after GLFW's `win32_window.c` and
  `win32_monitor.c`. **Monitors done Oct 9:** `contract.Monitor` (position and size in the monitor's own
  logical pixels, scale, refresh rate - 0 when unknown - name, primary) and `monitorCount`, `monitor`,
  `currentMonitor` on every platform: Windows enumerates (`EnumDisplayMonitors`, `GetMonitorInfoW` with
  `MONITORINFOEXW`, `GetDpiForMonitor`, `EnumDisplaySettingsW` - `DEVMODEW`'s layout checked at compile time), the
  web reports its screen (`js_screen_width`, `js_screen_height`, and `js_get_dpi_scale`, registered at last),
  headless its screen; `z.monitorCount`, `z.monitor`, `z.currentMonitor`; the `monitors` example. `openUrl` was
  already written. Seen on Simon's Windows machine: three monitors - two at scale 1, a portrait one at 1.5 - named,
  sized, and the current one followed. **Window placement done Oct 9:** `showWindow(WindowShow)` (`SW_RESTORE`,
  `SW_MINIMIZE`, `SW_MAXIMIZE`), `focusWindow` (`SetForegroundWindow`), `setWindowPosition(monitor, x, y)` - a
  position on one monitor, in its logical pixels, since a desktop of mixed scales has no one logical space -
  (`SetWindowPos`), `setWindowSizeLimits` (kept by the window in logical pixels, applied at its scale on
  `WM_GETMINMAXINFO` through `AdjustWindowRectExForDpi`); the web refuses each at compile time with its reason;
  headless records them. The `monitors` example places its window with keys. **`keyName` done Oct 9:** a key's label
  in the current layout - Windows: the key's scancode (`native_input.scancodeOfEngineKey`, the scancode table turned
  the other way at compile time) named by `GetKeyNameTextW`; headless and the web: the US labels
  (`contract.usKeyLabel`, built at compile time from the key enum's names). `input_keys` moves with the keys at W A S D
  too, its prompt naming them in the person's layout. Still to do for the web: the layout itself, where Chromium offers
  it (`navigator.keyboard.getLayoutMap`, a promise). **C3 is done** but for that.
  **Reviewed Oct 9, seven fixes:** the monitors are listed once and kept until `WM_DISPLAYCHANGE`, `WM_DPICHANGED` or
  `WM_SETTINGCHANGE` (listing asks the display driver); each gets its own EDID name and exact refresh rate, a ratio,
  from the display configuration (`QueryDisplayConfig`, `DisplayConfigGetDeviceInfo` - layouts checked at compile
  time), the device name and whole hertz as fallback; `setWindowPosition` places the drawing area, the frame around it
  at the target monitor's scale (`moveClientTo`); size limits apply at once (`applySizeLimits`); a fullscreen window
  neither maximizes nor moves, as with GLFW; the flagship sweep's script is written by the build from its flagship
  list, the launcher switching with Page Down and Page Up, and the build checks at configure time that its list and
  the launcher's roster name the same flagships (`kaleidoscope`, gone from the launcher, had stayed in the list);
  `contract.usKeyName` is the one copy of the US key name both platforms use; `kb_menu` reads "Menu".
- **C4.** Jobs and saved state (D13): `worker_png`, `four_ways`, `ui_full_showcase`.
- **C5.** Audio (D10), in steps, each verified headless by capturing the sound as a WAV file and measuring it (level,
  peak, dominant frequency by FFT), the way frames are verified by capture:
  1. *The contract's four requests, precise, and headless output.* `startAudio(wanted)` grants a format - headless and
     Windows grant exactly 48 000 Hz stereo; `queueAudio(samples)` appends interleaved frames; `queuedAudioFrames()`
     is queued minus played; `stopAudio()`. Headless plays on the run's clock - each frame drawn plays
     `frame_ms x rate` frames, a fractional remainder carried - so the sound is the same every run; the script command
     `.{ .capture_audio_to = "x.wav" }` writes what has played so far, as 32-bit float WAV. Tests: the queue's
     arithmetic; a run capturing silence; one capturing a tone. **Done Oct 9:** the contract states the four requests'
     meaning (a frame queued late plays late, never in place of the silence; `stopAudio` drops the queue); headless
     plays on the run's clock - `playAudioUntil` before each frame's update, `floor(elapsed x rate / 1000)` frames in
     all, so no fraction is lost - keeps what played, and writes it with `capture_audio_to` (a window's script fails
     that line: its sound goes to its device). Its own float WAV header, since `codecs` imports the platform layer.
     Tests: the queue's arithmetic, underrun included; the header; a run capturing no frames - the tone waits for the
     mixer.
  2. *The mixer* (`sound.zig`, a `mixer` section). A pool of voices (64), each named by a handle -
     `enum(u32) { none = maxInt, _ }`, a generation in its high bits so a stale handle names nothing. Each voice reads
     a source - `union(enum) { samples, stream, generator, music }`, every one with `read(destination, frames)`, as
     oto's players read - at a fixed-point position (32.32) advanced by its pitch, linearly interpolated (cubic later);
     its volume ramps across each mixed block from the last to the new (no click), its pan is constant-power, then the
     master volume, then a clamp to -1..1. The engine calls `mixer.mixFrame` after the app's update: it mixes
     `render_ahead - queuedAudioFrames()` frames and queues them. `render_ahead` starts at 50 ms, grows by 25 ms after
     an underrun (the queue found empty), up to 200 ms. **Done Oct 9:** `sound.mixer` - `Voice` handles with generations, `Source`
     (`samples`, `generator`; `stream` and `music` come with the API's port), 32.32 positions, linear interpolation,
     constant-power pan, gains ramped over each block, master volume, clamp; the platform reached through an `Output`
     of the contract's four requests, so only a program starting sound compiles the platform's; the engine's `App`
     holds one, topped up after each update. Tested: a centred tone at 0.707 a side, a stale handle naming nothing,
     samples at double pitch, and a second of 440 Hz through the headless output, frame by frame - 440 rising zero
     crossings, 48 000 frames played, no underrun.
  3. *The API, ported onto the mixer*, raylib's names kept, in the order the five audio examples need it. All five make
     their sounds with `composer.tone` or one embedded WAV, and play them through `sounds`; none uses `music`,
     `streams`, or a compressed format. Each sub-step is checked headless, its sound captured and measured.
     - 3a. *The mixer's additions.* `pauseVoice`, `resumeVoice`, `isVoicePaused`: a paused voice keeps its slot and
       position, and is not mixed. Done Oct 10, before the port: the pan law by source (`PanLaw` - constant power for
       mono, balance for stereo, which plays at unity at the centre), the pitch held to at least 1/64, `start` safe to
       call twice.
     - 3b. *`audio_device`.* `init` starts the engine's mixer (`f.mixer`), with the engine's allocator, on the
       platform's output; `close` stops it; `getMasterVolume` and `setMasterVolume` are the mixer's; `getSampleRate`
       is 48 000; `isReady` is whether the mixer is started; `resumeFromGesture` does nothing - each output resumes
       itself; `getContextId`, a browser handle, goes.
     - 3c. *`sounds`.* A sound holds its samples as 32-bit floats - a wave of 16-bit samples converted once, at
       `loadFromWave` - and one voice: `play` stops the voice it has and starts a new one, as raylib's does (an alias,
       `loadAlias`, shares the samples and has its own voice, so that one sound can overlap itself). `stop`, `pause`,
       `resumeSound`, `isPlaying` act on the voice; `setVolume`, `setPitch`, `setPan` on the voice and on the next.
       `unload` stops the voice and frees the samples, unless they belong to the sound an alias was made from.
       Checked by `audio_basic` (a tone, captured: its frequency) and `audio_sound_lab` (volume, pan and pitch,
       measured in the capture).
     - 3d. *`analyser`.* The mixer keeps the last 4 096 mixed frames, summed to mono, in a ring. `read` takes the
       `fft_size` frames ending at the play position - mixed frames less queued ones, so the spectrum shows what is
       heard, not what is queued - and transforms them as the browser's `AnalyserNode` does: a Blackman window,
       `zimrnum`'s `rfft`, magnitudes in decibels mapped from -100..-30 dB to 0..255, smoothed by 0.8 from one read to
       the next. `audio_spectrum_visualizer` draws the same; checked headless: the peak bin of a 440 Hz tone at 440 Hz.
     - 3e. *The browser's audio graph removed.* The bridge's `js_audio_*` functions and `web.zig`'s imports of them
       go, and with them `sound.zig`'s two lint directives (`arch-check`, `browser-call`). Checked by
       `composer_drum` (each hit of the sequence on its frame, in the capture) and `audio_amp_envelope` (the
       envelope's shape in the capture); then all five examples on Windows and in a page.
     - 3f. *`music` and `streams`.* `music`: a decoder source, decoding as the voice reads - WAV now, Vorbis with
       step 6; until then an OGG file refuses to load, saying why, on every platform alike. `streams`: an app's pushed
       samples, a ring the voice reads (one thread: no atomics); `isProcessed` is room for one more of the stream's
       buffers, as raylib's double buffering asks.
  4. *The web's output.* An AudioWorklet, its module from a Blob URL (as zoto loads it); each frame posts its chunk as
     a transferable `Float32Array`; queued = posted - played, played read from `AudioContext.currentTime` (no message
     back). Before the first gesture the context is suspended: it is resumed on the first pointer or key event, and
     until then chunks are dropped and counted as played, so a sound never plays late. **Done Oct 10:** `bridge.zig`'s `audio_output_program` - the
     processor's source a function turned into the module's text by `toString()`; queued = posted - played, played
     reported by the processor (every 1 024 frames, and on running dry) rather than read from `currentTime`, which
     runs on through an underrun; before the processor can play, blocks held and drained at the real rate. The frame
     gains `f.mixer`; the runner stops the mixer before an example's `deinit`. Example `audio_mixer` (T a tone, Space a
     blip, Up and Down the master volume): headless, its captured sound measured - 1.550 s for 93 frames, the tone at
     440.0 Hz and peak 0.1414, the blip at 660 Hz times its random pitch, no step above 0.04. That first capture found
     a flaw in step 1: an output started in `init` counted from a stale clock and played a second of silence; it now
     starts on the next frame's time. Windows refuses the example until step 5. The page first shipped without its
     program: Zig's C backend writes a byte array of 4 096 bytes or more as character constants, which `c2js` read as
     zeros. `c2js` now reads every constant form exactly - a constant grammar with casts, character constants,
     adjacent string literals joined, function addresses as table indices - and reports anything it does not model
     as an error naming the C line, never a guessed zero (tutorial 2.7). Its 102 differential cases agree with native,
     a new one covering both string forms; the bridge converts with no report. The page's program, extracted from its
     data, passes a Node test against stand-ins for the browser's audio classes. First tries in browsers (Oct 10): in
     an embedding viewer's sandboxed frame, `getGamepads` threw - the frame's permissions policy denies gamepads - and
     ended every page's tick (a regression of C8's per-frame gamepad read); gamepads are now read through one guarded
     function that turns a refusal into none, warning once. In Chrome on a file from the phone's downloads, an opaque
     origin, the worklet could not load from a `blob:null` URL; the module now loads from a Blob URL, else a `data:`
     URL, else the blocks play through a ScriptProcessorNode on the main thread - one copying function shared by both.
     Every path tested in Node on the page's own program. Heard on Simon's phone (Oct 10), through the script
     processor in the viewer's frame - but not every tap: a phone delivers a tap's down and up together, between two
     frames, and `isMouseButtonPressed` compared the button's state at two frame starts, up at both. Key and button
     presses and releases are now transitions recorded by their events and cleared by `endFrame`
     (`pressed_this_frame`, `released_this_frame`), so a tap shorter than a frame is pressed and released in it; every
     app and the UI's letter shortcuts see it. Tested by a unit test and a headless script tapping within one frame.
     Chrome then underran nearly every frame (2 753 underruns, margin at 200 ms) while the viewer's script processor
     played well: on the worklet path, `post` counted a block's frames after transferring its buffer, which detaches
     it - the length read 0, so nothing ever counted as queued, and each frame mixed a full margin onto a queue that
     only grew. Frames are now counted before posting; the Node test's stand-in port transfers as a browser does,
     reproduced the bug on the published page, and passes on the fixed one.
  4b. *Starting a sound inside the queue (Oct 10).* Simon found the delay of a new sound too long: it waited behind
     the margin. The contract's fifth request, `mixIntoQueuedAudio`, adds samples onto the frames queued and not yet
     played, aligned to the queue's end (the part on frames already played dropped, sums held to -1..1); the mixer
     renders a voice started since the last frame into the queue, 10 ms (`late_start_lead_frames`) after the play
     position, and continues it after the queue's end. Headless (a plain array), the browser (`mixIntoQueue`, shared
     by the worklet - by a message, after every block posted before it - the script processor and held blocks), and
     Windows refuses until step 5. The worklet reports every 256 frames rather than 1 024. The margin now also shrinks
     by 5 ms after each second without an underrun, back to 50 ms. Tested: the voice's first sound at exactly frame
     24 481 and a seamless join; the margin's widening and shrinking; the headless addition; every browser path in
     Node; the example headless - each blip 10.02 ms after the frame that saw its tap, where it was about 30 ms.
  4c. *Changes reaching the queue.* A volume, pan or stop given to a playing voice reaches the frames already queued, as
     a start does (4b). Mixing is linear, so a change is the difference between the voice's frames with its new
     settings and with its old, mixed in: for a stop, the old frames with the sign turned. The mixer keeps, for each
     voice, what it mixed into each block still queued - its position, pitch and gains at the block's start - and from
     that renders the voice's queued frames past the lead twice, old and new, and mixes in the difference
     (`mixIntoQueuedAudio`). Exact, except where a sum was held at -1 or 1. A change then takes a frame and 10 ms, as
     a start does; it costs one render of the voice's queued frames.
  4d. *Scheduled starts.* `PlayOptions.start_frame`, on the mixer's clock - frames since the start;
     `mixer.playPositionFrames` is the frames mixed less the frames queued. A voice is placed at that exact frame,
     inside the queue (4b) or after it, if the frame is at least the lead past the play position: sample-accurate
     timing for music and rhythm, as miniaudio's `ma_sound_set_start_time_in_pcm_frames` gives.
  5. *Windows' output.* WASAPI, shared, event-driven, `AUTOCONVERTPCM | SRC_DEFAULT_QUALITY | NOPERSIST`, its COM
     interfaces as vtables in `win32.zig`. A render thread waits on the event and fills `GetBuffer` from the ring,
     zero-filling and counting an underrun when it runs short. A change of default device
     (`IMMNotificationClient.OnDefaultDeviceChanged`) or `AUDCLNT_E_DEVICE_INVALIDATED` makes the thread reopen the
     stream - headphones plugged in move the sound to them. **Written Oct 10:** `win32.zig`'s WASAPI section (GUIDs, a
     packed `WAVEFORMATEX` checked at compile time, the five interfaces' vtables); `platform/windows.zig`'s output -
     a render thread owning COM and WASAPI, streaming from the contract's `AudioRing` (shared by every native output,
     tested on the host with a real second thread), reopening on a lost device or a new default (an
     `IMMNotificationClient` of the engine's own), draining the ring at the real rate with no device. Mixing into the
     queue uses no guard: the mixer's 10 ms lead is a device period. Reviewed the same day against an SPSC queue in
     Zig (rigtorp's design): each side's state on its own cache line, each keeping the other's counter as last seen
     (the queue reviewed kept both copies on one shared line; ours sit with their owners); copies in two runs; a test
     mixing into the ring while another thread reads it, proved to run. The stream: its event made before the client
     holding it, the buffer filled before `Start`, the render thread registered with MMCSS as "Pro Audio", a failed
     stream reopened after 100 ms rather than at once. Compiles; heard on Windows: to do (Simon).
  *Status, Oct 10 - and the order from here.* Reviewed and tested: the stalled turn's changes (a pitch floor of
     1/64; a pan law per source - stereo samples balanced, mono at constant power; fewer than 255 voice slots, checked
     at compile time; a restarted mixer stopped first; the script processor's absence warned of). Background jobs do
     not outlive a turn: each turn runs its checks to the end, in bounded waits. Next, in order:
     a. *Generators declare their channels* (`Generator.channels`, 1 or 2): a stereo generator is balanced, a mono one
        placed at constant power. **Done Oct 10**, the pan-law test extended to generators.
     b. *The API's port* (step 3), one part a turn: `audio_device` onto the mixer's start and stop; `waves` as sample
        sources (PCM converted to f32 at load); `sounds` as voices, a sound's replay stopping its voice first, as
        raylib's does; `streams` - an app's pushed samples as a ring source, a callback as a generator; `music`
        decoded as it plays (WAV now; in the browser, until Vorbis, decoded whole by `decodeAudioData`); `composer`
        unchanged, its waves played through the mixer; the analyser an FFT of the last mixed frames. Then the five
        audio examples run headless (captured and measured), in the browser and on Windows; then the browser's audio
        graph and its bridge functions are removed, with `sound.zig`'s two lint directives. **First part done Oct 10:**
        `audio_device.init` starts the engine's mixer on every platform (the engine hands the device its mixer and
        allocator in `makeFrame`), `close` stops it, the master volume goes to it; in the browser the old context is
        still opened, for the sections not yet ported. The mixer's section now opens `sound.zig`, the others built on
        it. `audio_mixer` starts its sound by `audio_device.init` - its blips still begin 10.02 ms after their frames,
        no leak; the page and an old example build for the browser. **Second part, Oct 10:** the mixer pauses
        and resumes voices (a paused voice keeps its slot and place, unmixed; a resumed one continues after what is
        queued, since its frames queued before the pause still play); `waves.mixerSamplesOf` gives a wave's samples as
        the mixer's floats - mono kept mono, so a pan places it at constant power; a wider wave's first two channels.
        Next: the sound table onto the mixer - an entry's float samples and current voice in place of the browser's
        handles; no example loads an OGG sound, so no browser decoding is needed.
     *Review of the sound system, Oct 10.* Found and fixed: a looping source stepping more than twice its length
        wrapped by one subtraction and read past its end (a test reproduced the panic, `index 15, len 10`, then
        passed with the remainder); a sample source of no channels or no rate is refused (`Voice.none`); pitch held to
        at most 64, so a position's step fits 64 bits; the runner's teardown, and the launcher's reset of a child,
        close the audio device - the ready mark cleared, so a later `init` starts the mixer again, and a child's voices
        stopped before its deinit frees what they read. Cleared: the bridge's per-frame handles are reclaimed by the
        frame's handle scope (`js_mark`, `js_reset`). Still to fix: the browser resumes audio on `pointerdown`, which
        for touch is no user activation (`pointerup`, `touchend` are) - a phone's first tap may not start the sound;
        the headless output keeps every sample played, 384 KB a second without bound. **Both fixed the same day:** the
        browser output resumes on `keydown`, `pointerdown`, `pointerup`, `touchend` and `click` (a Node test: a
        `touchend` alone starts the sound); the headless output keeps the last two minutes played, dropping the oldest
        in batches of ten seconds (tested with small numbers).
     *The sound table on the mixer, Oct 10.* An entry keeps its samples as the mixer reads them (the wave's own rate,
        mono kept mono), the allocator that made them, the device's mixer, and its most recent voice; a sound played
        again plays beside itself, and `stop`, `pause`, `resumeSound`, `isPlaying` and the setters act on the most
        recent voice, as before. Unloading an original stops every voice reading its samples (`mixer.stopVoicesReading`)
        and empties its aliases, which then play nothing rather than freed memory - the old code only warned. OGG gives
        `error.OggNeedsDecoder` until Vorbis. Tests: loading, the lifecycle on a real mixer, the setters, an unload with
        an alias playing. Next: the sound examples run headless, in the browser and on Windows - the analyser still
        reads the browser's graph, which sounds no longer feed, so the spectrum example waits for its FFT.
     *The sound examples on three platforms, Oct 10.* `audio_basic`, `composer_drum`, `audio_sound_lab` and
        `audio_amp_envelope` build for Windows and the browser, and play headless - scripted, their sound captured and
        measured: each sound 10 ms after its frame; the lab's pause and resume continuing its 22 050 Hz sound where it
        paused (the half second in two parts, 210 and 300 ms, each change after the margin's lag); the envelope's
        900 ms, 330 Hz tone rising, decaying and sustaining. Heard on Windows and in a phone's browser: to do (Simon).
        Noticed: `composer_drum`'s title overlaps the line above it (layout, not sound).
     *First listening on a phone, Oct 10: timing irregular in the drum loop, clicks in the envelope.* The drum loop was
        replayed by the example whenever frames x 16 ms passed - wrong at any other frame rate - and the pattern's
        baked wave ended with its last sound (905 ms), not its bar (1 000 ms). Sounds may now loop (`sounds.setLooping`,
        the mixer looping the samples), `composer.Sequence` takes a least length (`length_frames`), and the cursor
        follows the app's time: kicks measured every 500 ms, loop after loop. Stops and pauses cut voices off
        mid-waveform: they now fade out over 5 ms (`fade_out_frames`), a resumed voice fades in, and a voice mixed is
        no longer new. Next: in Claude's viewer the script processor's count of frames played jumps 2 048 frames at a
        time, so a new sound's start varies by up to 43 ms - its count to be smoothed by the audio context's clock.
     *The envelope's glitches, Oct 10.* A headless capture of three overlapping plays is clean - no step beyond the
        tone's own slope, no gap - so what remains is the output on the device running dry; `audio_amp_envelope` now
        shows the margin and the underrun count, to tell. One click was the engine's: a slider moved during the tone
        rebuilds the sound, and unloading cut its voice off. Now each voice reading samples about to be freed copies
        its next 5 ms - at its pitch, so at the mixer's rate - and fades out over the copy
        (`mixer.fadeVoicesReading`); a voice keeps the pan law it started with, so the stereo copy does not change its
        level. Tested: a voice reading its copy while the original is overwritten; the slider dragged mid-tone,
        headless - the largest step the tone's own slope.
     *A diagnostics panel, Oct 10.* In Chrome the page's log strip (bottom, console messages only) showed nothing:
        `audio_device.showDiagnostics` opens a panel at the top of the page, refreshed four times a second - the path
        (worklet, script processor, held and why), the context's rate and latencies, what waits, how often the sink
        itself ran dry and for how long (the worklet and the script processor now count their dry spells - the mixer
        sees only those a report shows it), the mixer's margin, underruns and voices (reported each frame by the
        engine once shown), and the newest warnings. The audio examples show it while their sound is tested; to be
        removed from them, or kept behind a switch, once the glitches are understood. Tested in Node: a dry spell of
        one quantum counted, and the panel's text.
     *The glitches found, Oct 10.* The panel, in Chrome on a phone: the worklet ran dry 5 times (36 ms) in 22 s, the
        mixer counting the same 5 underruns - the page's frames stalling past the 50 ms margin. The old rule widened the
        margin by 25 ms per underrun and narrowed it by 5 ms per quiet second, so a stall that recurred every few
        seconds found the margin back at 50 ms each time. Now the margin follows the gaps between frames, measured by
        the output's own clock (frames played between two top-ups): the longest gap of the last eight seconds and 25 ms
        more, 50..200 ms - a recurring stall raises it before it empties the queue. The script processor's 2 048-frame
        callbacks show as gaps too, so its margin adapts by itself. Tests: a 45 ms gap raising the margin to 70 ms and
        a 60 ms gap then ridden out; a 100 ms gap running dry once, the margin then 100 ms; eight quiet seconds bringing
        it back. Also seen: an output latency of 232 ms - Bluetooth headphones. **Heard working the same day.**
     *Review, Oct 10.* The examples no longer open the diagnostics panel (`audio_device.showDiagnostics` stays, for
        the next search). A fade took the frames of its block, so a short top-up block made it steep - a click again:
        a fade now keeps its frames left across blocks (`fade_frames_left`), its gain falling by one step a frame to
        silence at its 240th frame, tested across three blocks of 100. Compared, from their sources, with raylib
        (stop and pause at once; volume applied whole at the next callback; one pan law, 0.6875 a side at the centre for
        stereo), Mach (16 ms rendered ahead, fixed), SDL3 (gain per device buffer; a paused device silent at once) and
        sokol (2 048-frame buffer): the backends tutorial's comparison gains these rows.
     *Glitches rarer, still heard, Oct 10.* Three causes left in the browser: the main thread's count of frames
        played came from the worklet's messages, and after a stall several wait unread while the next frame runs - the
        mixer then thought the queue fuller than it was, topped it up too little, and it ran dry a second time (and a
        new sound could start on frames already played); the worklet posted a message every 256 frames, garbage on a
        thread that must never wait; the margin forgot a stall after eight seconds. Now each report says the context
        frame it describes and the count runs on by the context's clock (`estimateFramesPlayed`), reports come every
        1 024 frames, and the margin remembers thirty seconds. Tested in Node: a report for frame 1 024, 300 frames
        rendered since, the queue reading 2 772, not 3 072. Next, to make a gap impossible short of a stall longer
        than the margin: changes to a playing voice applied to the frames already queued (subtracting the voice's
        queued frames and adding the changed ones - mixing is addition), so that a margin of 250 ms or more delays
        nothing and only a stall that long - one the screen shows too - can empty the queue.
     *Decision, Oct 10: the mixer renders where the sound is played.* For an instrument - a key to its sound within
        16 ms - mixing on the main thread fails at the root: a key waits for the next frame (up to 16.7 ms at 60 Hz)
        before anything can start, and then the 10 ms lead. JUCE never puts a frame between them: its on-screen keyboard
        records each note with a timestamp (`MidiKeyboardState::noteOn`), the audio callback takes the notes at the start
        of every block (`processNextMidiBuffer`) and renders each at its own sample (`Synthesiser::processNextBlock`),
        on a device opened with the engine's smallest period (WASAPI's `InitializeSharedAudioStream`, about 3 ms).
        raylib also polls input once a frame. Rewinding (PulseAudio; PipeWire dropped it) would only cure the lag of
        changes. So, replacing D10:
        1. *Two sides.* The renderer owns the voices and renders blocks; the main side (`Mixer`) names voices and sends
           commands through a single-producer single-consumer queue, the renderer's notices coming back through
           another. **Done Oct 10:** `SpscQueue`, `Command`, `Notice`, `Renderer`; the main thread still drives the
           renderer (`mixFrame`), so every output behaves as before - the sound tests, and the two-tap script's blips
           at 60.02 and 560.02 ms, unchanged.
        2. *Pull*: the platform's output calls the renderer for the frames its device asks for - headless on its clock
           first, then WASAPI's render thread (with the release of samples handed over by notice, the low-latency
           period), then the browser's worklet running a second instance of the app's wasm (Faust's and Csound's way:
           the module compiled on the main thread, passed in `processorOptions`). The margin, the lead and the start
           inside the queue then go. **Headless done Oct 10:** each platform declares `audio_output_kind` (headless `.pull`; web
           and Windows `.push` until their turns; the template `.pull`); the contract gains `AudioRenderCallback` and
           `startAudioPull`; headless renders at each frame the frames its clock played since the last, in place where
           it keeps them; the mixer, pulled, only reads the renderer's notices each frame. A sound now starts at its
           frame's own time - the two-tap script's blips at 50.02 and 550.02 ms (were 60.02 and 560.02). The push path
           keeps its tests through the headless output pushed to (`headlessPushOutput`). **Reviewed the same day:** the queue's counters were
           `u64` atomics, which a 32-bit target lacks - the browser build failed - now `usize`, counting with wrapping
           arithmetic (tested across a wrap, and across threads with a hundred thousand items); the renderer iterated
           its slots by value, copying each slot's tail buffer every block - now by pointer; the three places where the
           main side runs the renderer itself (`send` when the queue is full, `fadeVoicesReading`, `stop`) now say
           why that is safe, and the first two assert the renderer is not on another thread
           (`Output.renders_on_another_thread`) - the Windows step must replace them. **Replaced, Oct 10**, ahead of Windows: the kind of a
           pulled output says where it renders (`pull_on_main_thread` for headless, `pull_on_audio_thread` for a
           device's thread; the template's); samples are released by handoff (`Mixer.releaseSamples`: kept under a
           token, a `release_samples` command, the renderer's voices copying their tails, a `samples_released`
           notice, and only then the free - at once when the renderer is on this thread; `sounds.unload` uses it); a
           full command queue with the renderer elsewhere waits for room and, failing, drops the command (a `play`
           giving its name back); `stop` applies the commands waiting rather than dropping them, so a release in
           flight is still freed. Tested: samples released with the renderer driven by hand as another thread's,
           kept until its block, freed at its notice. A thread's yield is skipped in a build without threads - the
           browser's, whose libc-free build had failed on it. **Windows pulls, Oct 10:** `audio_output_kind =
           .pull_on_audio_thread`; WASAPI's render thread calls the renderer straight into the device's buffer
           (`fillStreamRoom`), and with no device renders and drops the frames at the real rate (`renderAndDiscard`),
           so that voices keep their time; `startAudio` and `startAudioPull` share one start (`startOutput`). A
           generator now runs where the renderer does - its context belongs to that thread while its voice plays
           (documented; `audio_mixer`'s tone writes its context only before playing). All five audio examples build for
           Windows; heard: to do (Simon). **The low-latency stream, Oct 10:** `IAudioClient3` declared with its own
           identifier, 7ED4EE07-8E67-4CD4-8C1A-2B7A5987AD42 (Windows' audioclient.h, Wine, mingw-w64, PortAudio,
           cubeb; JUCE declares it with `IAudioClient`'s, which works only because Windows 10's object implements both
           in one table), its table's 21 slots checked at compile time. The render thread opens the stream at the
           engine's shortest period for the mixer's format (`GetSharedModeEnginePeriod`, `InitializeSharedAudioStream`,
           no conversion), and the standard stream when the device has no `IAudioClient3` or refuses the format - each
           attempt on a fresh client; it says which opened, with its buffer. Heard: to do (Simon). Next: the browser.
           *The browser.* The worklet runs a second instance of the app's own wasm module - compiled once on the main
           thread, handed over in `processorOptions`, instantiated in the worklet with stand-in imports, as Faust and
           Csound do - and the renderer runs there. The two instances share no memory, so everything crossing between
           them is a message, and a command must mean the same on both sides: (a) a generator's state travels inside its
           play command and lives in the voice; (b) samples are uploaded to the worklet once and named by an id; (c) the
           commands and notices go as messages, the worklet's instance rendering into its own memory at each quantum;
           (d) where no worklet can load (Claude's viewer), the script processor calls the main instance's renderer on
           the main thread. Then the push path - the margin, the start inside the queue, the ring - goes, and the
           sound chapter of the tutorial is rewritten. **(a) done Oct 10:** `Generator` is `generate(state, frames,
           first_frame)` with `initial_state` (at most 64 bytes, aligned to 16) copied into the play command when sent
           and into the voice when started - the voice's own, changed by `generate` alone; tested: two voices from one
           source counting each from its own copy, the caller's untouched, an oversized state refused. **Reviewed and named, Oct 10:**
           the references reach their audio thread by locks - raylib one mutex (21 takings, the mixing callback among
           them), sokol a mutex around its packets, SDL3 a mutex in each stream, Mach a lock on its buffers, JUCE the
           synthesizer's lock, a sound freed where its last reference drops, the audio thread included; zimr by a
           lock-free queue each way, the renderer never waiting, allocating or freeing. Names made plain: the queue
           `SingleProducerSingleConsumerQueue` (its sides `pushing_side`, `popping_side`), the pair `RendererQueues`
           (it had been `Channel`, beside audio channels), `RendererCommand`, `RendererNotice`, `VoiceToStart`,
           `VoiceParameterChange`, `VoiceLoopingChange`, `SamplesToRelease`, `SamplesAwaitingRelease`,
           `VoiceNameRecord` (`is_slot_held`, `is_name_live`), `sendToRenderer`, `readRendererNotices`,
           `applyCommand`, `renderForPullingOutput`, `is_output_pulling`, `is_renderer_on_another_thread`. The backends
           tutorial gains 14.11, the two sides, with the comparison. **(b) done Oct 10:** samples are named by an id (`SamplesId`,
           512 of them): a buffer is registered the first time it plays (`register_samples`, `Mixer.samplesIdOf`), a
           play command carries the id and the format (`SourceToStart` - nothing in a command points into the main
           side's memory), the renderer finds the samples in its own registry (`Renderer.registered_samples`) and a
           voice remembers the id; a release is by id (`release_samples`, `samples_released`), the id replacing the
           release token. Natively the registered buffer is the same memory; the browser will copy it into the worklet.
           Tested: one registration for two plays, the renderer resolving the id, a buffer never played freed at once;
           headless, the drum loop's kicks every 500 ms - the first at 84.6 ms, its frame's time, with no lead. **(c),
           its protocol, Oct 10:** `forwardCommands` empties the main side's queue into a `CommandSink` - each command
           as its bytes (the same module, so the same layout, in both instances), a registration as its samples;
           `RendererHost` is the worklet's side: its own renderer and queues, commands accepted as bytes, samples
           copied into its memory (`allocateUploadedSamples`, `registerUploadedSamples`), blocks rendered, notices
           taken - a release freeing its copy; `acceptNotices` hands them back to the main side, read as any renderer's.
           Tested in one process: a host reached by bytes alone renders the same samples, bit for bit, as a renderer
           reached by its queues, and a release frees the host's copy and then, at the notice, the main side's buffer.
           Next, its other half: the worklet instantiating the module, the exports it calls, the messages, and the
           script processor's fallback calling the main instance's renderer.
           *No hand-written JavaScript.* The worklet's program is to be Zig compiled by c2js, as `src/jobs_worker.zig`
           is - its comment records why: the hand-written JavaScript there had caused the jobs system's two worst
           bugs - and `audio_output_program` (about 480 lines of JavaScript in a Zig string, written during this sound
           work) is to go the same way. **c2js in an audio worklet's scope, Oct 10:** that scope has only the language
           itself - no `atob` (the prelude's data section), no `TextDecoder` or `TextEncoder` (the kernel's `__dec`,
           `__enc`) - and a worklet module is strict. The prelude now carries `__base64Bytes`, `__utf8Decode` (the
           Encoding Standard's UTF-8 decoder, TextDecoder's own algorithm) and `__utf8EncodeInto`, used only where the
           built-ins are missing. Before: all 102 cases failed in those conditions (`atob is not a function`); after:
           every case runs there with its native result, c2js's output proving strict-clean. The differential suite now
           runs each case three ways - native, JavaScript, and as a worklet loads it (`run_as_worklet.js`) - and tests
           the fallbacks against the built-ins (`prelude_fallbacks_test.js`: base64 at every length to 300 and 64 KB;
           3 000 valid strings and 20 000 invalid sequences decoded exactly as TextDecoder; encodeInto at every room,
           lone surrogates included). A deliberately broken alphabet failed two cases' worklet runs and the fallback
           test. **The processor class, Oct 10:** one generic primitive in c2js's kernel, `js_subclass(base, init)` - a
           class extending `base` whose constructor calls base's with its arguments (so that an AudioWorkletProcessor
           gets its port) and then `init(this, ...arguments)`; methods go on its prototype by `js_set`, and
           `registerProcessor` is an ordinary call. The suite gains a JS-only stage (`js_cases/`): cases reaching
           JavaScript through the kernel, each against a fixture (`<name>.fixture.js`) and checking itself, run as a
           page and as a worklet (`run_js_case.js`). The interop case - skipped until now, its fixture never written,
           so the kernel had no running test - moved there with its fixture, and passes; `subclass` makes a processor
           as the worklet will, against a stand-in base class and `registerProcessor`: the base constructor ran (its
           port), `init` got `this` and the options, `process` set from Zig wrote its output and asked to be kept, the
           instance is an AudioWorkletProcessor. A deliberate break (`init` without the arguments) failed it in both
           runs. **Made plain the same day:** the prelude's fallbacks and `js_subclass` with descriptive names and
           named intermediate values in the emitted JavaScript (`sixBitValueOfCharacterCode`,
           `continuationBytesNeeded`, `utf16UnitsRead`, `initializeAfterBase` ...; `__dec`, `__enc` become
           `__utf8Decoder`, `__utf8Encoder`), and the explanations - base64 worked on "TWFu", UTF-8's layout on three
           characters, surrogate pairs, the broken sequences and the decoder's rule, what a class and `super` are - as
           Zig comments between the emitted lines, which reach no program; the fallbacks end at a marker line the test
           finds them by. The test file and the subclass case rewritten the same way. The backends tutorial gains 2.8,
           a program in an audio worklet. Next: the mixer's renderer host and forwarding, given the same reading; then
           the worklet's program in Zig (`src/audio_worklet.zig`). **Read and rewritten, Oct 10:** the renderer host's
           block - what a module and an instance are, why their memories are apart, why a command's bytes travel and an
           address does not, `context` as Zig's stand-in for a closure, why forwarding keeps order, why the notice
           queue always has room; named intermediate values throughout (`samples_in_main_memory`, `command_bytes`,
           `uploaded_copy`, `rendered_block`, `taken_notice_count`); and `render` now asserts a request fits its block.
           The two sides' introduction (what a thread is, why sound has its own, a play followed both ways) and the
           queue's comment rewritten as a course: the ring with a worked example, the mask, release and acquire in
           plain terms, cache lines, the 32-bit wrap with numbers; `push` and `pop` name each step. The tutorial's
           14.11 gains the same course. **The renderer, read the same way:** its comment opens with the words of sound
           (sample, channel, frame, block, voice, volume, pan, pitch, gain, mixing); `applyCommand` says what each change
           does to the sound; a voice's name explained (slot and generation); the stop's 5 ms fade, the release's copy
           of a voice's tail, pause and resume stated for pulled outputs first, the push path noted as the exception;
           `mixVoiceInto`'s gain ramp worked on an example, every step named; `gainsPartWayDown` worked on a fade split
           across two blocks, and now safe to call when no fall is under way (it returned a division by zero then -
           never used, as only a fading voice used it, but `mixVoiceInto` now computes both gains before choosing).
           **The main side, read the same way:** its fields grouped (bookkeeping, renderer, output, push path only);
           a voice's life through its name record drawn out; `yieldThisThread` explained; `stop`'s comment corrected
           (it applies the commands waiting, no longer drops them); `play` split into named steps - `isPlayable`,
           `firstFreeSlotIndex` (now found before anything is registered, so a full mixer registers nothing),
           `voiceToStartOf` - and the setters, pause and resume given their ranges and what is heard; a buffer
           released twice - which would be freed twice, at once and at the notice - now caught by an assertion
           (`isBeingReleased`); `mixFrame` says the pulled case first. **For the worklet step:** with the renderer in
           the worklet, a full command queue must be forwarded (`forwardCommands`), not applied to the local renderer
           as `sendToRenderer` does for a renderer on this thread - the local one is then unused. **Reading a source, read
           the same way:** `readSampleSource`'s comment is a short course - resampling (44 100 read at 48 000), the
           32.32 fixed-point position with its worked numbers and why not a float, linear interpolation worked on an
           example with what it costs in quality, the end of a buffer, channels; the code names each stage.
           `readVoiceSource` says what a generator is handed. **The pan law, the same way:** loudness as the sum of
           the squared gains, decibels from zero, why a mono sound gets constant power and a stereo one a balance, and
           a table of both laws at five pans beside the plain crossfade (-3 dB at the centre); `gainsForPan` names its
           angle and gains. **The command and notice types:** each command and field says what it does or holds; why
           a generator's function pointer means the same function in the worklet's instance (a wasm function's address
           is its index in the module's table, the same in every instance); `SamplesToRegister` named as the one
           command holding an address; the notice queue's claim - never full, 64 + 512 of 1 024 - now a compile-time
           check (made to fire once with the queue at 512, then restored); a compile error message damaged by an old
           rename ("a voice's voice_name") repaired. Next: the worklet's program in Zig.
           **The worklet, in steps (Oct 11).** The worklet runs the app's own module, not a separate one as the jobs
           worker does: a generator is a function pointer, an index in the app module's table, found only in that
           module. (1) **Done:** the renderer host's entry points in the app's module - `sound.mixer.worklet_abi`, one
           spelling of each name for both sides; eight functions over one `WorkletState` (start, the command buffer,
           accept a command, room for samples, register them, render, take notices, the notices buffer), exported only
           in a browser build (`wgpu_app.zig`, `host.kind == .web`); tested natively against a local renderer, bit for
           bit, and through a release; all eight present in the built module. (2) The worklet's program in Zig, by
           c2js: `js_subclass` processor, the module from the constructor's options instantiated with stand-in
           imports, `process` rendering, the port's messages in and notices out; a Node test against a small module
           built from the entry points. (3) The main thread's side in `bridge.zig`, in Zig: the context, the module
           loaded, commands forwarded each frame, notices back; without a worklet, the script processor runs the
           renderer on the main thread - both pull. (4) The browser output switched to pulling, then the push path
           removed. (5) The tutorial.
           **Step 2, ground laid (Oct 11):** the browser build's module, linked in Node with a stand-in for each import
           - 82 imports, all functions; nothing runs while linking (no start function); a fresh instance's memory is
           21.6 MB, the app's static data, which a second instance costs - started, rendered a silent quantum, called
           no import. `render` now returns the block one channel after the other (two `set` calls per quantum in the
           worklet, not hundreds); `worklet_abi` gains the processor's name, the module option and the messages
           (commands and samples in, notices out, each by its kind). Handles in the worklet's callbacks are freed one
           by one (`defer js_free`): `js_mark`/`js_reset` cannot be used inside a callback, since `__href` takes
           free-list slots below the mark, which a reset never reaches - a message per frame would pin about 120 slots
           a second. Next: the program itself, `src/audio_worklet.zig`, and its Node test. **The program, written:**
           `src/audio_worklet.zig` - registers the processor (`js_subclass`), links the app's module from the
           constructor's options with a stand-in for each import (names set by `Reflect.set`, kept as JavaScript
           strings), starts the host, listens on the port; `process` renders and copies each channel with one `set`;
           commands and samples taken from messages; notices sent back, transferred. Compiled with the `zm` module
           given (`--dep zm -Mroot=... -Mzm=src/zimrmath.zig`): `Voice.none` is `zm.maxInt`. Ordered bottom-up for the
           lint (vocabulary, state, helpers, linking, messages, callbacks, `start`). Tested in Node against the real
           browser build's module (`tools/c2js_cases/audio_worklet_test.cjs`, by hand for now): registered, linked,
           silent quanta, messages taken, and live handles unchanged over 2 000 quanta and 200 messages - a handle
           leaked on purpose each quantum made them 2 015, and failed it. Next: a test module that plays a sound
           through it, and the program built and embedded by the build.
        3. *Input to sound*: key and pointer events forwarded to the renderer as they arrive, an instrument running on
           the renderer's side, timestamps placing each note at its sample; a playable keyboard example.
        4. *Natively*, the main loop wakes on input rather than sleeping until the next frame.
     c. *The Node test into the repository*: the browser output's program tested against stand-ins, on every path,
        with transfers as browsers make them - today a file in /tmp.
     d. *Decoders* (step 6): Vorbis, then QOA.
     e. *Later*: sample-accurate scheduling - a sound started, or a parameter changed, at a given frame rather than
        at the next block; stops and volume changes of playing voices without the margin's lag, by re-rendering the
        queued frames; ALSA, CoreAudio and AAudio outputs, each on `AudioRing`.
  6. *Decoders.* WAV (written); Vorbis, a port of `stb_vorbis`; QOA (raylib's, small); MP3 later.
  7. *The analyser:* in 3d.
  8. *The tutorial's audio chapter.* Written as the steps land (chapter 14); each step adds its section.
  9. *Quality, when measured to matter.* The resampler: linear interpolation dulls the highest frequencies and, at
     pitches above 1, folds some back as aliasing; a low-pass before it (as miniaudio's), or cubic interpolation, when
     a capture shows it. The clamp: many loud voices summed past 1 are cut flat, a harsh distortion; a limiter on the
     master - a gain that follows the peak down quickly and recovers slowly - in its place.
  **C5 from here (Oct 12, made precise).** The order of the work that remains, each step with its files, how it is
  verified, and when it is done.

  **The goal: the sound examples' lag, cut to what the hardware allows - on Windows first, then in the browser.** Every
  sound example plays through the mixer (`sounds.play` and `Mixer.play` alike), on the outputs written: Windows pulls
  (`pull_on_audio_thread`, WASAPI), the browser pushes (`push`, a worklet fed blocks from the main thread), headless
  pulls on the main thread. A sound's lag is a sum of terms, each set by one piece of the code; the target for a key's
  note is 16 ms at most, about 10 where the device permits.

  **The latency model.** The symbols: `F` the frame period (16.7 ms at 60 Hz); `P` the device's period (WASAPI calls
  the render thread once a period); `B` the device buffer (`GetBufferSize`); `M` the push path's margin; `L` the
  push path's lead for a new voice (`late_start_lead_frames`, 480 frames, 10 ms); `D` what lies past the engine's
  reach - the driver, the converter, the speaker's own latency (WASAPI reports part of it, `GetStreamLatency`; a page
  reports it as `baseLatency + outputLatency`). Each term, from the code:

      term                       Windows (pulled)                          browser (pushed)
      t1 key or click reaches    0 .. F: the loop blocks in the present    0 .. F: the app reads input at its
         the app's update        (FIFO, 2 frames in flight), then reads    animation frame; `keydown` itself runs at
                                 the window's messages (native_loop.zig    once, but nothing acts on it before then
                                 `serviceWindow`)
      t2 the command waits for   0 .. P: commands apply at the start of    0 .. 2.7 ms: the block is posted, and the
         the renderer            the renderer's next call                  worklet takes messages between quanta
      t3 queued ahead of the     B - P: the render thread fills all the    L, less the play position's staleness:
         new sound's first frame room each event (`streamUntilChange`),    the main side's count of what played is
                                 so at an event `padding` is B - P         reported every 256 frames, so 4.7 .. 10 ms
      t4 past the engine         D                                         D
      a change - stop, release,  t1 + t2 + t3 + t4, the same as a start    t1 + M + D: M is 50 ms at least, up to 200,
      volume, pan, pitch                                                   since the change waits behind the margin

  Today, at 60 Hz, before `D`:

      Windows, standard stream (P = 10 ms, B = 20 ms asked)   start 10 .. 37 ms, 23 on average
      Windows, low-latency stream (P = 2.7 ms, B unknown)     start 0 .. 16.7 + 2.7 + (B - P); B is Simon's to read
      browser                                                 start 5 .. 30 ms; a change 50 .. 217 ms

  So the terms in order of size: the browser's margin `M` for every change (the worst, 50 ms at least - a key's
  release rings on that long); the frame wait `t1` on both (8.3 ms on average, 16.7 at worst); the Windows buffer
  residue `B - P` (10 ms on the standard stream); the browser's lead `L`. `D` is the floor.

  **What each step removes.**

      step                                        removes                         for
      4 the latency readout                       nothing: it measures each term  every sound example
      5 the Windows device buffer                 most of B - P                   every sound, on Windows
      6 the note thread on Windows                t1                              keys' notes, on Windows
      7 the browser's worklet pulls               M (to 2.7 ms), L                every sound, in the browser
        and keys' handlers send notes             t1                              keys' notes, in the browser

  A click on a UI button keeps `t1`: the UI is laid out and hit-tested at the frame (`pressed_on_click` already fires
  at the press's frame, not the release's). So does a sound an app plays from its update. Only a note sent from where
  the input arrives escapes the frame (decision below).

  **Decided: the app's update stays at the display's rate** (Oct 11): notes leave the frame path instead.
  **Decided: a note starts at the next block by default**; the timestamp's placement is the instrument's option.
  **Decided (Oct 12, Simon): the input path, both halves, in this order.** Inputs are polled, so a key waits for
  the next frame (`t1`, 8.3 ms on average at 60 Hz) - with the worklet path in place, one of the largest terms left.
  (1) *Bindings, resolved without app code:* the app tells the engine once what a key plays - a note, or a sound -
  and the engine resolves the key wherever it arrives: on Windows on the input thread, in the browser in the key's
  handler, posting to the worklet; no app code runs off the main thread, so nothing in it can race. The app still
  sees the key at its next frame, polled, to draw it. JUCE's on-screen keyboard works so: a key-to-note table and a
  key state, apart from the app's logic. (2) *A callback for app code, on the main thread:* `on_input` beside
  `update`, called as each key or pointer event arrives, between frames - the app's state and the mixer are its to
  use (one thread, no locks); it must not draw; the event is still recorded for the next frame's polling. The
  browser calls it from the event's handler; Windows needs the loop to wait on input and the frame's readiness
  together rather than block in the present. sokol's event callback and SDL's event watchers are the same shape.

  *(Made precise on Oct 14 - each remaining step's design, sub-steps, tests and size: section 9.)*
  **The order from here (Oct 12, evening - revised after the wiring and Simon's glitches), every remaining step,
  superseding the "Next" lines in the journal below:**

      done   the push path deleted; page audio in Zig and wired (`page_audio.zig`, the JavaScript program deleted, a
             frame's commands in one message); a steady worklet block allocates nothing; the second audio context
             made only for music, streams and the analyser; the worklet's timing on the panel
      1. glitches, by Simon's screenshot     the cause the `worklet:` line shows, fixed; the worklet's module linked
                                              asynchronously and warmed up (blind spot 6)
      2. the hot paths' rest                  the voice slot's tail copy out of the slot; the resampling position in a
                                              local; flush-to-zero on the Windows render thread
      3. the Shepard instrument               `mixer.shepard_instrument`, with an attack ramp (blind spot 8)
      4. the scale star (`audio_scale_star`)  the example on Simon's drawing, played with Shepard tones
      5. streams on the mixer, in one memory  a stream voice reading a ring the game fills; Windows, headless and the
                                              script processor
      6. streams across to the worklet        a stream's frames posted to the renderer in the worklet
      7. music on the mixer                   a Vorbis decoder in Zig (none ships today), its frames fed to a voice as
                                              it plays; then the older browser-graph layer deleted
      8. the worklet path measured (7d)       the readout's rows in Chrome; `t1` from the key's own time
      9. bindings                             the input path's first half - takes in steps 6 and 7e
     10. `on_input`                           the input path's second half
     11. the Windows device buffer (step 5)   when Simon's Windows numbers arrive - with blind spots 1 and 2
     12. the remaining blind spots and debts  5 (a note placed by its time, jitter shown); c2js's `js_free` and its
                                              dropped `(&x)->field = value`, with a c2js case for each;
                                              `verify_imports` folded into `bridge_import_check`; the page frame loop's
                                              handle scope
     13. the sound tutorial (step 9)           `sound_tutorial.html`, extracted from the backends tutorial's chapter 14
                                              and rewritten for the design as it is (Simon, Oct 12, night: done before
                                              the scale star, then kept in sync with every step)

  **The next five turns, precisely (Oct 12, evening).** Each ends green - the targeted tests named, lint clean, the
  pages and the Windows build where named - and with a snapshot; the full `gate` runs at the end of turn 2, which
  touches the mixer's core. What Simon checks is said for each.

  *Turn 1 - the glitches, by what the panel shows; the worklet's start off the audio path.* It begins with Simon's
  screenshot of the `worklet:` line, taken within a second of a glitch, and reads it by this rule:
    - a longest block over 2.5 ms: our block outlasted its deadline - first calls compiling, or work that spikes. The
      fix is part (b) below, and the block's work is profiled in Node to name what spikes (a block's calls timed one by
      one: render, the two copies, the notices);
    - short blocks and a longest gap longer than the whole buffer - the base and output latency on the `audio:` line,
      28 ms on Simon's phone - the worklet's thread was not run in time: a gap that long is an underrun, whatever the
      device's period (a gap of about a period is ordinary: the browser asks for blocks in bursts). **Corrected (Oct 12,
      night): the wrong buffer.** The output latency lies after the device's callback and drains at a steady rate; the
      worklet's slack is the browser's queue between its thread and that callback - in Chrome a FIFO kept near the
      callback's size (`baseLatency`, 4 ms on Simon's phone), deepened after each underrun - so a gap of a few periods
      can already be one. The worklet's numbers cannot decide it; the `dropouts:` line, from the output's own clock,
      does (journal, "Turn 2's renderer half"). The fix is a
      larger browser buffer: page audio makes its context with `latencyHint` a number of seconds rather than `"interactive"`, starting
      at 0.03, shown on the panel's `audio:` line, so that Simon weighs glitches against the latency read beside them;
    - neither: the glitch is not in the worklet - the main thread's notes arriving late, or the device - and the turn
      adds the main thread's longest frame to the panel to look there.
  (b), whatever the screenshot: the worklet's module linked asynchronously and warmed up. `audio_worklet.zig`:
  `initializeProcessor` asks `WebAssembly.instantiate(module, imports)` - a promise, resolved in a callback - rather
  than `new WebAssembly.Instance`; `processBlock` plays silence until it resolves; the resolving callback starts the
  renderer (`worklet_abi.start`), then renders 64 silent blocks and a block with a voice of each kind the renderer
  knows by itself - a generator, a buffer of samples - each at zero volume, so that the functions a block calls are
  compiled before the first sound needs them, and only then posts `ready`. The instrument's functions are the app's,
  and arrive later, with `set_instrument`: they are warmed when that command is applied, by a silent note started and
  ended in a scratch slot - still before the first key, which comes after the app's `init` has set the instrument.
  `sound.zig`: `RendererHost.warmUp()` and its export (`worklet_abi.warm_up`), and the instrument's warming in
  `applyCommand`, each leaving the renderer as it found it (no voice, no notice). Tests: the
  worklet test - `ready` posted only after the instantiation's promise resolves, silence before, the sine and the
  ramp bit for bit as before; `test-sound` - `warmUp` leaves no voice playing and no notice queued; the page test
  unchanged and green. Built: both pages. Simon checks: the glitches - rarer, or gone - and the panel's lines.

  *Turn 2 - the hot paths' rest.* `sound.zig`: `VoiceSlot.tail_samples` moves to `Renderer.tail_copies:
  [voice_capacity][fade_out_frames * channel_count]f32`, indexed by slot - the same memory, out of the slot - so that a
  slot is the state a block reads (a comptime check: `@sizeOf(VoiceSlot) <= 256`; it is 2 080 today);
  `readSampleSource` reads the position into a local and writes it back after its loop. `platform/windows.zig`: the
  render thread sets flush-to-zero and denormals-are-zero (MXCSR bits 15 and 6) when it starts, through inline
  assembly on x86-64, a comptime branch leaving other targets as they are. Tests: every existing test unchanged and
  green - the fade over a released buffer's copy, the stolen note, the resampling ones - and a new one: two voices fading
  over their copies at once, in neighbouring slots, each heard as its own - the copies out of the slots, a slot must
  still find its own by its index. Built: both pages and
  both examples for Windows; then the full `gate`. Simon checks nothing new by ear; Windows when he can.

  *Turn 3 - the Shepard instrument.* `sound.zig`, beside `sine_instrument`: `shepard_instrument`, as its plan above
  says - the key's pitch class (`key mod 12`), partials at every octave from 12.5 Hz to 12.8 kHz under a bell
  centred at 400 Hz, one octave wide; one phase in f64 turns, each partial's `frac(phase x 2^k)`; a release as the
  sine's; and an attack - a ramp of 2 ms at a note's start, the first instrument to have one (blind spot 8). Tests:
  each of the twelve pitch classes' centroid in log-frequency within a cent of the bell's centre, and their loudness
  within 0.1 dB of one another; a note's first block rising from silence with no step over 0.01; its state inside
  the 64 bytes (comptime); a chord's three notes sounding at once. Nothing built for a page yet.

  *Turn 4 - the scale star*, in three turns since Simon asked for smaller ones (Oct 12, night): **4a** the example
  drawing - the circle in thirds, the star, the chords and their lines, from the geometry alone, with its web build
  entry; **4b** what it plays - the digits, the taps on numbers and on chords' names, the lighting, the Shepard
  instrument set at `init`, and its Windows and headless entries; **4c** the headless script and its checks. As a
  whole: `examples/audio_scale_star/audio_scale_star.zig`, as its plan above says: the circle in
  thirds, the star of the scale's steps, the chords outside with their lines; the digits 1 to 7 and taps on the
  numbers play notes while held, taps on a chord's name its triad while held; what sounds is lit; the Shepard
  instrument set at `init`. Its build entries (web, Windows, headless). Tests: a headless script pressing 1 to 7 and
  then each chord, its capture and its frames checked (a chord's three notes in the capture's spectrum, the lit
  names in the frame). Built: the page and the Windows program. Simon checks: it plays on his phone and on Windows,
  the notes at one height.

  *Turn 5 - streams on the mixer, in one memory.* `sound.zig`: a stream voice - a source reading a ring of frames
  (single producer, single consumer, the queue form the mixer already uses) that `streams.update` fills on the main
  thread and the renderer drains; a ring that runs dry plays silence and counts it; `isProcessed` true while the ring
  has room for another `update`, as raylib's; play, pause, stop, volume, pitch and pan as any voice's. The `streams`
  namespace keeps its API and moves off the older layer onto the mixer where the renderer shares the game's memory -
  Windows, headless, the script processor; the renderer worklet keeps the older layer until turn 6. Tests: a
  streamed sine through headless, a second of it bit for bit; a ring run dry heard as silence, counted; pause and
  resume; the `audio_stream_synth` example's headless run, its capture checked. Built: the Windows program of a
  streaming example. Simon checks: a streaming example plays on Windows, where it was silent.

  *The scale star, in detail (Simon, Oct 12, from his drawing; turns 3 and 4; redrawn Oct 13).* An example,
  `examples/audio_scale_star`, that shows the notes and the chords of the major scale and plays them.
  *What it draws (Simon's second drawing, Oct 13, superseding the first's star and chords-by-their-root).* The seven
  notes of C major on a circle, in thirds, clockwise from the top: 1 C do, 3 E mi, 5 G sol, 7 B si, 2 D re, 4 F fa, 6 A
  la - each note shown with its degree, its letter and its solfege name. Two neighbours on the circle are a third
  apart, so each chord of the scale is three neighbours: its root, its third, its fifth. Each chord is drawn beside
  its THIRD - the middle of its three - the major chords outside the circle (I by E, IV by A, V by B) and the minor ones
  inside (ii by F, iii by G, vi by C), with the diminished vii (by D) inside among the minors. Lines lead from each
  chord to its three notes, one style a role: the root a solid line ending in an arrowhead, the third a zigzag, the
  fifth a dashed line. A minor chord's box has a double border, and a note whose own chord is minor or diminished (2,
  3, 6, 7) a double ring; the major side (1, 4, 5 and I, IV, V) single. Upper case for a major triad, lower case for a
  minor one; vii's diminished fifth shown as such (vii with a degree sign). No star in this version.
  *What it plays.* The digits 1 to 7 play the scale's notes while held, as do a tap or a click on a note's number; a tap
  or a click on a chord's name plays its triad - its three notes together - while held. A note sounding lights its
  number; a chord lights its name, its three notes and its three lines.
  *Shepard tones: a new instrument, `mixer.shepard_instrument`.* Each note is its pitch class sounding in every octave
  at once: sines at `f, 2f, 4f, ...` over the audible range, each weighted by a bell - a Gaussian in log-frequency,
  centred on a fixed frequency (about 400 Hz), one octave or more wide. The same bell for every note: so every note has
  the same average frequency - its spectrum's centroid, in log-frequency, at the bell's centre - and the same loudness,
  and the notes differ only in pitch class, not in height; a scale played round the circle neither rises nor falls.
  Why the centroid is the same for each note to a fraction of a cent: the bell, sampled at a note's octaves, has a mean
  that moves with the sampling's offset only by about `4 pi sigma^2 exp(-2 pi^2 sigma^2)` octaves (Poisson summation)
  - 3e-8 octaves for a width `sigma` of one octave. That holds for octaves on both sides of the centre without end; cut
  short, the bell's tails would be cut unevenly, by up to a cent or two. So a note's partials reach five octaves either
  side of the bell's centre, where its weight has fallen below four millionths: ten or eleven partials, from about
  12.5 Hz to 12.8 kHz for a centre of 400 Hz - the lowest inaudible, and weighted too little to matter. The key's octave is ignored by design: the instrument reads its pitch class
  (`key mod 12`). Its state stays inside a voice's 64 bytes (`generator_state_capacity`): one phase, the lowest
  partial's, in f64 turns, from which each partial's is `frac(phase x 2^k)` - wrapping the lowest phase by whole turns
  changes no partial's, since `2^k` is whole - and the level, as the sine instrument keeps it. Ten or eleven partials a
  note, three notes a chord: about thirty sines a frame, inside the budget (`sound_performance_review.md`). Its notes
  start with a short attack ramp, so that a chord's partials begin without a click - the review's blind spot 8, met
  here first.
  *Verified:* for each of the twelve pitch classes, the rendered note's centroid in log-frequency within a cent of the
  bell's centre, and its loudness (RMS) within 0.1 dB of the others'; a chord press starts three voices and its
  release ends them; a headless script presses 1 to 7 and each chord in turn, its capture and its frames checked.
  *Done when* Simon plays it in Chrome on his phone and on Windows, and hears the notes at one height.

  *9, bindings, in detail.* A binding table the app sets from the main thread - a key to a note (key number,
  velocity) or to a sound (a `Sound` already registered with the renderer, so that the input side never registers
  samples) - swapped in whole, so that an input thread reads one consistent table. Resolved: on Windows by step 6's
  input thread (raw input; notes only while the window has the focus; a bitset of the keys it pressed, so that
  repeats are ignored; every one released when the focus leaves - blind spot 7), sending through
  `sendNoteFromInputThread` and, for a sound, a fourth queue of its own - a trigger naming registered samples, which
  the renderer starts in a free main-side slot it then reports, as a note's slot needs no name; in the browser by the
  key's handler, posting `{ kind: "note" }` to the worklet's port, or applying it on the main thread on the pulled
  path; elsewhere at the frame. `audio_keyboard` binds its keys; its on-screen keys stay polled. *Verified:* headless,
  a scripted key with a binding starts its note at its own frame; the page test, a `keydown` posting its note
  without calling into the app; the readout's `t1` near 0 for bound keys. *Done when* Simon's readout shows it on
  Windows and in Chrome.
  *10, `on_input`, in detail.* `AppSpec.on_input: ?fn (*Frame, *State, InputEvent) void`; the frame it is handed
  allows the mixer and the app's state, not drawing. Browser: called from the bridge's event handlers. Windows: the
  native loop waits with `MsgWaitForMultipleObjectsEx` on its window's messages and on the swapchain's readiness
  together, so that a message arriving mid-wait is handled at once. Headless: at each scripted event, so that it is
  tested by script. An example of its own: `audio_mixer`'s sounds started from `on_input`, the readout showing
  `t1` against the polled ones. *Done when* both platforms call it between frames, measured.

  1. **A sound through the worklet, in Node.** A test module, `src/tests/audio_worklet_module.zig`, built for
     wasm32-freestanding: the worklet's entry points (`exportWorkletEntryPoints`), and test exports that write the
     bytes of commands made by a real `Mixer` - a play of a sine generator, a play of registered samples - so that no
     test spells out a command's layout. The Node test (`tools/c2js_cases/audio_worklet_test.cjs`) sends them as the
     main thread will, and reads the output. *Verified:* the sine's first quanta equal the generator's samples times
     the centre gain, 0.707, exactly in float32; a ramp of samples at 24 000 Hz equals what a local renderer makes of
     it (a test export renders the same ramp locally); a buffer that ends posts one notice naming its slot; live
     handles unchanged over 2 000 quanta. *Done when* a build step runs it (`zbuild audio-worklet-test`), and the full
     gate includes it. **Done Oct 11:** the module is `src/audio_worklet_test_module.zig`, beside the program it tests
     rather than in `src/tests/`, since a module cannot import `../sound.zig` from outside its root's directory. Its
     first instance starts a real `Mixer` on a stand-in pulled output and records what `forwardCommands` hands over,
     giving the same to a local `RendererHost`, the reference; the worklet's program instantiates it again. The main
     side takes the worklet's notices as a message's bytes through `mixer.acceptNoticeBytes`, which the bridge will
     use too (3e). Measured: 4 quanta of a 1 kHz sine equal the generator's frames times 0.70710677, bit for bit, and
     the local renderer's; a 24 000 Hz ramp over it equals the local renderer for 17 quanta, then one 4-byte notice
     ends the ramp's voice and not the sine's (the ramp still plays before it is read); live handles 10 before and
     after 2 000 quanta. Made red by the worklet ignoring `samples` messages. In `gate`.
  2. **The program built and embedded.** `build.zig`: the program compiled as the jobs worker's is
     (`buildWorkerJs`), with the `zm` module given (`--dep zm -Mroot=src/audio_worklet.zig -Mzm=src/zimrmath.zig`);
     each page carries its text as `window.ZIMR_AUDIO_WORKLET_JS`, as it carries the jobs worker's (c2js's
     `--worker-js-embed` gains its audio twin). *Verified:* every audio example's page builds, and the program in it
     is byte for byte the build's output (a Node check of the page). *Done when* step 1's test runs the program taken
     from a built page. **Done Oct 11:** `buildAudioWorkletJs` (with `sound.zig` declared an
     input, so a change to the names rebuilds it) and c2js's `--audio-worklet-js-embed`, on every page, served or
     self-contained; the program taken from the built `audio_mixer` page is byte for byte a fresh build, and passes
     the Node test. The same day: the five audio examples built for Windows as `zimr_windows_audio_test.zip`, for
     step 6.
  3. **The keyboard instrument, verified headless.** `sound.zig`: an instrument that runs on the renderer's side,
     with voices of its own, driven by note events - a key down starts a note, a key up releases it - through a
     note queue of their own, single producer, single consumer, separate from the mixer's commands: the producer is
     the input's path, which may be a thread other than the main one, and the mixer's command queue has exactly one
     producer, the main side. Each event carries its time; the renderer starts the note at the next block, or at the
     timestamp plus the fixed delay. An example, `audio_keyboard`: a row of keys on screen, the computer keyboard's
     two rows playing them. *Verified:* headless, by the script's clock - a key pressed at a known time, the
     captured sound's first nonzero frame found in the WAV; the measured delay is the software's share, at most one
     block from the event's time with the event path, and up to a frame more through the frame path, both measured
     and both recorded. *Done when* the example plays from scripted keys, headless, with the delay measured.
     **The instrument, landed (Oct 11):** `mixer.Instrument` (generate, start_note, release_note, has_fallen_silent),
     `NoteEvent` with MIDI key numbers, `NoteQueue` (256, a third queue in `RendererQueues`), the last 16 of the 64
     slots kept for notes (`first_instrument_slot`; `Mixer.play` looks below it, and a note's slot ends with no
     notice), `Mixer.setInstrument` and `Mixer.sendNote`, and `sine_instrument` (struck at the velocity, held, a
     50 ms half-life release, silent below -80 dB). A full instrument steals the longest-sounding note. Tested: key
     69 sounds from the first block's frame 1, 439 rising crossings in a second (440 less the one at frame 0), peak
     0.7071; released, every note slot is free a second later and the last block is zero; the main side plays 48
     voices and refuses the 49th. All 256 tests of `sound.zig`'s root pass. Next: the browser's worklet takes notes
     too (`RendererHost`), the `audio_keyboard` example, and the headless measurement.
     **`audio_keyboard`, landed (Oct 11):** seventeen keys from middle C, the computer keyboard's middle row the white
     keys and the row above the black (A S D F G H J K L ; and W E T Y U O P), the pointer playing them too, sliding
     from key to key; the notes go through `Mixer.sendNote`, read at the frame for now. The push path applied notes
     only in its render, after the new voices had started inside the queue - a note would have waited out the whole
     margin - so `mixFrame` now applies notes beside the commands. Headless (`zig build audio-keyboard-headless
     -Dscript=...`, Mesa's software Vulkan: `apt-get install mesa-vulkan-drivers` on a fresh sandbox): H held from
     frame 30 to 60, then 60 frames more. The captured WAV: the note's frame 0 at output frame 24 000 - 500 ms, the
     frame its key went down, no frame later; 440 Hz; peak 0.3536 (velocity 0.5 x 0.7071); silent at 1 616.6 ms,
     614 ms after the release, as 12.3 half-lives of 50 ms predict. The headless output pulls at each frame on the
     run's clock, so this shows the mixer adds no delay of its own; the frame path's wait and the device's latency
     are what steps 4 and 5 measure.
     **Notes through the worklet (Oct 11):** `worklet_abi.accept_note` (key, 1 or 0, velocity - plain numbers), the
     message `{ kind: "note", key, isDown, velocity }` - the one a key's handler will post in step 5 - handled by the
     worklet's program (`acceptNote`; `callExport` gained three arguments), `RendererHost.acceptNote`, and the
     `CommandSink`'s third function, `send_note`: `forwardCommands` hands on the notes sent on the main side after the
     frame's commands. The Node test sets the instrument and plays key 69 for 8 quanta, releases it for 8 more, each
     equal to the local renderer bit for bit; made red at the note's first sample by the worklet ignoring `note`.
     **From the review (Oct 11):** (1) Two producers on one note queue would race - the input thread of step 4 and
     the main thread both sending notes - so `RendererQueues` has two note queues, `notes` (`Mixer.sendNote`, the
     main thread) and `input_thread_notes` (`Mixer.sendNoteFromInputThread`), drained one after the other each block.
     Tested with a real thread sending sixteen events while the main thread sends its own: all ten notes sounding,
     the two held ones the right keys. In step 4, `audio_keyboard` must not also send the keys the input thread
     sends. (2) The sine note's phase was `frequency x frame / rate` in `f32`: measured 0.005 from the exact sine
     after 20 s held (noise 46 dB below the note). It is kept in the note's state now, in `f64`, wrapped below one
     turn each frame: within a millionth after 20 s. (3) A stolen note fades: before its slot is reused, its next
     5 ms are generated at its last gains, ramped to zero, and kept as a tail the next blocks add in
     (`keepFadeOfStolenNote`, `addStolenNoteTail`); tested with a loud low note stolen near its peak - the largest
     step between frames under 0.01, where the cut (the control) failed it. (4) `sound.zig` is a fast test root:
     `zig build test-sound`, 264 tests, and in `test-fast` - a planted failure made it red. (5) `audio_keyboard` cross-compiled for
     Windows (`-Dplatform=windows -Dmode=release`): 2.9 MB; it imports ntdll, KERNEL32, USER32, SHELL32, comdlg32,
     IMM32, AVRT (the audio thread's Pro Audio class) and ole32 (WASAPI's COM), Vulkan loaded at run time; its PE
     subsystem is the console (3), Zig's default for a `main` - so a console window opens beside the app, which no
     decision records. (6) Chapter 14 gains 14.14, from a key to its sound - the four stages and their floors,
     the frame path's wait drawn against an input thread's, why notes leave the frame path rather than the update
     running at 120 Hz, the next block against the timestamp's placement, and where raylib, SDL3, sokol, JUCE and zimr
     read keys and start their sound - and 14.15, the instrument - its four functions, MIDI key numbers, the two note
     queues, the reserved slots, the exponential release worked to 614 ms, the phase kept below one turn and why, the
     stolen note's kept fade - with folds of `Instrument`, `applyNotes`, `generateSineNote` and
     `keepFadeOfStolenNote`. The review's list is done; next, step 4. Known until step 5: on the web's push output, a key's release waits out the
     margin (50 ms or more).
  4. **The latency readout - every term measured, on every platform.** `sound.zig`, `windows.zig`, `bridge.zig`: the
     engine stamps each start - a play's command or a note - with the time its request reached the engine
     (`t_request`: the key's event time for a note, the call's time for a play) and the time the renderer applied it
     (`t_applied`, the block's start), and the output says when that block's first frame reaches the speaker
     (`t_out`): on Windows the event's performance-counter time plus `padding` frames, with `IAudioClock::GetPosition`
     to check it, plus `GetStreamLatency`; in the browser the context's `getOutputTimestamp()` and `outputLatency`.
     `audio_device.showDiagnostics` - already in every sound example - shows, for the last ten starts, `t1` (key to
     request: the frame wait, from the key event's own time), `t2` (request to applied), `t3 + t4` (applied to out),
     their sum, and the stream: low-latency or standard, `P`, `B`, the padding at the last event. Headless shows the
     same from its clock. *Verified:* headless, a scripted key at a known time gives the expected terms (`t1` 0 for
     a key on the frame's start, `t2` and `t3` 0 by its clock); Windows cross-compiled; Simon reads the numbers on
     Windows and in Chrome for `audio_keyboard` and `audio_mixer`. *Done when* those numbers are in this plan, term
     by term - they decide step 5. This replaces the old step 6, Simon's Windows audio test.
     **The measurement, landed (Oct 12):** `t1` needs the key's own time, which the contract's events do not carry:
     the browser has it (`event.timeStamp`); on Windows `GetMessageTime` has the system tick's resolution, 10 - 16 ms,
     so a precise `t1` there comes with step 6's thread, stamped from the performance counter. The rest is in:
     `contract.AudioRenderTiming` (when the output asked for a block, when its first frame reaches the output) passed
     to every pulled render; the request `audioClockMilliseconds` (Windows the performance counter, the browser
     `performance.now()`, headless the run's clock, the template a compile error); `Output.clock_ms`; a play's and a
     note's request time (`VoiceToStart.requested_at_ms`, `NoteEvent.requested_at_ms`); the renderer's `recordStart`
     into a lossy `LatencyQueue` of 64; the main side keeping the last ten (`Mixer.recentStarts`). Windows passes the
     event's time plus `padding / rate`; headless, its start plus the frames played - its blocks are rendered after
     the fact, so its `t3` is negative by up to a frame and `t2 + t3` is the true zero of its clock. Tested with a
     stand-in output at known times: a play applied at 105 and out at 115, a note at 205 and 207.5, both requested at
     100, read back exactly, newest first. The push path is measured too: the frame's starts are applied in
     `mixFrame` and heard where they begin inside the queue, `min(queued, late_start_lead_frames)` frames past the
     play position the output last reported (tested: 50 ms queued, a start at 100 ms heard at 110). The display:
     `Mixer.formatLatencyLine` ("note   wait for the renderer 1.4 ms   queued ahead 2.6 ms   total 4.0 ms"), drawn
     for the last five starts by `audio_keyboard` (under the keys) and `audio_mixer` (under its status). Headless, two
     scripted notes read wait 16.7, queued -16.7, total 0.0 - its clock's true zero, as the model says. Built for the
     web and Windows (`zimr_windows_latency_readout.zip`) for Simon's numbers; still to add to the readout: the stream
     and its `P` and `B` (the console's "windows audio:" line has them meanwhile), the browser's `baseLatency` and
     `outputLatency` (its diagnostics panel has them), and `t1` from the browser's `event.timeStamp`.
     **The pages failed to load on Simon's phone (Oct 12):** `Import "dom" "js_now_ms": function import requires a
     callable`. `audioClockMilliseconds` called `web.dom.now_ms`, whose extern said `"dom"` while the bridge registers
     `js_now_ms` in `wgpu` (`wgpu.nowMs` is the engine's clock); never called before, the mismatch slept. Fixed at the
     declaration (`extern "wgpu"` in `web.zig`), and in the check that should have caught it: `bridge_import_check`
     compared names only, so a name registered in any module passed; it now resolves each registration's module and
     compares module and name, as a browser binds. Red on the broken page, explaining itself; no false rejection over
     sixteen cached modules. To do: `verify_imports`, the smoke's own import check, has the same blind spot - fold
     it into `bridge_import_check`.
     **Simon's first numbers, phone, Claude's viewer (Oct 12):** wait 0.4 - 0.9 ms, queued 10.x ms - and the page
     warned that the audio worklet loaded neither from a Blob URL nor from a `data:` URL (an opaque origin: "a
     dependency or cross-origin script failed to load"), so the sound played through the script processor, whose
     2 048-frame buffer (42.7 ms) the readout did not count. So the readout gained `t4`: the contract requests
     `audioOutputLatencyMilliseconds` (the browser: the script processor's buffer when it plays, plus
     `baseLatency + outputLatency`; Windows: `GetStreamLatency`, past the buffer already in `padding`; headless 0)
     and `audioOutputName` (which path plays), and the line became a table that fits a phone - `wait queued past
     total (ms)` under an `output:` line. In this viewer the worklet cannot load at all, so step 7's numbers need a
     served page (http or https), not a file the viewer opens.
     **The readout with `t4`, Simon's phone (Oct 12):** in Claude's viewer, `output: a script processor` - wait 0.6 -
     0.9, queued 10.0, past 70.7 (42.7 the script processor's buffer, 28.0 the context's base and output latency),
     total about 81.5 ms. In Chrome, opened from `content://`, the worklet loads: wait 0.7, queued 10.0, past 28.0,
     total 38.7 ms. So on this phone the browser's own 28 ms is the floor; ours is the 10.7 ms of wait and queue, and
     a change - a release - still waits behind the margin, 50 ms and more. Chrome loads the worklet from a page opened
     as a file; only Claude's viewer cannot.
  5. **The Windows device buffer.** `windows.zig`. From step 4's numbers: with the standard stream, `B - P` is 10 ms
     of the lag; the render thread can fill only up to a target - one period and a small safety, rather than the
     whole buffer - so that a new sound waits behind about one period, not two; and the standard stream can ask for
     a smaller buffer. With the low-latency stream, the same policy at its own period. The risk is an underrun when
     the render thread is late; Windows schedules it as Pro Audio (MMCSS), and the readout counts underruns. *Verified:*
     cross-compiled; Simon's readout before and after, with the underrun count. *Done when* `t3` is about one period
     on his machine with no underruns over a minute of playing.
  6. **A note thread on Windows.** `native_input.zig` and `windows.zig`: raw keyboard input (`RegisterRawInputDevices`
     with `RIDEV_INPUTSINK`) on a thread of its own, behind a message-only window, timestamped with the performance
     counter; each key event goes into the input thread's note queue at once (`Mixer.sendNoteFromInputThread`) and is
     also delivered to the frame as now. `audio_keyboard` then sends the pointer's notes only, the keyboard's coming
     from the thread - two producers sending one key would sound it twice. *Verified:* cross-compiled; the readout's
     `t1` for notes about 0 on Simon's machine. *Done when* it is.
  7. **The browser: the worklet pulls, and keys' handlers send notes.** Done first of the remaining steps (Oct 12):
     Simon can measure it on his phone today, while step 5 waits for his Windows numbers. The design:
     a. *The path is decided at boot.* A worklet's module loads asynchronously (`addModule`), and the mixer must know
        at its start which path it takes. So the page makes its audio context and loads `zimr-renderer`'s module
        (`window.ZIMR_AUDIO_WORKLET_JS`, from a Blob URL, then a `data:` URL) while the app's module instantiates,
        before `init` runs; the context stays suspended until the first gesture, as now.
     b. *Forwarding, a third kind of output.* `Mixer.Output` gains `start_forwarding`: it returns the granted format
        when the page's worklet loaded, null when it did not - and then the mixer starts the push output as today
        (Claude's viewer, where no worklet loads). Forwarding, `mixFrame` forwards every command, registration and note
        (`forwardCommands`) through the output's sink, takes the notices that came back (`acceptNoticeBytes`), and
        reads them; `sendToRenderer` finding the queue full forwards rather than applying locally; samples are freed
        only on the renderer's notice, as on an audio thread. The local renderer is unused.
     c. *The page's side.* The node, `new AudioWorkletNode(context, "zimr-renderer", { numberOfInputs: 0,
        outputChannelCount: [2], processorOptions: { module } })`, `module` the app's compiled module kept from its
        instantiation; commands posted as one `commands` message a frame, samples as `samples` messages before them;
        `notices` messages kept until the frame takes them.
     d. *Measured.* The worklet's renderer knows its block's frame on the context's clock (`currentFrame`); the page
        maps context time to `performance.now()` by `getOutputTimestamp()`, so a start's `applied` and `out` land on
        the main side's clock and the readout covers this path too.
     e. *Notes from the handlers.* A `keydown` or `pointerdown` the app maps to a note posts `{ kind: "note", key,
        isDown, velocity }` to the port from the event's own handler - `t1` gone for notes.
     **7b, the mixer's side, landed (Oct 12):** `Mixer.Output.forwarding` (`ForwardingOutput`: start - null when the
     platform cannot forward after all, the push output then started - and the sink's four functions), taken by
     `outputOf` when the platform declares `startAudioForwarding`; `Mixer.forwarding` while it forwards. `mixFrame`
     forwards (`forwardToOtherMemory`: `forwardCommands` through the sink, then every notice that came back,
     `acceptNoticeBytes`, then `readRendererNotices`); a full queue is forwarded at once; `stop` ends forwarding -
     every voice name freed, samples awaiting a notice freed now, unforwarded commands and notes dropped. Tested with
     a stand-in whose sink feeds a `RendererHost`: a ramp played there and not here, released, freed only after the
     notice, its voice ended after its 5 ms fade. Next: 7a and 7c, the page's side (`web.zig`, `bridge.zig`).
     **7a and 7c, the page's side, landed (Oct 12):** boot gains stage 5 between instantiation and the app's start:
     the compiled module is kept (`Boot.app_module`) and the output program's `prepareRenderer` makes the audio
     context and loads `ZIMR_AUDIO_WORKLET_JS` with `start()` appended (Blob URL, then `data:` URL), resolving true or
     false - false at once for an app that imports no sound. The web platform declares the forwarding functions
     (`startAudioForwarding` - null when the worklet did not load -, `forwardAudioCommandBytes`, `forwardAudioSamples`,
     `forwardAudioNote`, `takeAudioNoticeBytes`), over five new `dom` imports answered by the bridge
     (`js_audio_forward_*`, `js_audio_take_notice_bytes`); a note crosses as plain values, since the platform layer
     cannot name the mixer's types. The output program gained `startForwarding` (the node, `processorOptions.module`,
     notices kept as they arrive), the four posts, `takeNoticeBytes`, a shared `listenForGesture`; `stop` keeps the
     renderer's context, suspended, for the next start. This part of the output program is JavaScript, as the rest of
     it still is; its port to Zig stays part of step 7. Checked in Node against stand-ins (a scratch harness, not yet
     in the repo): loaded at boot, the node started with the real `audio_keyboard` module, a real play of a ramp
     sounding at 0.331 (0.468 x 0.707), its notice back. Not yet measured on this path - the renderer in the worklet
     stamps no timing - so the readout shows only its `output:` line until 7d.
     **Silent in Chrome (Simon, Oct 12):** `output: zimr's renderer, in the audio worklet`, notes counted, no sound -
     the page started the path, and the worklet said nothing: a processor that throws dies silently unless the node's
     `processorerror` is heard. The suspects the code allows: Chrome refusing the compiled module in
     `processorOptions` on the audio thread, or the linking failing there. Diagnostics added rather than guessed: the
     worklet program posts `{ kind: "ready" }` once linked and started, `{ kind: "failed" }` when its renderer cannot
     start (`postStatus`, `worklet_abi.message.ready_kind`, `failed_kind`); the page tracks the state, logs a
     `processorerror`, and the `output:` line says which holds - starting, running, FAILED (see the log), or suspended
     until a tap. The Node harness checks the flow (suspended, then running after the processor's `ready`).
     **Still silent, "a glitch at first" (Simon, Oct 12):** no browser can run in the sandbox (Playwright's download
     host is blocked), so the page now reports the renderer's whole state in one screenshot: the worklet program posts
     `{ kind: "stats", blocks, peak }` every 375 blocks - blocks rendered, and the loudest sample since its last report
     (`RendererHost.takePeak`, `worklet_abi.take_peak`) - and the diagnostics panel, now shown by `audio_keyboard`,
     prints `renderer: <state> | <n> blocks, loudest <peak> | posted <c> commands, <n> notes, <s> samples` under the
     context's line. No blocks: the processor does not run; blocks at peak 0: the commands or notes do not arrive or
     do not sound; a peak with no sound: the output does not reach the speaker.
     **The references reviewed (Oct 12, `sound_reference_review.md`):** JUCE, miniaudio (in zaudio), sfizz, zoto,
     groovebasin, against this design. Eight blind spots, now part of the steps: (1) the low-latency WASAPI stream
     opens only at the engine's own format - ours is fixed at 48 kHz stereo float, so a 44.1 kHz device falls back to
     the standard stream silently: open it at `GetMixFormat`'s rate and channels (step 5); (2) the standard stream
     asks 20 ms where JUCE asks one period, 10 (step 5); (3) stealing takes a held note while released ones ring -
     JUCE's order, or sfizz's quietest-of-the-older (the instrument, next); (4) the same key again stacks voices -
     release the ringing one first, as JUCE does (the instrument, next); (5) every event starts at the block's start:
     jitter up to a period, 10 ms on the standard stream - place a note by its time, splitting the block, and show
     jitter in the readout; (6) the worklet links the 3.9 MB module synchronously on the audio thread - instantiate
     asynchronously inside the worklet, as Emscripten does (step 7); (7) step 6's raw input sees keys while unfocused,
     repeats them, and bypasses the release on focus loss - focus-only, a pressed-key bitset, release all on focus
     loss (step 6); (8) nothing guarantees an attack - a one or two millisecond ramp at a note's start.
     **Chrome on Android, the renderer's panel (Simon, Oct 12):** `renderer: running | no report yet | posted 1
     commands, 50 notes`, context running, no error: the processor finished its constructor (`ready`), the
     instrument and every tap reached its port, and yet it never reached its 375th block, and no `processorerror`.
     Read line by line again - `start`, the import object, the constructor, `processBlock`, the views, `sendNotices`,
     the handlers, the page's side, the older layer's own context - nothing found that fails in Chrome and passes in
     Node. Found on the way, not the cause: the c2js runtime's `js_free` recycles a slot only when its value is not
     `undefined`, so every handle of `undefined` leaks a slot (the Node test, lacking a worklet's `currentFrame`,
     leaked one per report; its scope now has it) - to fix in c2js, with a sentinel for a freed slot. The next build
     tells the remaining cases apart: the processor reports at its first block and every 25 after, with the worklet's
     `currentFrame`; the render call is made through `js_try_call`, so a throw is posted with its text whatever Chrome
     does with `processorerror`; the panel shows how long ago the last report came. `no block yet` - `process` never
     called; one block and then silence - the first call never returns; blocks counting with `loudest 0` - it runs and
     no note sounds.
     **Found (Oct 12): `process` returned the number 1.** Simon's panel: `1 blocks (frame 0, 29.0 s ago), loudest
     0.350` - the first block ran, with his first note in it, and Chrome never called `process` again; no error.
     `processBlock` returned a `u32`, which c2js gives back as the number 1; the specification converts `process`'s
     result with `ToBoolean`, but Chrome keeps a processor with no inputs alive only while it returns exactly `true`
     (`IsTrue()`), and the old push path's hand-written processor returned `true`. The one block was the "glitch at
     first". Fixed: `processBlock` returns `bool` - c2js emits `return true;` - and the worklet test, which had locked
     the assumption in (`keepCalling === 1`), now demands exactly `true`; with the number restored it goes red. The
     page's embedded program checked: only `return true;`. The reports go back to the first block and every second.
     **Made harder to repeat (Oct 12):** a compile-time check refuses a `processBlock` returning anything but `bool`;
     `prepareRenderer` now checks what a worklet needs - the module exports `zimr_audio_worklet_start` - not an import;
     and `zig build audio-page-test` (in `gate`, `tools/c2js_cases/audio_page_test.cjs`) runs the page's output program
     from bridge.zig, the worklet's program and the test module as the app against a Chrome-strict stand-in browser:
     a held note through the instrument must sound for 400 blocks, the processor report at block 375 with its
     `currentFrame`, the context suspend rather than close on `stop`. Red when `process` stops after one block.
     **The instrument's blind spots 3 and 4, landed (Oct 12):** the same key struck again releases its held note
     first - it rings on in its release, and a key holds one note at a time; stealing follows JUCE's
     `findVoiceToSteal` (`noteSlotToSteal`): the longest-sounding note of the same key, else the longest-sounding
     released note, else the longest-sounding held note other than the lowest and the highest held, else the highest,
     the lowest last. Tested: a key struck twice - two sounding, one held; fifteen held notes and a released one - the
     released one taken; sixteen held - key 41 taken, keys 40 and 55 kept. Made red by "the oldest, regardless": both
     stealing tests fail. The fade test's notes moved so that its loud note is the oldest unprotected one. Next: 7d,
     the worklet path measured; 7e, notes from the key handlers; blind spot 5, a note placed by its time.
     **Where the page's code stands (Oct 12):** the renderer worklet plays in Chrome (Simon: 15 000 blocks, still
     running). Hand-written JavaScript remains in the page: `audio_output_program` in bridge.zig, 632 lines - it was
     360 when this step was written; the renderer path (`prepareRenderer`, `startForwarding`, the four posts,
     `takeNoticeBytes`, the status and the diagnostics' renderer line) went in as JavaScript to reach a working phone
     first - and a 20-line `reporter`. The worklet's program is Zig through c2js. **The order from here, so as to port
     less:** first delete what the worklet path made unneeded - the push path, its `zimr-output` processor, its
     blocks, its play-position estimate, its margin and inside-the-queue starts; the fallback where no worklet loads
     (Claude's viewer) becomes a *pulled* output: the script processor's `onaudioprocess` calling the main thread's
     own renderer, as headless pulls on the main thread - no queue, no margin. Then port what remains to Zig over the
     bridge's `Value` API: the context, the module's loading as two boot stages (Blob URL, then `data:` URL), the
     node and its port handler (`func`), the posts, the notices, the script processor's callback, the diagnostics
     panel. Step 8 (the push path removed) moves before the port. The Node tests (`audio_worklet_test.cjs`,
     `audio_page_test.cjs`) stay JavaScript: they stand in for a browser, which only JavaScript can.
     **Stage 1 of that order, landed (Oct 12): the fallback pulls.** The web platform's output kind is
     `pull_on_main_thread`, as headless's: where the renderer worklet loaded the mixer forwards to it; where it did
     not, `startAudioPull` keeps the mixer's render callback and the page's `startPulled` makes a script processor
     whose `onaudioprocess` calls the app module's new export `zimr_audio_pull_block` (`pullAudioBlock` in
     platform/web.zig): the mixer's own renderer renders the block then and there, laid out channel after channel for
     `getChannelData`, and the callback copies each channel out of the app's memory - no queue, no margin, no
     inside-the-queue start. It plays on the context made at boot when there is one. The export exists only in page
     builds (checked: not in the worklet test module, not in the renderer program). The page test covers it with
     stand-in exports: one pull per buffer of 2 048 frames, each channel copied, 70.7 ms past the output (the buffer
     and the context's latency). **Found while answering Simon (Oct 12): `music` and `streams` do not use the
     mixer.** They play through the older browser graph (`web.audio`: `loadAudioBuffer`, `decodeOggBytes`,
     `playBufferAt`, a second audio context made by `audio_device.init`), and off the web `web.audio` does nothing -
     so on Windows today a game's music and its streamed sound are silent; only `sounds` (the mixer) plays everywhere.
     Not touched by the push path's removal - they never used it - but it moves "streams and music on the mixer" up:
     right after the port, before 7d, so that a Windows game has music. A stream becomes a voice reading a ring the
     game fills at its frame; music a voice fed by a decoder as it plays.
     Next, stage 2: the push path deleted - from the contract (`startAudio`,
     `queueAudio`, `queuedAudioFrames`, `mixIntoQueuedAudio`), the mixer (the margin, the gaps, the inside-the-queue
     starts, `Output`'s push fields), every platform (Windows' ring, headless's pushed capture, the page's
     `zimr-output` processor and blocks), and the tests that exercise it.
     **Step 1 of the order, its first half, landed (Oct 12): the mixer no longer pushes.** `Output` keeps
     `start_pulling` (now required), the clock, the latency, the name, `stop`, and `forwarding`; its `start`, `queue`,
     `queued_frames` and `mix_into_queued` are gone, and `outputOf` no longer names the platform's push requests.
     `Mixer.start` forwards or pulls; `mixFrame` forwards, or reads the renderer's notices - nothing else. Deleted: the
     margin and its gap buckets (`render_ahead_*`, `gap_bucket_*`, `noteGapBetweenFrames`), the inside-the-queue
     starts (`late_start_lead_frames`, `startNewVoicesInsideQueue`, `Renderer.mixNewVoicesInto`), the underrun count,
     the per-frame mix block; `render_ahead_most_frames` became `render_block_most_frames`, the largest block the
     renderer renders at once. `is_new` stays - a voice not yet heard stops with no fade - its doc reworded. The page's
     mixer report narrowed to the voice count (`js_audio_output_note_mixer`); `audio_mixer` lost its margin line. Four
     push tests deleted (the inside-the-queue start, the margin following stalls, running dry once, a pushed start's
     measurement); the stand-in outputs rewritten - the forwarding one's `startPulling` asserts it is never called.
     `test-sound` 261 of 266, the worklet, page and contract tests green, the pages and Windows built. Second half,
     next: the contract's push requests and `AudioRing` with its four tests, Windows' ring and its section's account,
     headless's pushed capture, the web platform's push functions.
     **Step 1 of the order, done (Oct 12): no output pushes.** The contract: `AudioOutputKind` is `pull_on_main_thread`
     or `pull_on_audio_thread` - `push` gone; the requests `startAudio`, `queueAudio`, `queuedAudioFrames` and
     `mixIntoQueuedAudio` gone, `startAudioPull` a required request with its account; `AudioRing` and its four tests
     deleted. Windows: the ring, its constants and its section's account gone - the section now tells the pulled
     design; `startAudioPull` is the one start; with no device the thread renders to nowhere at the real rate.
     Headless: the queue, the underrun count and the push functions gone; `playAudioUntil` renders what came due; its
     test of a queue running dry became one of the pulled capture (480 frames at 10 ms in one block asked at 10 and out
     at 0, 960 more at 30 ms out at 10, nothing asked after `stopAudio`); the test of mixing into the queue deleted.
     Web: the four push functions and their `dom` declarations gone - the bridge still registers the imports, unused,
     until the port. Template: the four stubs gone. Green: `test-sound`, the contract's, worklet and page tests; both
     examples built for Windows and the web. Next: stage 3, the output program ported to Zig.
     **Stage 3, the port, made precise (Oct 12).** Two findings shape it. (1) The bridge's Zig cannot be tested
     where it lives: bridge.zig is one file by charter, built only for the page, and the smoke runner
     (`webtests/runner.mjs`) never runs it - it stands in for the app module's imports directly. Today the page test
     covers the output program only because that program is JavaScript text the test can pull out of bridge.zig;
     ported into the monolith, it would lose its only test. (2) The page's frame loop (`ZimrBoot.tick`, stage 4)
     opens no handle scope, unlike the kernel's own loop: handles minted during a page's frames are never reclaimed -
     a few a frame, for the page's life. Adding a scope is not a one-line fix - bridge tables keep handles created
     during frames (GPU objects), which a reset would orphan - so it is recorded here, for its own step.
     *The structure:* page audio becomes `src/page_audio.zig`, a second exception to the one-file charter of the kind
     the charter already makes for `dom_input.zig` ("that table can [be unit-tested], so it lives apart"). It is
     written as the worklet's program is - against c2js's handle functions (`js_get`, `js_call*`, `js_new*`,
     `js_func`, `js_mark`/`js_reset`), not the bridge's `Value` - so that it transpiles on its own. The bridge imports
     it (declared to `addBridgeSource` as an input, as `dom_input.zig` is) and its `dom` import answers call it; and a
     build step transpiles it alone for `audio_page_test.cjs`, which then drives the real Zig against the same
     Chrome-strict stand-ins instead of the JavaScript text. *Its pieces:* the state (context, node, path, the
     renderer's state and report, the counts posted, the held notices as one JavaScript array - an object holding
     objects, so that handle scopes reclaim only slots); the renderer's loading at boot with callbacks rather than a
     returned promise (a Blob URL's `addModule`, then on failure a `data:` URL's), the bridge's boot stage 5 polling
     `isRendererSettled` each tick; `startForwarding`, the four posts, `takeNoticeBytes`; `startPulled` and its
     `onaudioprocess`; the gesture listener; `stop`; the latency and the path; the diagnostics panel - its lines
     formatted in Zig and set as the panel's text every 250 ms, the console's warnings no longer intercepted (the
     panel shows page audio's own). Every browser callback opens its own handle scope. *Done when* the page test
     passes against the transpiled `page_audio.zig`, `audio_output_program` is deleted, and Simon's phone plays.
     **Part 1 written (Oct 12): the loading at boot.** `src/page_audio.zig` - not yet wired, so no page changes: its
     head (the two paths, the boot's wait, the handle rules), c2js's handle functions declared as the worklet's
     program declares them, helpers over them, the state (`OutputPath`, `RendererLoading`, `ProcessorState`,
     `PageAudio`), and the loading - `prepareRenderer` (the module's export checked, the context made, the source given
     its `start()` call, a Blob URL's `addModule` with callbacks), the four settling callbacks (a `data:` URL tried on
     the Blob's failure; the browser's reason warned once), `isRendererSettled`. Read bottom-up, vocabulary first,
     the entry point last; compiled as c2js consumes it; lint clean. Next, part 2: `startForwarding`, the posts,
     `takeNoticeBytes`, the port's and the node's handlers; then part 3: `startPulled`, the gesture listener, `stop`,
     the latency and the path, the panel; then the wiring (the bridge's boot and `dom` answers), the page test against
     the transpiled file, and `audio_output_program` deleted.
     **Part 2 written (Oct 12): the forwarding path.** `setAppExports`; `startForwarding` (the node with its options -
     no input, the channels out, `processorOptions.module` - its port's handler and `onprocessorerror` set, connected,
     the held notices a fresh array, the counts reset, the gesture listened for); `forwardCommandBytes`,
     `forwardSamples` (each copied out of the app's memory - `appMemoryView`, the buffer read afresh at each use - and
     the copy's buffer transferred), `forwardNote`; `takeNoticeBytes` (whole notices, a message's remainder kept first
     in line); `onRendererMessage` (notices, the report, ready, failed), `onProcessorError`; the gesture listener
     (`onGesture` resumes a context not running; the five activation events, in the capture phase); `stop` (the
     handler cleared, the node disconnected; the renderer's context suspended, the script processor's closed). The
     handle rules kept: calls whose result is unused go through the void variants (a call returning `undefined` would
     leave a handle `js_free` never frees), part 1's three included; every function the app calls during a frame
     frees each handle it makes, since the page's frame loop reclaims none; the browser's callbacks open their own
     scope. Compiled as c2js consumes it; lint clean. Next, part 3: `startPulled` and its `onaudioprocess`, the
     latency and the path, the panel.
     **Part 3 written (Oct 12): the pulled path, the readout's numbers, the panel.** `startPulled` (the boot's context
     when there is one, else a new one; a script processor of 2 048 frames, its `onAudioProcess` asking the app's
     `zimr_audio_pull_block` for each buffer and copying each channel out of the app's memory); `outputLatencyMilliseconds`
     (the processor's buffer when it plays, and the context's `baseLatency + outputLatency`, NaN read as 0) and
     `pathCode` (the codes `web.zig` maps: 0, 2 starting, 3 running, 4 failed, 5 the context not running); `noteMixer`;
     `warn` - page audio keeps its last warning for the panel, since a console's warnings cannot be intercepted without
     a closure; the panel (`showDiagnostics`, a `<pre>` refreshed every 250 ms by `refreshDiagnostics`), its lines
     written by `describeOutput` into a `TextBuilder` - std's formatting is not used, as the bridge's own note says it
     brings a writer's table of functions the transpile cannot take. The builder's test runs natively:
     `page_audio.zig` joined the fast test roots (`zig build test-page_audio`, 1 of 1). The whole file - with every
     public function referenced - compiles to C and transpiles through c2js to JavaScript that parses. Next: the
     wiring - the bridge's boot (stage 5 polling `isRendererSettled`) and its `dom` answers calling `page_audio`; the
     page test against the transpiled file (exports for Node published only when the file is the root); and
     `audio_output_program` deleted.
     **The page test moved onto `page_audio.zig` (Oct 12).** The file publishes its entry points (`page_audio_*`,
     `callconv(.c)` wrappers) only when it is its program's root (`@import("root") == @This()`); `buildPageAudioJs`
     transpiles it so, and `audio-page-test` drives it - the bridge still runs the JavaScript program until the wiring.
     The test now covers: the boot's loading (settled asynchronously), the gesture listener (five events, in the
     capture phase; a tap resumes the context), the held note for 400 blocks, the panel's text as page audio writes
     it, a ramp's notice copied into the app's memory, no handle kept by a frame's calls (100 frames), `stop`, the
     pulled path. Two bugs found by it, both fixed: `startForwarding` set its state after installing the port's
     handler - a message delivered at once found the state not yet there, and `starting` then overwrote `running`
     (Chrome delivers asynchronously, so it was latent); and **c2js drops `(&x)->field = value`** - Zig emits it for
     an optional's null flag when a struct literal is assigned to an optional struct field, so the optional reads as
     empty after being set (twenty-line repro: `?Report` set from a literal, then `!= null` is false; the JavaScript
     holds `((1032 + 0)).is_null; false;`). `page_audio` keeps a plain struct and a flag; the transpiler's fix is a
     debt of step 9.
     **Wired (Oct 12): the page's sound is Zig.** The bridge imports `page_audio.zig` (its header now names two
     imports kept apart to be tested; `addBridgeSource` declares the file as an input); boot stage 3 hands page audio
     the exports and the module (`setAppExports`, `prepareRenderer`), and stage 5 polls `isRendererSettled` each tick
     instead of a promise; the `dom` answers call page audio; `audio_output_program` - 47 KB of JavaScript, with its
     push processor, its `audioOutput` and `viewOfAppMemory` - is deleted, with the four push registrations. A frame's
     forwarded commands travel as one message (`Mixer.forward_batch`, up to 32 commands; sent when full, at the frame's
     end, and before samples or a note, so that the other side meets everything in the order it was sent); the native
     forwarding test's stand-in splits a message as the worklet does and counts them - a play and a volume change in
     one frame arrive as one message of two. Green: `test-sound` (256 of 261 - the platform files' tests, run with it,
     lost `AudioRing`'s four and a net one of headless's), the page and worklet tests, the smoke run with every import
     resolved. The page, measured part by part: the bridge's memory image 40 KB smaller (the program lived there as a
     string), its code 94 KB larger (page audio, transpiled - c2js writes about twice the hand-written size), the app
     module 3 KB larger: 57 KB more in all, 1.8 %. Next: Simon's phone - Chrome (the worklet) and Claude's viewer (the
     script processor) - then step 3.
     **Simon's phone, Chrome (Oct 12): plays, with a glitch once in a while.** The panel: 12 750 blocks, loudest 0.354,
     57 notes posted - and the context's output latency risen from 24 ms to 88: Chrome on Android enlarges its buffer
     after it detects underruns, so the glitches cost latency as well. So step 3 began with the worklet's allocations
     (the performance review's item 4), each a chance of a collection on the audio thread. Counted from c2js's
     runtime, a block made five objects: `js_func`'s callback wrapper two arrays (its rest parameter and `map`),
     `js_try_call` one (`__args`), and two views. Now none: c2js's runtime gained `js_func3` (a callback of exactly
     three arguments, building no array) and `js_try_call1` (one argument, no array) - `process` and the render call
     use them; the two views are made once and kept (`keepViewsFresh`), made again only when stale - another address
     or length, or detached by the instance's memory growing, whose views read a length of 0 (miniaudio's test). The
     worklet test counts the views made over a buffer: a steady block makes none (red when the views are remade each
     block). And the panel shows the browser's own count where it gives one (`playoutStats`, in Chrome):
     `playout: 3 glitches, 21 ms filled in | latency 31 ms (24 to 88)` - so that the next screenshot measures what
     was heard. The c2js canary passes.
     **Still glitchy (Simon, Oct 12), and measured where it can be.** His Chrome has no `playoutStats` (no `playout:`
     line); the latency held at 24 ms this time. A steady block allocating nothing, what remains is told apart by
     timing inside the worklet: a long block is this program, a collection, or a function compiled on its first call;
     a long gap between blocks with short blocks is the thread not run in time - the page draws with WebGPU at 60
     frames a second on the same phone. So the worklet keeps, each second, the longest block and the longest gap from
     one block's start to the next (on `performance.now()` where a worklet has it, else `Date.now()`), and the panel
     shows them (`worklet: longest block 1.66 ms, longest gap 4.6 ms`). Measured in Node on x86, outside the repo
     (5 000 blocks): a block's median 3 microseconds silent, 10 with a chord of three notes, the 99th percentile 25 -
     and rare spikes of 4 to 14 ms, too long for the young collections Node traced (0.1 to 0.8 ms, the harness's own),
     so the sandbox's scheduling or V8's compiling, which only the phone can tell apart. And the second audio context
     is gone (the review's item 1): the older layer's context is made on the first use of `music`, `streams` or the
     analyser (`olderLayerContext`), not at `init` - a page that plays only through the mixer holds one context, one
     output stream (the smoke run: 4 181 host calls at init, two fewer).
     **The sound path's performance reviewed (Oct 12, `sound_performance_review.md`).** Clean where it matters - no
     allocation and no lock on the audio threads, Rigtorp queues, bounded work, zero-copy on Windows, precision that does
     not drift; the arithmetic is tens of microseconds of a 2.67 ms block. Six costs, folded into the order: the second
     audio context every sound page makes (the older layer's, for music and streams - lazy, or gone with step 3); the
     voice slot's inline 1 920-byte tail copy (2 080 bytes a slot; split hot from cold - 12 KB instead of 133 KB); the
     resampling position kept in memory (a local); the worklet's per-block allocations (views made once); one message
     per forwarded command (a frame's in one); flush-to-zero on the Windows render thread. One fixed at once:
     `takeNoticeBytes` no longer makes a view on frames with no notice. Where they go - after the comparison with JUCE and
     miniaudio (in the review's last section), as the revised order says: the forwarding batch with the wiring (step
     2); the slot split, the position, the worklet's views, flush-to-zero and the worklet's asynchronous start as step
     3, the audio threads' hot paths; the second context with music and streams (step 4).
     **Turn 1 (b), landed (Oct 12, night): the worklet's start off the audio path, and the warm-up.** Part (a) waits
     on Simon's screenshot of the `worklet:` line, taken on these pages. `audio_worklet.zig`: the constructor keeps the
     port, the constructors and the clock, then asks `WebAssembly.instantiate(module, imports)` and returns; the
     promise's callbacks are `onModuleLinked` (start, `warm_up`, the buffers' addresses, `onmessage` set, `ready`
     posted) and `onModuleLinkFailed` (`postFailure`, now shared with `renderCaught`). Messages sent before then wait
     in the port's queue, which starts only when `onmessage` is set. `sound.zig`: `RendererHost.warmUp` plays in a
     scratch host it allocates and frees - a generator, mono samples at 24 000 Hz and pitch 1.5, stereo samples, all
     at volume 0, for 64 blocks; then the stereo samples released under their voice and the other two stopped, rendered
     until ended - so the host itself is untouched (it takes `*const`). A deviation from the text above: the voices
     play through all 64 blocks rather than one block after 64 silent ones, so that the voice paths are the ones made
     hot. The instrument: `Renderer.warmInstrument`, called where `set_instrument` is applied, runs the instrument's
     four functions on a note of its own on the stack - no slot, queue or notice touched. Export `worklet_abi.warm_up`.
     Tests: `test-sound` - a warmed host renders a tone bit for bit as a host never warmed, no voice playing, every slot
     at generation 0, every queue empty, nothing leaked; an instrument set leaves its slots free and queues nothing.
     The worklet test - nothing posted, the port not listening and a block silent before the promise resolves; `ready`
     one turn of the event loop later; the sine, the ramp and the note bit for bit as before; handles 16 and 16. The
     page test unchanged and green. Built for the web: all nine sound examples. Simon checks: the glitches - rarer, or
     gone - and the panel's lines. Next: part (a) by the screenshot; then turn 2.
     **Simon's screenshots after turn 1 (b) (Oct 12, night): still some glitches.** `audio_keyboard` in Chrome on his
     phone: `latency 4 ms + 24 ms` held; `worklet: longest block 1.00 ms, longest gap 5.0 ms`, and in a second
     screenshot `12.0 ms`; the readout's table empty on the worklet path (step 8 brings its rows). Read by the rule:
     a block of exactly 1.00 ms is a clock counting whole milliseconds - `Date`, where the worklet has no `performance`
     - so the block's time says only "under 2 ms"; and the rule's 28 ms bound was the wrong buffer (corrected in turn
     1's text). Simon: continue with the plan, keeping the glitches in view.
     **Turn 2's renderer half, and a dropout count, landed (Oct 12, night).** `sound.zig`: the tail copy left the slot -
     `Renderer.tail_copies: [voice_capacity]TailCopy`, a slot finding its copy by its index - and `@sizeOf(VoiceSlot)`
     is 160 bytes natively (2 080 before; 64 slots 10 KB rather than 133), held by a comptime check against
     `voice_slot_most_bytes` (256). `readSampleSource` keeps the position in a local, written back by a `defer` on
     either return: in the slot, every write to the output slice could have changed it as far as the compiler knew -
     and while the copy lived in the slot, the copy WAS that slice. Test: two ramps panned hard left and right,
     released in the same block, fade over their copies bit for bit as each does with its neighbour silent; made red by
     every slot using copy 0 (the left channel heard the right voice's tail, -0.475 for 0.272). `page_audio.zig`: a
     `dropouts:` line from `getOutputTimestamp` - the speaker's time less the timeline's is constant while the output
     plays the rendered frames back to back, and steps up by exactly the silence played when the renderer is late (a
     deeper buffer after an underrun does not move it). Read with the panel every 250 ms; a step of 2 ms or more is a
     dropout; counted since the context last started. `audio_worklet.zig`: its stats say whether the clock counts whole
     milliseconds, and the panel says so beside the worklet's line. Tests: the page test - unbroken readings no
     dropout, 9 ms and 3 ms steps two dropouts of 12 ms, a drift of 0.01 ms none, a suspension no dropout and a fresh
     count; `test-sound`, `test-page_audio`, the worklet test green. Built for the web: the nine sound pages. Simon
     checks: the `dropouts:` line when a glitch is heard - a count that moves with each glitch makes them the output's
     underruns (then the worklet's scheduling, and the browser's buffer, are the levers); a count that stays at none
     while glitches are heard puts them in the sound itself. Next: turn 2's rest - flush-to-zero on the Windows render
     thread, the Windows build of both examples, the full `gate`.
     **Turn 2's rest, landed (Oct 12, night): flush-to-zero, in the renderer.** First written in zimrmath and called
     once by Windows' render thread; withdrawn on Simon's note that zimrmath must hold on every platform, shaders
     included - a GPU has no such register (SPIR-V's float controls are execution modes fixed when a shader is
     compiled, and WebGPU exposes none), and wasm's arithmetic is fixed by its specification. Meanwhile a concurrent
     session had written the better form into `sound.zig` (22:11): `enterFlushToZero` / `restoreFloatingPointMode`
     around each `Renderer.render`, as JUCE's `ScopedNoDenormals` wraps each block - so the headless output, which
     renders on the app's main thread, leaves the app's arithmetic as it was. Kept, and finished: each register write
     now declares the register it changes (`.mxcsr`, `.fpcr` clobbers), so that the compiler cannot move a block's float
     operation across it; wasm is named as having no control, and any other CPU is a compile error until its register
     is added. Windows' per-thread call removed. Its test (a generator's product of 1e-38 and 0.01 heard as 0 inside a
     block, subnormal again after it) made red by leaving the bits unset. AArch64 compiled (`mrs`/`msr fpcr` in the
     render path); wasm through the worklet test; Windows through `audio_keyboard.exe`.
     **The gate, read (Oct 12, night): one failure, older than this turn's work.** `win32-abi-check` stopped at
     `IDC_IBEAM` - the cursors added in C3 are each `MAKEINTRESOURCE(n)`, which translate-c cannot express, and only
     `IDC_ARROW` was skipped - then, past it, at `MONITORINFOEXW` (a nameless `MONITORINFO` member in the headers, five
     fields in a row in `win32.zig`) and at `DISPLAYCONFIG_PATH_SOURCE_INFO` (demoted by translate-c to `opaque {}` for
     its bit-fields). The check now skips the `IDC_` prefix, flattens nameless structure members on both sides before
     comparing field by field, and skips an opaque twin - `win32.zig` pins those layouts itself. Green; made red by
     swapping `rcWork` and `dwFlags` (`field 2 (dwFlags): offset 20 size 4, but rcWork: offset 20 size 16`). The rest of
     the gate passed as far as it ran (spv2wgsl 106 ok, doc-gate, the audio tests, doc-sync); the full gate is to run
     again, detached, and be read in a later turn.
     **Turn 3's code is in the tree (the concurrent session, 22:11): `shepard_instrument`,** with three tests - the
     twelve notes' centroid within a cent and their loudness, the attack's ramp (frame n at most n / 96 of the
     velocity), a chord of three. `test-sound` green.
     **Turn 3, reviewed against its text (Oct 12, night): done.** Every point holds: the pitch class `key mod 12`; ten
     partials an octave apart, the lowest 4 to 5 octaves under the 400 Hz centre (12.5 to 25 Hz), the highest 6.4 to
     12.8 kHz; the bell one octave wide, its amplitudes scaled by its area so that they sum to 1 at most; a 2 ms linear
     attack (96 frames) and the sine's release; the state 40 bytes, held under the voice's 64 by a comptime check. The
     tests ask what the text asks, some more strictly: the twelve centroids within a cent, their loudness within 0.1 dB
     of one another and within 1 % of the bell's prediction, peaks under 1; frame n of the attack at most n / 96 of the
     velocity (stronger than "no step over 0.01"); a chord's three nearest-centre partials each at 1 % of its
     predicted amplitude, and every slot free a second after the release. One deviation, documented in the code and
     better than the text: the partials' phases come from the lowest partial's sine and cosine by angle doubling
     (`sin 2a = 2 sin a cos a`, `cos 2a = cos^2 a - sin^2 a`) - two trigonometric calls a frame instead of ten - rather
     than `frac(phase x 2^k)` per partial; the doubling doubles the angle's rounding error each octave, 512 times f32's
     6e-8 turns at the top partial, whose amplitude is four millionths.
     **The sound tutorial begun (Oct 12, night; Simon: before the plan's next step).** The backends tutorial's chapter
     14 becomes a tutorial of its own, `src/notes/tutorials/sound_tutorial.html`, rewritten for the design as it is
     (the chapter still describes the deleted push path) and organised as a course: 1 sound as numbers, 2 playing sound
     (the API), 3 voices and their names, 4 the arithmetic of a block, 5 the two sides of the mixer, 6 outputs, 7
     instruments, 8 latency, 9 from a key to its sound, 10 other engines. Written: chapters 1 and 2, the contents for
     all ten; then chapters 3 (names, generations, held slots and live names) and 4 (a block's four steps; pitch in
     32.32; pan, constant power and balance; ramps over one block; fades across blocks, pausing, unloading over the
     slots' copies; summing and headroom; subnormals flushed per block), with folds of the code each explains; then
     chapters 5 (the two sides and where the renderer runs on each platform; commands, notices and the queues' traffic;
     the lock-free ring, release and acquire, cache lines and the lagging copies; the registry by id and who frees
     samples) and 6 (outputs pull; the contract's requests; WASAPI's render thread writing straight into the device's
     buffer; the headless clock and the WAV capture; the browser's second instance, its messages, its asynchronous
     start and warm-up, its block, the loading order and the script processor, the gesture); then chapters 7
     (the instrument's four functions; keys and frequencies; the two note queues and the instrument's slots; the sine,
     its release and its phase; stealing a slot and its fade; the Shepard instrument, its bell, its two invariants, its
     angle doubling) and 8 (the four terms from key to ear, per platform; the readout's columns; dropouts, their three
     causes, the output's offset as their measure). Found while writing chapter 8: a steady worklet block still
     allocates two numbers - the clock's two readings, each stored in c2js's handle table as a boxed double - so the
     tutorial claims no arrays or views, not no objects. A `js_call0_num` in c2js's runtime (the result returned as a
     number, never stored in the table) would make the block allocate nothing at all: a candidate for the glitch work.
     **The sound tutorial, complete (Oct 13).** Chapters 9 (input read once a frame and what it costs a key; bindings
     and `on_input`, decided and marked not built; the comparison of where each system reads keys; the next block or
     the key's own time) and 10 (other engines: where they mix and what they do in a browser; how the main thread
     reaches the audio thread and who frees memory; stop, volume and pan; what zimr took from each - each claim kept
     to what the study covered, a dash elsewhere). The backends tutorial's chapter 14 is now a pointer to it, its
     contents entry one line, its section 2.8 links to the sound tutorial's browser section, and the stale "sound
     output (14.13), an 8 198-byte string" example in 2.7 - the JavaScript program page audio replaced - is a general
     sentence. doc-folds: 25 blocks in the sound tutorial, 144 left in the backends tutorial; doc-gate 16 pages. From
     here the tutorial is kept in sync with every sound change, in the same turn. Published like the others (`doc_pages`, its folds generated by `doc-folds`), linked from `readme.html`
     (the sound paragraph, rewritten for the mixer, and a "Sound" group in the tutorial index); doc-gate 16 pages. The
     backends tutorial keeps its chapter 14 until the new page covers all of it, then points to it. From here, every
     step that changes the sound keeps the tutorial in sync in the same turn.
     **Turn 4a, the scale star drawn (Oct 13), from Simon's second drawing.** `examples/audio_scale_star`: the notes on
     the circle of thirds, clockwise from the top (`circlePlaceOfDegree(d) = 4 (d - 1) mod 7` - 4 undoes a walk of
     2 degrees a place, since 2 x 4 = 8 = 1 mod 7); each chord at its third's place, majors at 1.55 radii, the minor
     side at 0.48; lines from a box's edge to a note's ring - root solid with an arrowhead, third a zigzag, fifth
     dashed (`lineDashed`) - majors amber, the minor side blue; double rings for 2, 3, 6, 7 and double borders for
     ii, iii, vi, vii (the font has the degree sign); everything in proportion to a radius fitted to the window. The
     circle's invariants checked at compile time (every degree its own place; every chord three neighbours). Added to
     `wgpu_apps` (web, Windows, headless at once); editor configs regenerated (320 apps). Seen headless (lavapipe, a
     720 x 760 window): the layout matches the drawing; the zigzags, too short beside their thirds at first, given room
     (note radius 0.17, inner chords 0.48). Built: the page. Nothing plays yet: 4b. Simon checks: the page on his
     phone, both ways round.
     **Turn 4b, the scale star plays (Oct 13).** The digits 1 to 7 (top row or keypad) and a press on a note play it
     while held; a press on a chord plays its triad while held; sliding while pressed moves to what is under the
     pointer. Each degree keeps a count of what holds it (`hold_counts`): its key goes down when the count leaves 0 and up
     when it returns, so a note held by its digit and by a chord sounds once. Lit: a note while it sounds (filled with
     its own chord's side color), a chord while all three of its notes sound - so 1, 3 and 5 on the keys light I as a
     press on I does - its box filled and its lines doubled. The Shepard instrument is set at `init`; keys are one real
     octave from middle C (60 62 64 65 67 69 71). Headless (digit 1 held 0.5 s, then a press on I for 1 s): the frames
     lit as described; the capture's RMS 0.1328 for the note - the bell's 0.3755 x velocity 0.5 x the centre's 0.7071,
     exactly - and 0.2300 for the chord, 0.1328 x sqrt 3; the chord's strongest partials 196, 262, 330, 392, 523, 660,
     784 Hz, C E G in octaves round the bell. **Found on the way: the flush-to-zero assembly did not compile in debug
     native builds** - Zig's own x86-64 code generator (debug) rejects a memory operand made from an operand's name,
     `(%[control_address])`; LLVM (release, tests) took it, so nothing had compiled the mixer in debug natively since
     22:11. Now the address goes in rax, `(%%rax)` with `"{rax}"`, run on both generators in a scratch program (MXCSR
     1f80, 9fc0 with the two bits, 1f80 restored). `test-sound` green; the Windows program built; the tutorial's 7.5
     names the example, with the levels as measured. Simon checks: the page on his phone - the notes at one height.
     **The scale star for the phone (Oct 13, Simon: chords farther out, every touch a note or a chord, his rainbow
     keyboard's colors, red yellow cyan lines, the whole screen used).** Colors: each degree its key's color on a
     rainbow keyboard (C red, D orange, E yellow, F green, G cyan, A blue, B violet), a chord its root's, dimmed 45%
     toward the background until it sounds; lines by role - root red, third yellow, fifth cyan, the colors of 1, 3, 5 -
     dimmed until their chord sounds, then doubled. A press anywhere holds the NEAREST note or chord, by the distance to
     its disc or box (0 inside), so the window is divided among the fourteen. Layout: the notes on an ellipse, the
     chords on ellipses 1.62 and 0.45 times it; every note a disc of radius u, every chord a 2.3u x 1.5u box, u the
     largest at which no two targets come within 0.3u (0.55u between a chord and its own notes - the line's room; the
     disc-to-box distance found exactly, by halving); the figure's bounding box fitted to the window on each axis, its
     middle at the window's (`fitAxis`); places and sizes settled together in five rounds; and the figure worked out
     with 1 at the top and with 1 at the right, the larger notes kept. Seen headless at three shapes: 720 x 760 (1 at
     the top, u about 43), 412 x 860 upright (1 at the top, the figure from edge to edge, u about 27), 860 x 412
     sideways (1 at the right, u about 30). Turning alone did not help upright: either way two inner chords face their
     thirds across the narrow axis; fitting the bounding box did, the figure having been lower than the window's middle.
     The sound unchanged (one note 0.1328 RMS). Built: the page.
     **The scale star: shapes, bigger chords, the button's corner, multitouch (Oct 13; Simon: almost perfect).**
     Shapes mark the side: squares for the major side (the chords I IV V, the notes 1 4 5 whose own chords they are),
     circles for the minor (ii iii vi vii, the notes 2 3 6 7, still with a double ring); a chord's size is twice a
     note's (`ShapedSize`). Every pair's limit on the size unit by its shapes (`largestUnitApart`: circle-circle and
     square-square in closed form, circle-square by halving); hit tests and line ends by shape (`distanceToShape`,
     `shapeEdgeToward`). The page's fullscreen button (52 px, 10 from the corner - `c2js.zig`'s `#fsbtn`) leaves its
     62-px corner free, as a strip on the right or along the bottom, whichever keeps the notes larger. Bigger chords
     shrank everything on a short screen (sideways u 15, the inner chords too near their thirds along the short axis):
     the chords' ellipses are now searched too (outer 1.5/1.62/1.75, inner 0.4/0.5/0.6/0.7), with the turn and the
     button's strip - 48 layouts, kept in the app's state until the window's size changes (`layoutOf`). Sideways
     860 x 412: 1 at the right, u about 20, I clear of the button; upright 412 x 860: 1 at the top, the strip along the
     bottom, u about 18. Multitouch: one hold per pointer (`PointerHold`, up to ten fingers and the mouse), each
     finger by its stable identifier (`getTouchPointId`) following it to its nearest target; the mouse ignored once
     any touch has been seen, since a browser also turns a touch into the mouse. Not verifiable headless - the script
     language has no touch commands: Simon's phone checks several fingers at once.
     **The scale star: the chords' triangles (Oct 13).** Each chord but vii fills the triangle between its centre, its
     root's and its third's faintly with its color (IV's green between IV, 4 and 6), drawn first, under everything - 86%
     toward the background, 70% while the chord sounds; the six triangles lie in separate sectors, so none covers
     another. The double rings are gone (the shape alone marks the side). vii, the diminished chord, is one and a half
     units rather than two (`chordSizeInUnits`), every use of a chord's size going through it - the layout's pairs and
     fit, the hit test, the lines' starts, the drawing. Seen headless at 720 x 760 (the figure turned, 1 at the right).
     Built: the page.
     **The scale star: both of a chord's triangles (Oct 13).** Each chord but vii now also fills the triangle between
     it, its third and its fifth, fainter than the one between it, its root and its third (90% toward the background
     at rest, 76% sounding; the root-third one 80% and 60%) - the third being what makes a chord major or minor. The
     outer chords' triangles tile the outside from 4 round to 2, the inner ones the inside from 2 round to 7, leaving
     only vii's sector. Built: the page.
     **A second version: `audio_scale_star_hands` (Oct 13, Simon).** The window split: a third for a chooser - the seven
     chords alone on one circle, at their angles in the star (on the left, or at the top of a screen held upright) -
     and two thirds for the star. A finger on the chooser chooses the nearest chord and plays nothing; the star turns,
     in 0.05 s, by the chord's turn (`chordTurn`: back by its root's place in sevenths), so that its root, third and
     fifth sit at places 0, 1, 2, where 1, 3, 5 sit unturned - under the right hand's index, middle and ring fingers -
     the shorter way round from where it is shown. Fingers on the star are matched to the star at its TARGET turn, so
     the chosen chord's notes sound as soon as it is chosen, while the star is drawn turning (`shownTurn`, linear over
     the 0.05 s). The star's layout holds at all seven turns: its size unit the smallest over them, its fit the union
     of their places. Seen headless (1000 x 560): I chosen at the start; a press near IV on the chooser turned the star
     so that 4, 6 and 1 sat where 1, 3, 5 had. The tutorial's 7.5 names it. Built: the page; editor configs (321).
     **The two-hand star, for the fingers (Oct 13, Simon).** Both circles now run counterclockwise (`pointAtPlace`:
     place k at `turn - k/7`; `chordTurn` turns the star on by the root's place), and the star starts with 3 at the
     bottom of the screen (`bottom_three_turn` = 1/2 + 1/7), so 1, 3, 5 lie along the bottom from left to right under
     the right hand's index, middle and ring fingers; the orientation is no longer searched. Sizes swapped: notes two
     units, chords one, I and vi 1.25, vii 0.75 (`chordSizeInUnits`; the chooser's spacing from the largest). Pitch
     steps: for each sounding note, dots flow from it toward the note a step above and from the note a step below
     toward it, colored from one note's color to the other's, three spacings a second (`drawPitchSteps`,
     `drawMovingDots`). A thin keyboard along the bottom (6% of the height, 16 to 36 px), C to B in the notes' colors,
     the sounding notes lit, the black keys drawn as on a piano; the star's room ends above it, and the fullscreen
     button's corner is now cut from the star's room by the button's actual place (`button_corner`). A finger on the
     keyboard plays nothing. Seen headless at 1000 x 560: 3 pressed - dots 2 to 3 and 3 to 4, E lit; 4, 6 and 1 held -
     IV lit, six flows, C F A lit. Built: the page.
     **The two-hand star: the keyboard plays, hero notes (Oct 13, Simon).** A finger on the bottom keyboard holds its
     white key's note (a black key counts as the white key under it; beside the keyboard, nothing), so it sounds and
     lights in the star exactly as a press there: the same `PointerTarget.note`, the same hold counts. The chosen
     chord's three notes are heroes, a fifth larger (2.4 units): the layout knows them at each of its seven turns
     (`hero_root_place`, `turnedToChordStep`), so the sizes and the fit allow for them wherever the chosen chord puts
     them; the star drawn and the star the fingers find both carry the chosen chord's heroes (`starAsChosen`). All
     chord outlines black, both diagrams (`drawShape`'s stroke color). The chooser's share 28% of the window rather
     than a third. Seen headless at 1000 x 560: a press on the keyboard's E lit 3 in the star, the E key and the
     flows 2 to 3 and 3 to 4, and sounded (RMS 0.134); 1, 3, 5 larger at the bottom. Built: the page.
     **The two-hand star: the heroes in a row (Oct 13, Simon).** The star's bottom flattened so that its three places
     there - where the chosen chord's root, third and fifth sit - lie on one line: within a seventh of a turn of the
     bottom each point's direction is pulled down to the bottom's height (the y alone, so the three keep an even
     spacing across), the pull fading by a smoothstep to nothing at two sevenths (`flattenedDirection`, `bottomPull`).
     It acts by angle, so notes slide onto the row and off it as the star turns, and the layout's sizing and fit see
     the flattened curve through `pointAtPlace`. The pitch-step dots now follow only notes touched themselves - a
     finger on the note or its key, a digit - not those a chord holds (`touch_counts`, `touchDegree`). Seen headless:
     I chosen, 1 3 5 on one line; vi chosen, 6 1 3 on it; 3 touched, its two flows. Built: the page.
     **The two-hand star: the chords trade sides (Oct 13, Simon).** With a minor-side chord chosen (ii, iii, vi, vii),
     the minor side's chords go outside and the major ones inside, sliding over the same 0.04 s as the turn - now 25%
     faster than 0.05 (`turn_duration_seconds`) - so that the chosen chord is always outside at its third's angle: the
     bottom, below its three notes, where a finger plays it. `Layout.minor_side_outside` (0 to 1) sets each chord's
     ellipse between the inner and the outer (`chordCentre`); `turnedToChordStep` sets it for each turn's chord
     (`degreeAtPlace`, the walk of thirds), so the sizing and the fit allow for both arrangements. One transition
     fraction drives the turn and the trade (`transitionFraction`); while it runs, the star plays nothing and what the
     fingers held on it is let go, to sound again from where they rest once it has arrived (`isInTransition`); the
     keyboard and the digits stay live. Seen headless: vi chosen - ii, iii, vi, vii outside, IV, V, I inside, vi at
     the bottom below 6 1 3. Built: the page.
     **The two-hand star: the pinky's place, a smaller chooser (Oct 13, Simon).** The place after 5 - the chosen
     chord's seventh (7 under I, 5 under vi) - is brought down beside the row and out to the right, under the little
     finger, but not onto the row: on the right-hand side only, the bottom's pull now falls to 0.65 at two sevenths
     from the bottom (not to 0) while the curve's x is stretched to 1.1 there, both fading out by three sevenths, each
     segment a smoothstep (`warpAt`, the `Warp` of pull and stretch; `flattenedDirection` applies it). The left side
     as before. The chooser's share of the window 21% (from 28%). Seen headless: I chosen - 7 down and right of 5; vi
     chosen - 6 1 3 on the row, G at the pinky's place. Built: the page.
     **The two-hand star: room for the pinky (Oct 13, Simon).** The place of 5 - the chosen chord's fifth, the row's
     right end - drawn in toward the middle to 0.85 of the ellipse's x (`fifth_stretch`), eased in from the bottom by a
     smoothstep so that the row stays straight; from there the stretch eases to the pinky's 1.1. The row's gaps 172 and
     145 px at 1000 x 560, the seventh's place clear of the fifth. Built: the page.
     **The two-hand star: an eighth key, a thicker keyboard (Oct 13, Simon).** The keyboard C to B and the C above
     (`keyboard_key_count` 8, `degreeOfKey`: the eighth key degree 1 again - the Shepard instrument plays a pitch class
     the same in every octave), 20% thicker (7.2% of the height, 19 to 43 px), ending 16 px further from the fullscreen
     button (`keyboard_gap_before_button`). The star's part ends 4% of the window's height above the keyboard
     (`star_lift`), so the figure sits higher and its bottom chord stands clear of the keys. Seen headless: the top C
     pressed lit 1 in the star and both C keys, the flows 7 to 1 and 1 to 2. Built: the page.
     **The two-hand star reviewed for understanding (Oct 13, Simon).** Names: one word one thing - `StarLayout`,
     `ChooserLayout`, `WindowLayout` (was `Layout`, -, `Layouts`); the star's variable `star` (was `layout`); "key"
     split three ways - `midiKeyOfDegree`, `degreeOfKeyboardKey`, `readDigitKeys` / `is_held_by_digit_key`; `PlayTarget`
     (what a pointer plays, from the star or the keyboard), `PointerDown`, `starForChoice`, `starTurnForChord`,
     `three_at_bottom_turns`, `starCurveDirection`, `lineColorOfRole`, `drawNotePath`, `minor_side_outside_fraction`,
     `transition_duration_seconds`. Structure: the move between chords one value, `StarTransition` (its start, its turn
     and its sides from and to; `fraction`, `isUnderWay`, `shownTurn`, `shownMinorSideOutside`; `at_rest`), in place of
     five loose fields and four functions; `readPointers` in named steps - `targetAt` (what a pointer plays, by the
     window's part), `holdWithPointer`, `letGoOfPointer`, `holdSlotOf`, `freeHoldSlot`; `chooseChord` with the shorter
     way round spelled out in locals. The file in sections from its vocabulary to its frame: colors, the scale, shapes
     and sizes, the star's curve, the star's layout, the window, choosing a chord, the app's state, playing, reading the
     input, drawing, the frame; `WindowLayout` beside the layouts it holds, `deinit` beside `initState`, the sounding
     tests with the holding. Every function documented; the header rewritten for the app as it is (it still said
     thirds, and that fingers sound while the star turns). Checked by behaviour: a script holding a digit, choosing a
     chord (a frame mid-move and one after), pressing the star and a keyboard key captured five frames and the sound
     before the review and after it - pixel for pixel and byte for byte the same. Built: the page.
     **The two-hand star: the chord as a Lissajous curve (Oct 13, Simon).** At the star's centre, what sounds draws
     itself: each coordinate swings like one note, `sin(frequency x s)`, the frequencies in just intonation as the
     smallest whole numbers (`just_interval_ratios` by semitones - 7:5 for the tritone, so vii is 5:6:7 - scaled by the
     least common multiple of the denominators, `curveFrequencies`): major 4:5:6, minor 10:12:15, the fifth 3:2 - whole
     ratios so that the curve closes after one round and stands still. One note a line; two notes the flat figure of
     their interval (upper across, lower upright), still; three a 3-D figure - fifth across, root upright, third in
     depth - turning at 0.08 turns a second about the upright axis, seen from the front. Which notes: the sounding ones,
     the chosen chord's first, at most three; a chord of the scale (all three, or two of the chosen) taken from its root;
     any other set stacked from whichever note gives the smallest largest frequency (`curveNotes`). Square, as large as
     the inner ring on its shorter side, under the lines, notes and chords; 48 segments per swing of the fastest note.
     The tutorial's 7.5 explains it. Seen headless: C and G - the 3:2 figure; C E G - the 4:5:6 figure, turned a second
     later. Built: the page.
     **The two-hand star: the curve in its notes' colors (Oct 13, Simon).** No curve for a single note (the unison's
     line said nothing). The pitch-step dots only around a note sounding alone (`onlySoundingDegree`); the touch counts
     that told a note touched by itself from one a chord holds are gone, a lone sounding note being always one played
     alone. The curve drawn in a gradient of its notes' colors, bottom to top and back, through every color as often as
     the bottom note swings while the curve goes round (`curveColorAt`) - four times for 4:5:6. Seen headless: C E G -
     the figure in red, yellow and cyan, no dots; 3 alone - its two steps, no curve. Built: the page.
     **The two-hand star: the chromatic circle and the chord's name; the curve's colors (Oct 13, Simon).** The curve's
     gradient now runs along its LENGTH, there and back through its notes' colors (C E G E C) - by its parameter it
     changed all at once where the point slows at the turns, which read as jumps (`curveColorAt`; points and running
     lengths first, `most_curve_points` 48 x 27 + 1). New: at the top of the left hand's column (the left of its band
     upright), the twelve pitch classes in order of pitch, C at the top - the scale's notes in their shapes and colors,
     the sharps grey dots - the sounding ones joined by a line, a triangle or a polygon filled faintly in the root's
     color, and the chord's name in the middle with its kind spelled out (`drawChromaticCircle`). Naming
     (`nameOfChord`, `namedChord`): the sounding set as twelve bits (`PitchClassSet`), rotated to each candidate root
     and matched against `chord_patterns` - triads, sevenths built of thirds, sus, sixths, add9, ninths, the bare fifth
     - the chosen chord's root first when it fits (C E G A is C6 under I, Am7 under vi), then the first pattern from
     the lowest root; two other notes named by their interval, upward as the curve stacks them; else the notes. Checked
     at compile time: the seven triads, G7, Cmaj7, Dm7, Bm7b5, C6/Am7 by the chosen root, Csus2/Gsus4, C5 - a wrong
     expectation made red ("the chord Am7 is named C6"). The rotation without std.math (banned outside zimrmath): the
     set written twice in 24 bits, twelve taken from the root. Seen headless: C E G "C major", + A "C6", G B D F "G7",
     upright A C E G "C6". The tutorial's 7.5 explains both. Built: the page.
     **The two-hand star: the thumb's chord (Oct 13, Simon, dictated).** Holding a chord on the chooser now plays it,
     at half strength (`thumb_chord_velocity`, 0.25), for as long as the finger stays - choosing it too, as before -
     so that the left thumb alone gives the chord beneath the right hand (`PlayTarget.chooser_chord`). A note's holds
     are counted two ways (`DegreeHolds`: thumb, full), and it sounds once at the strength they call for
     (`strengthOfDegree`: full if anything holds it fully): when that changes it is struck again at the new strength
     - the instrument lets a held key go when it is struck again - so the right hand pressing a note the thumb's
     chord already sounds is heard, struck fully, and lifting it returns the note to the thumb's strength, the full
     note fading beneath (`soundStrengthChange`). Measured headless: the thumb on I, RMS 0.1151 (predicted 0.1150:
     0.3755 x 0.25 x 0.707 x sqrt 3); with the digit 1 as well, 0.1630 (C full, E and G half: 0.1626); the digit
     lifted, 0.1150; the thumb lifted, silence. Built: the page.
     **A handle leak in the bridge's input listeners, found by Simon's crash (Oct 13).** After a few minutes of
     playing `audio_scale_star_hands` on his phone: "RangeError: Invalid array length" in `__href`, the handle table
     (`__H`) grown past what the browser allows. The frame is bracketed by `js_mark`/`js_reset` and the key and mouse
     listeners of `input` open their own scopes, but the input listeners `attach` registers - pointer down, move, up
     and cancel, wheel, keys, focus, visibility, paste, fullscreen, pointer lock, `devicemotion`, context menu - did
     not, so every handle they minted stayed: some thirty per pointer move (two bounding rectangles, a dozen
     properties, the numbers passed on, two export calls), and `devicemotion`, which Android fires sixty times a
     second whether the screen is touched or not, about fifteen per event. Fixed: each registered through
     `scopedListener(listener)`, a comptime wrapper opening a scope and closing it as the listener returns - in the
     shipped JS, `js_mark(); onPointerMove(e); js_reset(m)`. The one handle a listener made to keep, the TextEncoder
     (made lazily in seven places, some reached from inside a frame's scope, where it would dangle a frame later), is
     now made once at boot in `start()`. Left for an audit: the rarer listeners - DOM-UI events (`onDomEvent`), drag
     and drop, the file picker, the text overlays, GPU errors, the clipboard's reply - unscoped, some holding handles
     across asynchronous steps. Built: the page; every page picks it up at its next build.
     **Step 4c done: the scale star's sound checked by a tool (Oct 13).** `zig build audio-scale-star-check` runs
     `audio_scale_star` headless with a committed script (`examples/audio_scale_star/check.script`: the seven notes,
     then the seven chords, each held 0.4 s with 0.6 s of silence after, the sound saved to
     zig-out/headless/audio_scale_star_check.wav) and then `tools/sound_capture_check.zig` on the saved sound against
     `check.expect`: for each window, the loudness (RMS within 3%) and each of the twelve pitch classes present or
     absent, measured at its partial in the octave from middle C by the Goertzel algorithm under a Hann window (present
     at 0.03 and above, absent under 0.01). The program is installed first, which makes zig-out/headless/. All 14
     windows pass: the notes 0.1325 to 0.1329 against 0.1328, the chords 0.2274 to 0.2305 against 0.2300, each with
     exactly its pitch classes (C weakest, 0.117, its partial at 262 Hz furthest from the bell's 400 Hz). Red: C E A
     expected for the chord I fails, "!G=0.141 !A=0.000". Not in the gate: it needs the machine's Vulkan driver, as
     every headless run. Next: turn 5, streams on the mixer.
     **The two-hand star in any key and mode: the design, and its first half (Oct 13, Simon).** Simon: a dropdown at
     the top left for the tonic, A to G, C by default; a second for the mode (Ionian to Locrian); everything follows,
     the keyboard starting and ending on the tonic; the colors stay with the degrees (in A, the red square is A).
     The design. A scale is a natural tonic and a mode (`Scale.of(tonic_letter, mode)`); each mode is the major scale's
     step pattern begun on another of its steps (`Mode.semitonesAboveTonic`). From them, per degree: its semitones,
     pitch class and MIDI key (the tonic in middle C's octave); its spelling - one letter a degree, a sharp or a flat
     as needed (`Scale.spellingOf`; a natural tonic in these modes needs at most one: B Lydian E#, F Locrian Cb) - and
     its fixed-do syllable; its triad's quality from the thirds and its numeral (`ScaleChord.numeral`). By degree,
     whatever the key: the colors, the places on the star and the chooser, the heroes, the pinky's place, the steps'
     dots. Every mode has three major, three minor and one diminished triad, so the star's sides hold; shapes and sides
     follow the qualities (in Dorian the red tonic is a circle); the larger chords are the tonic's and its relative
     (vi for a major tonic, III otherwise: `Scale.isMainChord`). The keyboard: the scale's notes as long keys, tonic to
     tonic, a short key between two a whole step apart (C major is the piano; A minor the piano from A). The circle of
     the twelve notes turned to the tonic, notes and chord names spelled in the key (F#m, not Gbm). A change of key or
     mode lets go of every note; fingers still down sound again in the new scale the next frame; the chosen chord stays
     the same degree, the sides trading if its side changed. The dropdowns: the engine's combo boxes (`beginCombo`) in
     a borderless window at the top left, in place of the legend; fingers play nothing while a list is open.
     Done this turn: the scale model, every table of C major replaced (`all_degrees`, the star's and the chooser's
     layouts carrying their `scale`, the state holding it), the keyboard's short keys by whole steps, the circle turned
     to the tonic, names spelled; the resting state with the tonic chord's side outside (`atRestOnTonic`). Checked: at
     C Ionian five frames and the sound pixel for pixel and byte for byte the same as before; A major (A la red, C#
     do#, G# sol#, "A major", the circle from A) and D Dorian (i ii III IV v vi VII, the tonic a circle, i outside at
     the bottom, Dorian's whole steps on the keyboard) seen headless with the default changed. Next: the dropdowns,
     and the change of scale while playing.
     **The two-hand star in any key and mode: the dropdowns (Oct 13).** Two of the engine's combo boxes at the top left,
     in a window without title, border or background (`buildScaleDropdowns`): the tonic A to G, the mode Ionian to
     Locrian; a pick changes the scale (`changeScale`: every note let go under the old scale's keys, the layouts made
     again, the chosen chord kept and the sides trading over a move if its side changed; fingers and digits still down
     sound again in the new scale - `readDigitKeys` now holds while a key is down, not only on its press). The frame
     builds the dropdowns first, so a pick lands before anything reads the scale, and renders the UI last, over the
     drawing; the legend line went, the header band 34 px. A finger that begins on the dropdowns, or while a list is
     open, is theirs until it lifts (`PlayTarget.ignored`): the finger that picks an item is still down after the list
     closes. Two engine fixes in `ui.zig`, found by a list reaching past its one-row window: `beginCombo` set the
     dropdown as the current window without `refreshItemClip`, so its items kept the OWNER's clip - neither hoverable
     nor pickable past the owner's edge - and `endCombo`'s outside-click test went through the same clip, so a click
     on an item closed the list; `combo()` hit-tested its items and its outside click the same way. Now
     `refreshItemClip` on the push, and plain rectangle tests for what floats over every window; and `Ui.isComboOpen`,
     for an app reading the pointer itself. Checked headless: the key list opened, A picked, the mode list opened,
     Aeolian picked, each list closed by its pick; A minor right throughout (A la a red circle, i ii III iv v VI VII,
     i outside at the bottom, "Am minor", the keyboard the piano from A); A C E held, RMS 0.2283 (0.2300 expected).
     Found on the way: `ui.zig`'s own `test` blocks run in no step - `src/tests.zig` reaches it only through
     `refAllDecls`, which analyses declarations and runs no test block (its own comment says so), and the filtered
     `zig build test -Dtest-filter=combo` ran none of the four combo tests. Whether to run them - after years unrun,
     some may need repair - is Simon's call. Built: the page (release).
     **The two-hand star: the chooser's polygon, a quieter thumb, the pedal (Oct 13, Simon).** In the chooser's middle,
     the seven degrees as small dots at their angles on the circle of thirds, the sounding ones joined - a line, a
     triangle, a polygon - in the chord's root's color, as on the circle of the twelve notes (`drawChooserNotes`); a
     triad is three neighbours there, so its triangle sits by its chord. The thumb's chord a quarter quieter:
     velocity 0.1875, three eighths of full (`thumb_chord_velocity`). The pedal: a checkbox beside the dropdowns holds
     the chosen chord's root low beneath everything (`updatePedal`) - not with the Shepard instrument, which has no
     height, but a voice of its own playing a generator (`generatePedal`): the root's pitch class in the octave from
     C2 (65 to 123 Hz), its fundamental and five harmonics at 1/n - a sawtooth's first terms, so that a phone's
     speaker, silent at 65 Hz, gives the pitch through the harmonics - over a 30 ms attack, its phase wrapped in 64
     bits; a new root stops the old voice (5 ms fade) and starts another. Measured headless: the thumb's chord on I,
     RMS 0.0862 (0.0862 expected); the pedal on C, harmonics 0.087 0.043 0.029 0.022 at 65.4 Hz and its multiples,
     as designed; both, 0.1112. Built: the page. Note for the lint: its autofix deletes a global the build finds
     unused - twice this turn a declaration written ahead of its first use (`letter_names`, `pedal_volume`) was gone
     after a build in between; write the use in the same edit.
     **The two-hand star: Shepard pedals, the chooser's buttons joined (Oct 13, Simon).** The chooser's polygon now
     joins the chord buttons themselves - each sounding note standing for the chord built on it - beneath the buttons,
     the separate dots gone (`drawChooserPolygon`); the chosen chord's button a quarter larger as well as lit. The
     pedals are Shepard tones like the hands' notes, with the bell moved two octaves down, to 100 Hz (`pedalStateOf`:
     the instrument's construction - the pitch class taken whole octaves down to five below the centre, ten partials an
     octave apart, Gaussian heights over the bell's area - and `generatePedal`: one sine and cosine a frame, the higher
     partials by the double-angle formulas, a 30 ms attack; 64 bytes of state, exactly a generator's). Two checkboxes,
     two `Pedal`s (`Pedal.keep`): the root pedal on the chosen chord's root, the tonic pedal on the scale's tonic,
     unchanging. Measured headless with both ticked and IV held: C2 0.0707 (0.0702 designed), F2 0.0877 (0.0830), the
     others within the IV chord's own partials' interference at the same frequencies. Built: the page.
     **Glitches on Simon's phone: where they can come from, and what would make them impossible (Oct 13).** A glitch
     is the output asking for frames that are not there in time. On a page there are two paths. (1) The renderer
     worklet, on the browser's audio thread: the main thread cannot starve it - a main-thread spike only delays the
     next commands (a late note, never a gap) - so a gap there means the audio thread itself missed its deadline: a
     garbage collection in the worklet's JavaScript realm, or the thread not scheduled. What the worklet allocates per
     block was checked: the method names are cached (`__jstr`); the clock read (`js_call0(clock, "now")`) stores a
     fractional number in the handle table, a heap number each block, 375 a second; and each frame's posted commands
     allocate a message event and its data in the worklet's realm, 60 a second. Small, but not nothing - the pending
     `js_call0_num` (a number returned without a handle) and posting only when a frame has commands would make a
     steady block allocate nothing at all. (2) The script processor, on the MAIN thread, the fallback where the worklet
     is missing - and `audioWorklet` exists only in a secure context: a page opened from `content://` or `file://` may
     not be one. On that path any main-thread spike longer than the processor's buffer is a gap, and no buffering
     inside the renderer helps, since the callback itself does not run. So, first, which path his phone plays: the app
     now has an "audio stats" checkbox showing the engine's panel (path, dry runs, margin, underruns).
     Two ways to make gaps impossible without lag, beyond those. (a) Rendering ahead, corrected afterwards: the mix
     is a sum of voices, so frames rendered ahead can stay editable until they are handed over - a new note's voice
     rendered over the span and added, a release applied as the difference between the voice's two futures - so a
     deep buffer costs no latency; it absorbs spikes in the rendering itself (a burst of note starts), not a starved
     thread. (b) No script on the audio thread at all: a Shepard note's partials are its lowest partial's harmonics
     1, 2, 4 ... 512, so one OscillatorNode with a PeriodicWave plays a whole note - twelve waves, one a pitch class -
     its envelope as a GainNode's automation, everything run by the browser's own native audio engine: neither a
     garbage collection nor a main-thread spike can then make a gap, only the OS starving the browser's audio, as for
     any native app. It trades the engine's one renderer for the browser's, for this instrument on the web - Simon's
     call. Next: his panel's reading, then (b) or the allocation-free worklet as it says.
     **Static with no dropout: a click watch in the renderer (Oct 13, Simon).** Simon's panel: the renderer worklet,
     no dropouts in 42 s, the longest block 1 ms - and still static heard. So not timing: either the sound itself
     carries clicks, or something after the renderer distorts it. The worklet's path delivers the renderer's samples
     bit for bit (`audio-worklet-test`), so the renderer now watches what it mixes, on every platform
     (`Renderer.watchForClicks`, after `mixInto`): a click is a jump in the sound's slope, measured as the second
     difference `x[n] - 2 x[n-1] + x[n-2]` - at most `a (2 pi f / rate)^2` for a sine, about 0.015 for six Shepard
     notes at their worst, while a step of height h makes it h - counted over 0.02, each channel's last two samples
     carried across blocks. `Renderer.takeClicks` gives the count and the largest jump; the worklet's stats message
     carries them (`clicks`, `largestJump`, through two exports), and the page's panel shows the count since the page
     started and the largest jump on its renderer line. Test: a 400 Hz tone at 0.4 counts none across a block's join
     once begun - its abrupt start counts its kink, two, set aside - and a step of 0.1 two a channel, its jump 0.1
     (`test-sound`, 264 passed). Simon's ask - share code with native, avoid web-specific tricks unless they are best -
     taken: the watch is the shared renderer's; the PeriodicWave idea (all-native browser synthesis) is shelved. The
     tutorial's 8.4 explains clicks and the measure. Next, by what Simon's count says: a climbing count - find which
     moments make them (re-strikes at a target's edge, stolen voices); a count at 0 - the static is the device's or
     the speaker's (a dense chord played loud on a small speaker), and lowering the level is the test.
     **Turn 5 begun: the stream's ring (Oct 13).** `Mixer.StreamRing` in `sound.zig`, beside the mixer's queue: a ring
     of a stream's frames between the main side, which writes runs in (`write`, as many as there is room for), and the
     renderer, which reads runs out (`read`); the queue's two counters on their own cache lines, release after the
     samples, acquire before, each side keeping the other's as last seen - but in runs, one count stored a run, and
     with its room from samples the main side owns (`initOver`, a power of two frames). A run wrapping past the end is
     two copies (`piecesOfRun`). A short read counts its missing frames as dry (`takeDryFrames`). Tests: runs in order
     wrapping past the end, the room, a full ring taking part of a run, dry frames counted and taken; two threads
     passing 50 000 frames through 64, written in runs of 1 to 37 and read in runs of 1 to 29 (`test-sound`, 266
     passed). The tutorial's 5.2 describes it. Next: the stream voice - `Source.stream` and its `SourceToStart`, read
     through a two-frame window at the stream's rate and pitch by the samples' fixed-point position, in chunks from
     the ring, silent when dry; `Mixer.play` refusing a stream on a forwarding mixer (the worklet: turn 6); then
     `streams` moved onto it where the renderer shares the game's memory, and the streaming example's headless run.
     **Turn 5: the stream voice (Oct 13).** A third kind of source, `Source.stream` (`Stream`: the ring), carried to the
     renderer by address (`SourceToStart.stream`) - so `Mixer.play` refuses one when the commands are forwarded to a
     renderer with its own memory (the worklet; turn 6), and checks the ring is mono or stereo with a rate. The
     renderer reads it (`readStreamSource`) at the ring's rate and the voice's pitch on the samples' fixed-point grid,
     through a two-frame window slid on as the position passes whole frames (`VoiceSlot.stream_window`), primed with the
     stream's first two frames so that at the mixer's rate it plays them exactly; frames come from the ring in chunks
     of at most 64 (`StreamPuller`), each no larger than what the block still takes - computed at the block's start -
     so no frame is read out and left unplayed; a dry ring's missing frames are silence, counted by the ring. Pan law
     and looping changes extended; a stream never ends by itself. Tests: a mono tone at the mixer's rate comes out as
     written times the centre's gain, then silence past its 300 frames with at least 212 dry counted; at half the
     mixer's rate each frame spans two mixed frames, midpoints between (`test-sound`, 268 passed). The tutorial's 2.2
     describes streams. Next: the `streams` namespace onto the mixer where the renderer shares the game's memory, its
     rings allocated and freed after the voice's end notice; the streaming example's headless run.
     **Review of the last turns (Oct 13, Simon asked).** Bugs fixed: (1) `Pedal.keep` recorded the pitch class even
     when `play` failed - no slot free, the queue full - so the pedal stayed silent until its root changed; it now
     starts again whenever its voice is not playing (`isPlaying` is true from the frame a voice is started, which the
     unchanged reference capture confirms). (2) The page's stats report read its own old totals inside the struct
     literal that replaces it - right only by the fields' order, since Zig writes such a literal's fields straight into
     the destination - now computed as locals first. (3) `StreamRing.initOver` divided by the channel count before
     asserting it; the assert now comes first. (4) `sound_capture_check` read a format chunk's first four bytes
     unchecked; a short one is now an error. Style: the two circles' polygons were one idea written twice - now
     `colorOfSoundingNotes` and `drawSoundingPolygon`; dense lines given named locals (`frames_to_take`,
     `tonic_list_index`, `picked_tonic_letter`, `picked_mode`); `scopedListener`'s comment neutral. Checked: all 49
     tonic-and-mode spellings within one accidental (the spelling table's bound). Verified: the two-hand star's frame
     and sound with both pedals and IV held identical to before; `test-sound` 268 passed; `audio-worklet-test`
     passed; `audio-scale-star-check` 14 windows, none failed; the lint clean. Left: older turn numbers in `ui.zig`
     and `bridge.zig` comments, outside these turns.
     **Simon's panel: dropouts, and the latency at 272 ms (Oct 13).** The renderer worklet; dropouts 51 in 36 s, 285 ms
     of silence; the renderer's clicks 0 (largest jump 0.002), so its sound is clean and the static heard is the
     dropouts; the worklet's longest block 2 ms, its longest gap 39 ms - the audio thread went 39 ms without being
     asked for a block: not the renderer's time, the thread not run - and the output's latency 272 ms where it was
     24 ms (a Bluetooth output, or the browser's buffer grown after the underruns). Two readings added to tell the
     causes apart: the worklet's mean block time, over each second (its clock may count whole milliseconds, but the
     mean of 375 blocks is fine-grained; `meanBlockMs` in the stats, `RendererReport.mean_block_ms`), against the
     2.67 ms a block lasts; and the page's own frames on the main thread, timed where the mixer reports each
     (`noteMixer`): the longest gap and the mean over the second (`takeFrameGaps`). Long gaps on both threads at once:
     the device's processors are busy, and the page's drawing is what to lighten; long gaps on the audio thread alone:
     the output's own schedule (a Bluetooth link's bursts) or the system. `audio_page_test.cjs` pins the two lines'
     new format; it and `audio-worklet-test` pass. Also: the failed turn before this had left `sound.zig` with step
     5's `streams` rerouting half done and one of its new tests failing; `sound.zig` was restored to the last green
     snapshot, and the unfinished version kept as `wip/sound_streams_step5.zig.txt` to finish from.
     **The static, thought through before testing more (Oct 13, Simon's third panel).** The panel: 95 "dropouts" in
     84 s, 496 ms; the worklet's mean block 0.077 ms (3% of a block's 2.67 ms), its longest gap 25 ms; the page's frames
     8.3 ms on average, 12.4 at most (a 120 Hz display, no long task); clicks 0; the output latency 272 ms. So the
     renderer is cheap, the main thread is not stalling, and our sound has no clicks. Our blind spots, found by
     reasoning from the design: (1) the dropout detector trusted `getOutputTimestamp` to jitter under 2 ms - its own
     comment said so - and counted every rise, never a fall; an output that reports its position in chunks (a
     Bluetooth link; 272 ms is a Bluetooth latency) makes the offset swing, and every upswing was counted as silence:
     the 95 may be mostly jitter. Fixed: a dropout is a rise above the offset's top, which sinks 0.1 ms a second; the
     line adds the net shift since the start (silence adds to it, jitter cancels) and the largest fall (jitter alone
     makes one) - `audio_page_test.cjs` drives both a real silence and a 5 ms jitter. (2) The detector cannot see a
     glitch the browser hides: if a block arrives late and the browser skips it rather than delaying everything after,
     the timeline never shifts - the static on the phone's speaker, with no dropout counted and the worklet's gaps
     at 5 ms, may be that, or not timing at all. (3) The longest gap was read as starvation; with an output that asks
     in bursts - many blocks at once, then a pause - a gap of a burst's length is normal. (4) The context runs at
     48 000 Hz, forced, whatever the device's rate: a Bluetooth link at 44 100 makes the browser resample, in its
     own path, with its own buffering. (5) The latency hint is the default, "interactive": the smallest buffer, on a
     link whose own latency is 272 ms. (6) Static need not be a timing fault: a dense chord of Shepard tones -
     partials up to 6 kHz - played loud is what a small speaker distorts and a Bluetooth codec at a low bit rate
     smears; the click watch cannot see either. (7) Nothing in our tests runs a real-time device: headless and Node
     have no scheduler, no Bluetooth, no resampler. Next, one session of Simon's to tell them apart: the speaker
     against Bluetooth, the new dropouts line on each; a plain sine against the Shepard chord, at the same level; and
     the same Bluetooth headphones playing another app.
     **The handle leak, found whole: the WebGPU apps' frame loop had no handle scope (Oct 13, Simon's second crash).**
     The same "Invalid array length", now inside a scoped listener: the table was still growing. To reach the limit in
     minutes a page leaks thousands of handles a frame, and only the frame loop runs that often: `ZimrBoot.tick`, the
     loop every WebGPU app runs in, opened no scope - the scoped loop is wz.Site's, which these apps do not use - so
     every bridge call's numbers, strings and results stayed in the table for good, at 120 frames a second. (The
     input listeners' leak fixed earlier was real, and small beside it.) The leak also makes every garbage collection on
     the main thread scan a table of millions of handles, and the device's memory fill - worse the longer a page runs,
     as Simon's dropouts were (51 in 36 s, then 95 in 84 s). Fixed: stage 4 of the tick - the running frame - in
     `js_mark`/`js_reset`. The bridge's comments had assumed frames were scoped, and code had come to rely on the
     leak: handles made the first time a frame needs them and kept for the page's life would dangle a frame later. So
     the runtime gained `js_pin` (c2js's preamble): a reset leaves a pinned handle - the slots below it are freed
     rather than popped - and `js_free` unpins it; with nothing pinned a reset is as before. Pinned where made
     (`Value.keep`): the canvas, its context, the resize observer, the format list, the asset registry, the user-file
     queue, input, save element, save URL and pending name, both text overlays, the default style sheet, the held keys'
     set, the cached `performance` object; in `page_audio.zig` (`kept`) every handle it keeps - the node and the held
     notices made by the app's first frame, the script processor's context, the panel, the shared `undefined`. Checked:
     the runtime's lines run in Node over 10 000 frames of 300 handles, pinning one every 1 000 frames and freeing one -
     every pinned object intact, the table flat between pins (it grows only by a frame's handles at each pin: bounded by
     the pins, a few dozen in a page's life); `audio_page_test.cjs` now starts the output and shows the panel inside a
     frame's scope, then writes 50 handles over the freed slots - passes, and fails with the node unpinned ("Cannot read
     properties of undefined (reading 'postMessage')"); the shipped tick opens and resets the scope; `audio-page-test`,
     `audio-worklet-test`, `c2js-canary` pass. Not testable here: the bridge's pins, in a browser.
     **Handle bugs made easier to find (Oct 13, Simon asked).** The leak hid because nothing watched the table: the
     first sign was the browser's failure, minutes in. (1) A watch in the bridge, on every web page
     (`watchHandleTable`, at each frame's start with the frame's mark): every frame resets the table to where it
     began, so the length at a frame's start is what lives outside frames - boot handles and pins, a few hundred,
     steady - plus whatever a callback outside the frame loop leaked; a rise of 5 000 in 5 s, or a table past 200 000
     (then at each doubling), is written to the page's log (`console.error`, shown on the page), naming the cause - an
     event listener, timer or promise callback without a handle scope - and the cure. (2) The sound's panel shows both
     tables' lengths - the page's, and the worklet's (`handles` in its stats, `js_mark` in the audio thread's realm,
     which no frame resets) - steady on a healthy page: the Node page test shows 29 and 131. (3) The backends
     tutorial's new 13.19, "Handles to JavaScript objects": the table, scopes per frame and per listener, pins, the two
     symmetric mistakes (a callback outside every scope leaks; a stored handle not pinned dangles), and the watch. The
     dangling side has no watch - a stale handle reads a reused slot silently; a generation count in each handle would
     catch it, at the cost of every runtime function's lookup, left for later.
     **The two-hand star: options over the page, volumes, the circle pressable (Oct 13, Simon: "no more glitch").** The
     toolbar is now one button, "options", beside the scale's name; it opens a panel over the whole page
     (`buildOptions`, the engine's UI window, 6% inside the edges): the tonic and mode dropdowns, labelled; the two
     pedals' volumes in place of their checkboxes - 0.4 by default, a bit above the 0.3 they played at, so both pedals
     now sound from the start, 0 silencing one (`Pedal.volume`; a change reaches the playing voice through `setVolume`,
     the mixer ramping its gains over a block); the chooser chord's volume as a share of the notes' strength - 0.3 by
     default, a bit under the 0.375 it was (`State.chooser_chord_volume`, read by `soundStrengthChange`); the audio
     stats box; "close". While the panel is open the fingers play nothing. The circle of the twelve notes is
     pressable: a press within a note and a half's size of one of the scale's notes holds it at full strength, as a
     key (`ChromaticLayout`, shared by the drawing and the touch: `placeOf`, `degreeAt`) - connected to everything,
     the star's note lit with its steps' dots, the keyboard's key, both polygons, the chord's name. Measured headless:
     both pedals on C2 at 0.1871, as expected; E pressed on the circle sounding its partials, lit everywhere. The
     lint's autofix had deleted `letter_names` again, unused for a while; restored with its use.
     **The two-hand star: the chooser in the star's shape, the circle's notes (Oct 13, Simon).** The chooser now lays its
     chords out as the star lays out its notes: on the star's own curve (`starCurveDirection`, flattened at the bottom)
     at the star's turn with nothing chosen, each chord at its root's place - I where 1 is, at the bottom's left, iii
     and V on one line beside it, as the star's 1, 3 and 5; a chord built on a note is where the note is, so the notes
     sounding, joined on the chooser, make the star's shape (C E G: a line through I, iii and V). The curve is fitted to
     the chooser's room on each axis and the chords sized together with it, in three rounds (`ChooserLayout.ofRoom`):
     the radii fit the places' extent and the chords' outer halves; the size is what the closest two places allow for
     two of the largest chords, one of them chosen (a quarter larger, `chosen_chord_scale`), with 10% between; the
     curve's middle, not its centre, at the room's. The buttons are smaller than the circle's were - the row 1, 3, 5
     sets the spacing - but every point of the chooser still belongs to the nearest chord. The circle of the twelve
     notes: a scale note at rest drawn three quarters of its size (`ChromaticLayout.resting_note_scale`), one sounding
     whole; its notes attract as the star's and the chooser's targets do - every point of the circle's part belongs to
     the nearest of the seven by the distance to its shape (`ChromaticLayout.degreeAt`, no reach limit).
     **Two slow handle leaks, both shown by the new panel numbers (Oct 13, Simon: "Handle leak again?").** The page's
     table at 40 201 after three minutes (should be a few hundred: ~215 a second), the worklet's at 662 (starts near
     29: one per message, 627 messages). Below the watch's alarm (5 000 in 5 s), so it stayed quiet. Causes: (1) the
     page: the frame's scope covered stage 4's body only; the request for the next frame, after the switch, minted two
     handles a frame outside it - 240 a second at 120 Hz. Now the whole tick is the scope when running. (2) The runtime
     marked a free slot by `undefined`, so `js_free` refused any handle holding `undefined` - every call to an export
     that returns nothing (`accept_note`, `accept_command`) left a slot neither free nor reused: the worklet's one a
     message. Now a free slot holds `__HFREE`, a marker of its own, a Proxy that throws on use: a handle used after it
     was freed says so ("zimr: a handle used after it was freed") until its slot is reused - half of a dangling-handle
     detector. (3) A third hole, the one the worklet's header warned of: a scope's new handle could take a free slot
     below its mark, beyond its reset - each zero-argument callback after a wrapper's free leaked one. Scopes are now
     airtight: `js_mark` sets the free list aside, `js_reset` gives it back with the slots freed below the mark added;
     inner scopes never reset are folded in. `js_table_length` reads the length without opening a scope (the panel,
     the worklet's stats). The watch now sees slow leaks: 300 in 30 s (ten a second). Checked: the runtime's lines in
     Node over 5 000 frames with events, timers, calls returning nothing and code after the frame - the table flat (259
     to 259), pins intact, a stale handle throwing, undefined handles freed; `audio-worklet-test` now 10 live before
     and after 2 000 blocks and 200 messages (16 before: six slots lost to the old `js_free`); `audio-page-test`,
     `c2js-canary` pass; the shipped tick resets after its request for the next frame. Tutorial 13.19 updated.
     **The worklet's stale handle, found; handle debugging built in (Oct 13, Simon: "find a better way to diagnose").**
     Simon's panel: the renderer worklet failed - "a handle used after it was freed", last turn's marker firing - and
     the page's watch raised its alarm (1 733 handles in 30 s outside frames, ~58 a second). The stale use: the
     runtime's `js_push` returns the array's own handle, and `sendNotices` freed that result - the transfer list itself
     - before posting it, then freed it again by its `defer`. Under the old runtime the freed slot read `undefined`, so
     `postMessage` silently copied the notice bytes instead of transferring them and the second free did nothing; now
     the marker throws when the browser reads the transfer list - at the first notice, a voice ending. Fixed (the
     result ignored, as everywhere else; `js_push` documented as returning the array). The Node worklet test missed it:
     its fake port never read the transfer list; now it does, as a browser does - red with the old free ("zimr: a
     handle used after it was freed"), green with the fix, 10 handles before and after. Diagnosis built in, in the
     c2js runtime, for both realms: (1) handle debugging (`js_set_handle_debugging`, at run time - the scale star's
     options, "debug handles", through `z.audio_device.setHandleDebugging`, `page_audio.setHandleDebugging`, a
     `debugHandles` message to the worklet): each handle's making site recorded (three transpiled frames), each freed
     slot a tombstone throwing with the handle, where made and where freed; `js_handle_census` counts live handles by
     making site - in the leak alarm's message, and in the page's log every ten seconds while debugging. Off: the
     shared marker, no stacks. (2) Always on: the callback wrappers hand an escaping exception to the realm's
     `__zimrOnCallbackError` before it goes on; the worklet sets it to post the failure with its stack. The page test
     now drives the shipped runtime itself: 2 000 scoped frames with events and undefined handles, the table flat; a
     stale handle named with its makers; a leak counted where made. The page's ~58 a second is not found yet: its
     census, with debugging on, will name it. Tutorial 13.19 extended.
     **The page's leak, named by the census (Oct 13).** Simon ran with "debug handles": a sea of glitches - the worklet's
     mean block 4.8 ms, beyond the 2.67 a block lasts: every handle made and freed formatted its stack at once, some
     20 us each (here), twenty handles a block. But the census named the leak: "124 x Promise.resolve.then.__P...",
     the runtime's own promise registry. `js_promise_register` minted the result's handle in the promise's
     continuation - outside every scope - and `js_promise_take` handed that handle to the frame polling for it, whose
     reset never reached it: one handle per promise, and `pollGpuTiming` takes a GPU readback every frame or two -
     the ~58 a second. The registry `__P` also grew by an entry per promise. Fixed in the runtime: the registry keeps
     the settled value, and the handle is made at the take, in the taker's scope (a frame's take reclaimed with the
     frame; boot's takes, outside any scope, kept as before); taken ids are reused, a late settlement of a reused id
     ignored. The census also showed `onCanvasResize` (the ResizeObserver's callback, two arguments) leaking a few
     handles per resize: now in a scope of its own. Debug mode made light: a handle's making site is a bare `Error` -
     the stack captured cheaply, formatted only when a tombstone fires or a census is taken (6.5 us per handle made
     and freed, against 21 us formatting at once, 0.74 us off). The page test drives the shipped runtime through 500
     frames of a promise each, taken in a later frame's scope - the table and registry flat; red with the old promise
     lines ("promises grew the table to 534"). Tutorial 13.19: promises.
     **Clicks: false alarms, clipping, and a limiter (Oct 13, Simon: "clicks 14 (largest jump 0.042)").** With the
     leaks gone - the census, debugging on, held only handles made before it began - the panel's click count was the
     clue left. A test (sixteen-plus notes forcing steals; one key struck again and again) found the renderer's
     steals and re-strikes clean at velocity 0.1 - no click, largest jump 0.003 - but at 0.5 it counted dozens: the
     mix of sixteen notes passed full scale and was cut flat (a corner each time), and a dense, loud, smooth chord
     curves past the fixed 0.02 threshold anyway (false alarms). Three changes. (1) The click watch adapts: a jump
     counts only past 0.02 and past 8 times the root mean square of the channel's recent second differences (a
     running mean over ~5 ms): a step stands out against its sound's own curvature, a dense chord's peaks do not.
     (2) Clipping counted apart: frames that would pass full scale, carried to the panel ("clipped N"). (3) The mix's
     last stage is a limiter then a soft bend (`limitAndBend`, replacing the hard clamp): one gain for both channels,
     aimed at 0.7 over a peak envelope that rises at once and falls over 100 ms, the gain moving over a millisecond
     (no step, no click; no look-ahead, so a sudden peak's first millisecond reaches the bend); then `softClip` -
     untouched to 0.8, a tanh above it toward full scale, value and slope continuous. Tests: steals and re-strikes
     clean; sixteen loud notes clipped-counted and click-free once limited; a sine 1.3 cut flat jumps 0.034 at its
     corners, bent softly curves 0.010 at most - one past the click threshold, one under. The single-star sound check
     unchanged (14 windows): quiet sound never reaches the limiter. The app's mix - right-hand notes at 0.5, the
     thumb's chord, release tails, two pedals at 0.4 - can pass full scale: likely a part of the static heard. (The
     turn doing this stopped mid-test, unanswered; finished in the next.)
     **The two-hand star: the key's window on the circle of fifths (Oct 14, Simon, sound debugging paused).** The
     left hand's column now holds, at its top, the key's window on the circle of fifths' chord wheel (`FifthsLayout`,
     `drawFifths`): seven cells of three rings round a centre below them, each a twelfth of a turn wide - IV, I, V on
     the inner ring (a fifth apart, the subdominant left), ii, iii, vi above, the diminished vii on top, placed by
     degree so every key and mode keeps the shape - each filled in its root's colour (lit when chosen) with its numeral
     over its letters (`chordLetterName`: the root's spelling, then m or the degree sign). Rings one unit thick from a
     unit out: the window's width limits it, so thick rings make the largest cells. A press there chooses the nearest
     cell's chord, as the chooser does (the same target). The circle of the twelve notes moved to a square at the top
     right (15% of the width), the star narrowed by it; the chooser has the column's lower half and fits the star's
     curve by one scale on both axes - its own proportions, not stretched to its room - with 5% between neighbours,
     its buttons closer together. Upright: the band across the top holds the window, the chooser, the circle.
     **The two-hand star: chords toward their roots; the chooser labelled and tighter (Oct 14, Simon).** The star's
     chords sit half a place back from their third's place toward their root's (`chord_shift_toward_root`, through
     `StarLayout.pointAtFractionalPlace`): every chord moves by the same angle, so each ring keeps its spacing, and a
     chord's distance from the notes' ring is its own ring's whatever its angle - no new collision. The chooser is
     sized pair by pair: each pair of places at its two chords' own sizes, the larger of them chosen (a quarter
     larger), with 5% between (`neighbour_margin`) - before, every pair was spaced as two of the largest chords, so
     most gaps were wider than needed; the buttons grew into them. Each button shows its numeral over its letters
     (`chordLetterName`, moved to the vocabulary beside `chordSizeInUnits`). The circle of the twelve notes' square at
     the top right grew from 15% to 20% of the width.
     **The two-hand star: two bulges to the right (Oct 14, Simon: "keep the chord diamonds cleaner").** Each chord is
     drawn with its three notes as two triangles; the notes resting at the far left (6) and the top right (2) made
     those around them long and thin. The curve now bulges right at those two places (`right_bulge_places`,
     `rightBulgeWeight`, added to `starCurveDirection`'s x): a raised cosine of the angle, a place wide either side, so
     the neighbours stay put; 0.14 of the x radius. Like the bottom's warp it belongs to the shape, not to the notes:
     as the star turns, each note passing through a bulge takes it (with V chosen, 3 and 6 rest there). A chord whose
     root stands in a bulge moves 0.3 of a place further toward it (`chord_shift_toward_moved_root`): vi by 6, ii by 2.
     The star is refitted to its room, so the leftmost note's move is partly spread over the others: measured against
     their neighbours, 6 and 2 moved some 25 px of a 1000 px window. The chooser shares the curve, and the shape.
     **Glitches, reviewed in theory (Oct 14, Simon: "continue debugging the glitches, theoretically").** With dropouts
     gone, the worklet healthy and the leaks fixed, the review followed a note from the finger to the speaker. Found
     sound: the pedal's phase (f64, wrapped each frame, its sine and cosine computed from it each frame - no drift over
     minutes); the instrument's (a note held 20 s exact to a millionth, tested); steals and re-strikes click-free
     (tested at velocity 0.1); the mix's last stage (limiter, soft bend). Found in the app - and the panel's 2 765
     notes in 238 s, 11.6 a second, pointed there: (1) no hysteresis - every point belongs to its nearest target, and
     a finger resting near a boundary, moving a pixel or two between touch events, let its note go and struck the next
     many times a second: crackle. Now a hold remembers its anchor and changes target only after the finger moves
     `target_switch_distance` (6 px) from it. (2) The chooser chose at every frame a finger rested on it - a thumb near
     a boundary flipped the chord, each flip turning the star; and the key's window never chose at all (the capture
     read as a choice last round was the sounding chord's curve). Now a chord is chosen when a finger takes it, from
     either (`takeTarget`). (3) While the star turned, fingers on it let go and struck again after - a gap of ~40 ms at
     every chord change. Now they keep their notes through the turn, and when it ends every hold may change at once
     (anchor null) to what is under it. (4) A note going from full to the thumb's strength - the right hand lifting a
     note the chord still holds - was struck again, softer: an attack where a finger lifted. Now it rings on. Checked
     headless: a press on the key window's vi chooses it (the star turned, vi lit in the chooser); a 2 px jitter then a
     130 px slide changes note once. Left: the page posts its command message every frame, empty or not; each block in
     the worklet still mints handles - a block made of none would leave the audio thread no garbage at all.
     **Review (Oct 14, Simon: "review and improve the code again").** The app: the turn's end now frees the holds'
     anchors before the pointers are read, so a finger changes to the note the turn brought under it in the same
     frame, not the next; the three parts' rectangle tests use the engine's `Rectangle.contains`; `isInHeader` names
     the parts' common top (the key window's) rather than the circle's, right only by accident since it moved; a stale
     comment calling the circle silent removed. Checked and sound: `changeScale` clears the holds, so fingers sound
     again with fresh anchors. The runtime: `__Honerror` read a mark on the thrown value before its `try` - a callback
     throwing `null` would have had its error replaced by a TypeError; now a value that is not an object is handed over
     unmarked. The renderer: the limiter counted clipped frames under a name, and a panel line, saying samples - now
     each channel's sample is counted; the click watch compares squares (`jump^2 > 64 x mean square`), the same test
     without a square root per sample. Sound, page and worklet tests pass.
     **The runtime's debug code made readable (Oct 14, Simon).** The handle bookkeeping and debugging added to the c2js
     runtime had been written one function a line, with names like `__Hfreed(v)`. Rewritten one statement a line,
     with names that say what they hold - `__freedSlotMarker`, `__scopeStack`, `__pinnedHandles`,
     `__isDebuggingHandles`, `__errorWhereHandleWasMade`, `__tombstones`, `__describeWhereMade`, `__isFreedSlot`,
     `__markerForFreedSlot`, `__handOverCallbackError`, `__freedPromiseIds`; scope records as `{ mark, outerFreeList }`,
     promise records as `{ state, value }` - and named locals for each step; each function preceded by Zig comments
     explaining it (not emitted: the page carries none of their weight). The table `__H`, its free list `__Hf` and the
     promise table `__P` keep their names, used all through the runtime. Two bugs found on the way: (1) the census
     joined its lines with the two characters backslash and n - the template's `'\\n'`, copied as written into the
     JavaScript - so a census read as one line (Simon's screenshot showed it); now a line break. (2) The stack reader
     skipped the runtime's frames only when named bare ("at __href"); called through an object - "Object.__href [as
     handleOf]" - they counted as the place a handle was made. Now a frame is judged by the function's own name, the
     part after the last dot without an alias. The page test now checks the census line by line, the handles made
     before debugging counted apart, and no runtime function among the places.
     **Step 5 - streams on the mixer, in one memory (Oct 14).** The streams API (`z.streams`) now plays on the engine's
     mixer natively and headless (`plays_on_mixer`, every target but wasm): each stream a ring of 2048 frames in an
     allocation of its own (`RingBox` - its address, which the voice reads by, survives the table being copied), its
     voice a stream voice (`mixer.Stream`) started at its first frames; `isProcessed` asks for more while half the ring
     is free (21 to 43 ms queued); pause pauses the voice, the frames waiting; stop and unload retire the ring - its
     voice fades out over 240 frames still reading it - and free it once the renderer says the voice ended
     (`StreamTable.collectRetired`, `Mixer.isStoppedVoiceStillHeld`: the slot held, the name dead one generation on).
     Ported from the half-finished `wip/sound_streams_step5.zig.txt`; it compiled at once, and its test found an old
     bug: `isValid` read only the handle's shape - a stream was valid after `unload` - now it asks the slot's
     `in_use`. Checked: the four new stream tests (frames played exactly as written; paused frames waiting; the ring
     freed within the next block after unload, nothing leaked; volume, pitch and pan clamped and given to the voice);
     the `audio_stream_synth` example headless, held a second - 622 Hz at exactly 0.3000, its largest second
     difference the sine's own (0.00199): never a break. Left in step 5: the page's script-processor path, where the
     renderer is in the page's memory too, still plays streams through the browser's graph - the choice is made at
     compile time (wasm), not by the output found at run time; with step 6, streams across to the worklet.
     **The glitch hunted in the numbers (Oct 14, Simon: "a strange math error... threads stepping on each other's
     toes. Hunt hard").** Threads: on the page the worklet's message handler and `process` run in turn on one thread,
     and the page reaches it only by messages - no shared memory, so no race; races could only be native (the shared
     queues and rings). Numbers: a soak test plays ten minutes of two-hand use through the real renderer and the real
     Shepard instrument - some twelve events a second, chords changing every one to two seconds at 0.15 with a low
     note held under each (replaced at each change), right-hand strikes at 0.5, half of them on chord notes - every
     sample checked: finite, within full scale, not subnormal, and the renderer's own click count. Ten minutes is 28.8
     million frames, past 2^24, where a frame count kept in an f32 would round. Natively (`test-sound`, ~8 s): nothing
     not finite, past full scale or subnormal, no click, largest jump 0.0075. In WebAssembly, as the phone runs it
     (the worklet test, fed through the port with a new Shepard export, two minutes by default, its minutes an
     argument): the same - largest jump 0.0070 over ten minutes, after two false leads found on the way: (1) the
     test's first stats report carried the clicks of the sections before it, whose test generators start and end
     abruptly on purpose - the session now renders until a report arrives and sets it aside; (2) placed before the
     comparisons with the local renderer, the session left that renderer seven thousand queued notes behind - it now
     runs last, alone, the sine before it stopped (a new stop export). One real fault: the limiter's gain approaches its
     target by a 48th of the gap a frame, and in floating point that stalls once a 48th of the gap is under half a
     unit in the last place - just below 1, 1.4 millionths short - so after the limiter first acted every later sample
     was scaled by 0.9999986, for good: inaudible, but two renderers that should agree no longer did (the worklet test
     caught it). The gain now takes its target within ten millionths (`limiter_gain_snap`). The renderer's arithmetic
     is clean on both platforms: the glitches Simon hears are not made by it - the remaining suspects are the app's
     events (hysteresis and the rest, fixed in the round before, not yet heard on the phone) and the device's output.
     Process: the disk filled (98%; the build cache 8 GB) and zbuild refused to build; the page outputs and the cache's
     scratch were cleared. The turn ran long enough that the app could not show its reply.
     **Frames capped at 60; the queues reviewed; the chooser squished, with a star (Oct 14, Simon).** A browser asks
     for a frame at the display's rate - 120 a second on Simon's phone - and the app drew each one, twice the work of
     60, the audio thread among its neighbours on a phone that heats. `Config.max_frames_per_second` (60 by default,
     null for every frame) and `core.FramePacer` (runtime.zig, beside the frame clock's filter): frames due on a beat
     one period apart, a display frame taken up to 2 ms before its beat, the beat moved on from where it was - so 120
     Hz draws every other frame, 90 Hz two in three, both 60 on average; a frame over a period late restarts the beat
     rather than run missed frames in a burst. Applied in `update` in browser builds only: natively the window's pace
     holds, and a headless script draws exactly the frames it asks for. The lock-free queues
     (`SingleProducerSingleConsumerQueue`) reviewed: release stores after the item, acquire loads before it, each
     side's copy of the other's count only ever behind, wrapping arithmetic for 32-bit counts, one producer and one
     consumer per queue (the input thread's notes a queue of their own) - correct; the test machine's x86 would hide
     an ordering fault anyway, so the review is the check. Found by it: a push refused when a queue is full is
     dropped - `stopVoice` kills the name and sends `stop` regardless, so a refused stop would leave the voice playing
     and its slot held for good; a refused note-off would leave a note hanging. Queues fill when their reader stops -
     a stalled device natively; on the page, audio suspended (another app taking audio focus) while the page draws on.
     To fix next: keep what could not be sent, and send it when there is room. The app: pedals silent by default
     (`default_pedal_volume` 0); the chooser's curve squished to 0.7 of its height (`ChooserLayout.vertical_squish`),
     its rows closer; a seven-pointed star in its middle (`drawChooserStar`) joining the notes in pitch order, each line
     in the colour of the note it leaves, lit while it sounds - a step up in pitch is three places round the circle of
     thirds the chords follow, so the path is the {7/3} star.
     **The left hand's column: one kind of button, one kind of link (Oct 14, Simon).** The star's steps in pitch
     (`drawPitchStep`) now draw through a shared `drawStepDots` - two ends, each a centre, shape, half-size and colour,
     dots flowing from edge to edge (`DotsEnd`). The chooser's star has its corners on the chord buttons themselves
     (each chord standing for its root), its seven steps all flowing, dimmed, and in full colour around each note
     sounding - its step from below and its step above (`drawChooserStar`, `chooserDotsEnd`). The key's window draws
     the chooser's buttons (`drawChordButton`, split from `drawChooserChord`; `columnChordHalfSize`), at the chooser's
     sizes, and around each chord played - all three notes sounding (`isChordSounding`, the app's own) - the steps of
     its root, from the chord a step below and toward the chord a step above (`fifthsDotsEnd`). Its rings are now
     placed for those buttons (`FifthsLayout.ofArea` with the chooser's size unit): the inner ring where its three
     major chords, a twelfth of a turn apart, clear each other with the larger chosen and 5% between; the middle ring
     a major-minor clearance beyond, or as far as its own minors need; the outer ring a minor-diminished clearance
     beyond; the shape centred in its area - the arcs, sized for text, had put neighbours 0.8 of a ring apart. The
     divider between the column and the star removed. Simon's panel also showed 6 dropouts in 138 s, 225 ms of silence
     - with handle debugging on, its census in the log: debugging costs both threads; to be read again with it off.
     **The two-hand star: the chord named by degrees; the key window's shape; 2, ii and IV moved (Oct 14, Simon).** The
     chord sounding is written large in the star's middle, over its curve, by degrees - no note named
     (`degreeNameOfChord`, `drawChordNumeral`): one note its degree (`3`), two their degrees as the curve stacks them
     (`1-5`), a chord its Roman numeral and kind (`numeralNameOf`) - `I`, `ii`, `vii` with the degree sign, `V7`, `ii7`,
     `Imaj7`, vii with a slashed o and 7, `Vsus4`, `Iadd6`, `Iadd9` - else the degrees in scale order (`1-2-4`). The
     letter namer's matching is shared (`matchedChord`, `ChordMatch`): each pattern now says how it reads after a
     numeral (`numeral_suffix`, `has_minor_third`: small letters for a minor third, so `ii7` not `iim7`); a sixth is
     `add6`, since a lone 6 after a numeral means the first inversion in Roman numeral analysis. Checked when
     compiling, as the letter names are: twelve cases, among them the same notes read from two roots (`Isus2`/`Vsus4`,
     `Iadd6`/`vi7`). The key's window joins the sounding notes' chords by a polygon, as the chooser does
     (`drawFifthsPolygon`): its rows put no curve through them, so the corners go in order of angle round their
     centroid, and every sounding polygon is now filled by a fan from the centroid - which covers such a polygon,
     convex or not, exactly. The star: each bulge its own amount (`right_bulges`: 6's 0.14, 2's 0.24); a chord's shift
     toward its root by the place its root rests at (`chord_shift_by_rest_place`, `chordShiftAt`, interpolated by angle
     through turns): 0.5 for most, 0.95 for ii by 2, 0.8 for vi by 6, 0.3 for IV - down and left, toward its third.
     **The two-hand star: wider, vii outside, one column star (Oct 14, Simon).** The top right's bulge to 0.38 (the
     note resting there - 2 as the star rests, 4 with iii chosen - more room for its triangles). The star's room runs
     under the circle's lower part (`star_under_chromatic_share` 0.55), and the circle's square sits a little up and to
     the right of the content's corner (`chromatic_corner_shift` 0.08) - into the top band at the right, which
     `isInHeader` now leaves to the circle. The diminished chord always on the outer ring, whichever side is out: inside,
     its lines to its root, third and fifth - the fifth across the figure - crossed the middle's buttons. The notes'
     names (letter and solfege) half their note's half-size, from 0.42. One column star for the chooser and the key's
     window (`drawColumnStar`, `columnDotsEnd`, the corners passed in): the key's window now always shows it, dimmed,
     lit around sounding notes - and its minor chords' row stands a third further from the majors'
     (`FifthsLayout.minor_row_spread`). The chord's name in the middle at 2.2 note half-sizes, bolder: drawn four times a
     few hundredths of its size apart, which thickens its strokes.
     **The two-hand star: shifts by ring; the side diagrams' chords drawn by role (Oct 14, Simon).** A chord's shift
     toward its root now reads two tables by its root's resting place - one for chords inside, one outside - blended by
     its outward fraction (`chord_shift_inside_by_rest_place`, `..._outside_...`, `chordShiftAt(angle, outward)`,
     `valueAtPlace`): the place-4 lean of 0.95 was meant for ii inside, and pulled any chord outside there - vii with
     vi chosen - far out to the top right. Outside, the chord whose root rests at the right leans 0.85 (down, away from
     the circle above that corner - vi with vii chosen had touched it), the one at the top right 0.5 (between the two
     top notes), IV's place 0.3. The diminished chord sits 0.85 of the way out (`diminished_outward`); tried at 0.7,
     it pressed on its neighbours and the whole star - laid out as large as no two buttons touching allows - shrank by a
     sixth, so 0.85 stays. On the side diagrams (the chooser, the key's window, the circle of the twelve notes) a chord
     played is drawn as the star draws a chord's lines (`drawChordRoleEdges`): from its root a yellow zigzag to its third
     and a cyan dashed line to its fifth, the other edges unoutlined (`drawSoundingPolygon`'s `is_outlined`); notes
     no chord fits keep the plain outline. The disk filled again (the build cache 8.5 GB): cleared, a cold build run
     detached (about four minutes for the page).
     **A progression track on the chooser; scrolling combos (Oct 14, Simon).** The options offer twenty common chord
     progressions (`progressions`, as Nashville numbers - degrees - so each follows the key and the mode; b7 played on
     the scale's own chord on 7, the flat-seven major chord in Mixolydian, Dorian and Aeolian), in a list whose labels
     spell the chords in the current key (`writeProgressionLabels`: `1-4-5-1  C-F-G-C`), with a bpm slider. Chosen,
     the chooser's middle shows its track instead of its star (`drawProgressionTrack`): one chord a bar of four beats,
     looping; each chord appears at the chooser's centre a bar before its turn as a small faint ghost of its button
     (`drawFadedChordButton`) and travels out to its button, growing and filling in, landing on the bar's first beat;
     the chord to play now is ringed, the ring swelling on each beat. The first bar is the first chord's way in. The
     beats are counted frame by frame at the tempo (`advanceProgression`), so a tempo changed carries on smoothly. It
     plays nothing and presses nothing. The engine's combo learned to scroll (`ComboOpts.max_visible_items`,
     `scrollComboList`, `drawComboScrollBar`): at most that many rows, by the wheel or by dragging - a finger - a row
     a row's height; opened scrolled to the item chosen; a thin bar showing the rows' place in the list; a scrolling
     list chooses on release without a drag, a whole list still on the press. Checked headless: the list opened, a
     drag of 80 px scrolled it three rows without choosing, a tap chose 1-6-4-5, the track ran - I's ghost two thirds
     out in the first bar, I ringed and vi's ghost landing in the second. The chords' "vibe" texts of the list Simon
     shared are not copied.
     **Famous progressions, with borrowed chords (Oct 14, Simon).** Thirteen named progressions after the twenty
     common ones, numbered from the relative major as Nashville numbers do for minor-key songs: Canon (1-5-6-3-4-1-4-5),
     Hotel California (6-3-5-2-4-1-2-3), Let It Be, the 12-bar blues, the diatonic circle of fifths, Fly Me to the Moon,
     the Andalusian cadence, the royal road, La Folia, ragtime (3-6-2-5-1), Creep (1-3-4-4), Wonderwall, Smells Like
     Teen Spirit. A progression can borrow chords from outside the scale (`ProgressionBorrowing`: a step and its
     quality - Hotel California's major chords on 3 and 2, Creep's minor 4, ragtime's three secondary dominants as
     major chords); `progressionChord` gives each step's chord, the scale's own unless borrowed. The list names a
     borrowed chord as itself (`Am-E-G-D-F-C-Dm-E`), and the track's ghost shows it - E as a major square, III - on its
     way to the button of the scale's chord on that root, the nearest the chooser has. The list's labels now name the
     progression first (96 bytes of room), and the list is as wide as the panel's row.
     **Borrowed chords, step 1: four more seven-note scales, augmented triads (Oct 14, Simon).** The plan for borrowed
     chords across the app: a scale stays seven notes, a degree may move a semitone - everything reads
     `Scale.semitones`, so one entry changed carries through the star, the chords, the spellings, the keys, the sound
     and the names. Step 1, done: harmonic minor (0 2 3 5 7 8 11), melodic minor (0 2 3 5 7 9 11), harmonic major
     (0 2 4 5 7 8 11) and Phrygian dominant (0 1 4 5 7 8 10) in the mode list (`Mode` a 4-bit enum now; their
     semitones given directly, the modes' still rotations), the list scrolling, seven rows shown. Their raised notes
     bring augmented triads (`ChordQuality.augmented`: a fifth of 8 semitones; numerals with a plus, `III+`; letters
     `C+`; an `augmented` chord pattern; on the major side - its third is major - a square, outside) and two diminished
     ones, which every rule already took by quality. Each scale still has three chords on the major side and four on
     the minor, so the star's rings balance as with the modes. Checked when compiling: every scale on every natural
     tonic spells each degree with at most one accidental (77 cases). Headless, A harmonic minor: G# sol# on the star,
     III+ and V and VI squares, ii and vii diminished and outside, E G# B named V. Found on the way, in the engine's
     combo: a press choosing an item in an open list also pressed whatever widget came after it under the list - the
     tonic's A, chosen over the mode's box, opened the mode list. An open list's press, and a scrolling list's release,
     are now taken from the frame's input. Steps 2 and 3 to come: momentary alterations while a borrowed chord is held,
     and borrowed chords as small buttons beside their roots' chords.
     **Borrowed chords, steps 2 and 3: alterations while held; buttons beside their roots (Oct 14, Simon: "C").** A
     scale carries per-degree alterations (`Scale.alterations`, -1, 0 or +1; `Scale.altered` moves the semitones and
     reads the triads again through `chordsOfSemitones`, split out of `Scale.of`). A borrowed chord asks for its own
     (`alterationsForChord`): its third and fifth moved by the semitone the scale's own are off from the chord's -
     refused past a semitone, or where the note would need a second accidental; checked when compiling (C major: III
     raises G, II raises F, iv lowers A; A Aeolian: V raises G), and that the altered scale's chord on the root is then
     the borrowed one. The state keeps the chosen scale (`chosen_scale`: the layouts follow it, so nothing moves while
     a chord is held - the star's `chordCentre` places a chord by the layout's chord on its root) and the scale
     sounding (`scale`: what plays and is named). `applyAlterations` lets go of each held note whose pitch moves and
     strikes it again at the same strength. The progression's borrowed chords - not the chosen scale's own in this mode -
     each get a small button beside their root's chord on the chooser and on the key's window, toward the diagram's
     middle (`offeredBorrowedChords`, `borrowedButtonCentre`, `ButtonPlace`); a finger on one takes
     `PlayTarget.borrowed_chord`: the root's chord chosen, the scale altered, its notes held at the thumb's strength;
     let go, the alterations lift unless another borrowed chord is held. The track lands a borrowed step on its button.
     An altered note on the star wears a round badge, # or b, and is named as altered (G# sol#). `columnChordHalfSize`
     moved to the layout code, `drawBorrowedButtons` to the drawing code. Checked headless, Hotel California in C: II
     and III buttons beside ii and iii in both diagrams; III held - the star turned to iii, 5 named G# sol# with its
     badge, the middle and the circle naming III and E major, I read as I+ and V as v dim (the altered scale's own); the
     sound G# in every octave measured (0.042, 0.027) and G none (0.000); let go, all back to C major.
     **Full queues, met on both sides (Oct 14).** `RendererHost.acceptCommandBytes` asserted its push: a worklet taking
     messages while no block was asked for (a suspended context) trapped at the 1 025th command - the page's sound gone
     for good - and `acceptNote` dropped past 256 events, a release lost leaving its note on. The renderer is the host's
     own thread's, so a full queue is now applied at once (`Renderer.applyCommands`, `applyNotes`) and the item queued
     after - none dropped, the order kept. The game side's `sendNote` meets a full queue as `sendToRenderer` does its
     commands: forwarding, the backlog forwarded; the renderer on this thread, the events applied here; on an audio
     thread, a wait for room, then a drop with an error. Tests: three queues' worth of commands and notes into a host
     with no block rendered - none refused, no trap, the last volume in force; three queues' worth of notes into a
     mixer on its own thread - each sent.
     **The gate, and step 6a: a host's own stream rings (Oct 14).** The full gate, run detached (a run outlives its
     tool call but not the turn: two runs died silently at a turn's end; a third, its finished steps cached, took
     three minutes): 460 of 463 steps green; `doc-gate` refused `id="handles"` twice in the backends tutorial (3.1 and
     13.19) - 13.19's is `js-handles` now; `doc-folds` found two of the sound tutorial's code blocks stale
     (`processBlock`, `readOutputContinuity`) and regenerated them. A warning, left for Simon: 248 of the WGSL corpus's
     302 fixtures match no live shader (`zig build corpus-refresh` re-pins). Step 6, streams across to the worklet,
     designed: on a page a stream has two rings acting as one queue - the game writes its own as natively; each frame
     the frames written since the last are forwarded, staying in the game's ring; the host writes them into a ring of
     its own, its voice reading it as natively; the host reports each ring's frames read, and only then does the game's
     ring free them - so the game's room keeps its meaning and the host's ring never overflows. 6a, the host's half,
     done: `SourceToStart.forwarded_stream` (a stream by its number, `ForwardedStream`), `RendererCommand.release_stream`,
     `RendererNotice.stream_read` (`StreamRead`: frames read, wrapping, and frames dry), on `RendererHost` a ring per
     number (`stream_rings`, `HostStreamRing`, 4 096 frames - twice the game's), `acceptStreamFrames` (the ring opened at
     its first use; frames past its room lost, never a trap), `acceptCommandBytes` giving a forwarded start its ring's
     address - or, with no memory for one, telling the voice ended at once - and freeing a released ring; `takeNotices`
     adding, after the queued notices, a report for each ring read since its last (made then, never queued). Test: a
     750 Hz sine in two messages, a forwarded start, four blocks - the sine at 0.354, reported read 514 frames (512
     played and the two the interpolation's window takes at the start), none dry, nothing more to report until read
     again, the ring freed when released. The worklet test (Node, wasm): passed, 2 min in 3.3 s, 0 clicks.
     **Step 6b: the game's side of a forwarded stream (Oct 14).** `Mixer.play` forwards a stream by a number now
     instead of refusing it (`freeForwardedStreamId`: refused, said why, where the platform carries no frames yet, a
     ring is larger than the host's 4 096 frames, or all 32 numbers are in use); the start command names it
     (`.forwarded_stream`), and the mixer keeps a record per number (`forwarded_streams`, `ForwardedStreamRecord`: the
     game's ring, the voice, frames forwarded, frames read there). Each forwarding sends, after the frame's commands,
     each stream's frames written since the last (`forwardStreamFrames`: `piecesOfRun`, two pieces when the ring
     wraps) through the platform's new `ForwardingOutput.send_stream_frames` - plain values, optional, null until the
     page's port carries them (6c) - and the frames stay in the game's ring. The host's reports
     (`RendererNotice.stream_read`) move the game's ring on (`acceptStreamRead`: the 32-bit count widened by its change,
     stored as the ring's read position; its dry frames added to the ring's count), so the game's room means what it
     does natively. A forwarded stream's voice ending gives its number up and tells the host to free its ring
     (`releaseForwardedStreamOfSlot`, `release_stream`). Test, a stand-in worklet in the process: 1 024 frames cross with
     the start, the ring still full of them; played there at 0.354; the next frame's report frees 514 frames' room;
     1 536 more, past the ring's end, cross in two pieces and play with no frame missing; stopped - the number given up,
     the host's ring freed the frame after. The five forwarding tests and the worklet test (2 min in 3.4 s, 0 clicks)
     pass.
     **Step 6c, the page's path (Oct 14), first half.** A stream's frames now have a way from the game's module to
     the worklet's instance, beside the samples' own: the platform's `forwardAudioStreamFrames` (`web.zig`'s import
     `js_audio_forward_stream_frames`, filled into `ForwardingOutput.send_stream_frames` where the platform declares it);
     the page's answer (`bridge.zig`'s `jsAudioForwardStreamFrames`, `page_audio.forwardStreamFrames`, exported as
     `page_audio_forward_stream_frames`) posts `{ kind: "stream", streamId, channels, sampleRate, frames }` with the
     copy's buffer handed over; the worklet's program (`acceptStreamFrames`) copies them into the instance's stream
     buffer (`worklet_abi.stream_frames_buffer`, a host ring's worth of stereo - a message never holds more, since the
     game forwards no ring larger than the host's; one that would is dropped rather than thrown on) and calls
     `worklet_abi.accept_stream_frames`, which writes them into the stream's ring. Lint on the way: `std.math` out of the
     new code (`zm.maxInt`; the tests' sines by `sinTurns`). Green: the page, the five forwarding tests, the worklet test
     (2 min in 3.2 s, 0 clicks). Left for the second half: a stream in the worklet test - its main side a forwarding
     mixer whose functions record, not `forwardCommands` through a sink as now, and the `.cjs` reading a stream's
     record; the page's stream table on the mixer (`plays_on_mixer` everywhere) and its browser-graph half deleted;
     the sound tutorial. Until then a page's streams play as before, through the graph.
     **Review of the recent code: six bugs (Oct 14, Simon).** (1) A forwarded stream run dry went unreported: the
     host reported a ring only when its read count moved, and a dry ring reads nothing - now a ring with dry frames is
     reported too. (2) A ring played again - its counts long past zero - was forwarded from frame 0: every frame ever
     written counted unsent, and `piecesOfRun` cut a run longer than the ring, out of bounds. A forwarded stream now
     begins at its ring's read position (`ForwardedStreamRecord.first_frame`), as natively, and the host's counts are
     taken past it. (3) A number is given to a new stream as soon as its voice ends, while the host's last report on
     the old ring may still be on its way: it would have moved the new ring's read position. Each number now counts
     generations (`ForwardedStream.generation`, `forwarded_stream_generations`, `HostStreamRing.generation`,
     `StreamRead.generation` - in the eight bytes the report had); a report of another generation is dropped. (4) The
     same ring forwarded twice would have had two records moving its read position: refused, said why. And a report is
     never taken past what was sent, which would make the ring's room negative. (5) In the two-hand star, letting go of
     one of two borrowed chords held kept the scale altered as the chord let go asked (the other's alterations were
     lost): it now takes another held borrowed chord's (`otherHeldBorrowedChord`). (6) A stalled audio thread - a lost
     device - would have held the game up a million yields (about a second) at every command and note sent: after one
     wait gives up, none waits until a push finds room (`Mixer.has_renderer_stalled`; the two waits now one function,
     `waitForRenderer`; the queue names its element, `Element`). The sound tutorial's paragraph on full queues brought
     up to date (applied or forwarded at once where the renderer is not on an audio thread; the stall). Tests: a starving
     stream's report; the forwarding test replays its ring - only the unread frames cross, under the next generation -
     drops a late report of the generation before, and refuses a second voice on the ring. Green: 14 stream tests, 11
     queue tests, the worklet test, the page, `doc-gate`.
     **A seventh bug: a flood of reports trapped the main side (Oct 14).** `acceptNotices` asserted that the main
     side's notice queue always has room - true while each notice was a slot's end or an id's release, false once a
     forwarded stream reports at every block it reads: 375 messages a second per stream, all taken before the queue
     is read once (`forwardToOtherMemory`), so a hidden page - its frames stopped, its worklet playing on - would trap
     on its return after three seconds. A full queue is now read, its notices applied, before the next is queued; and
     the host reports reads at most every 512 frames, about 11 ms (`stream_report_interval_frames`,
     `frames_since_stream_reports`, counted in `render`) - a dry ring at once. Test: an unstarted main side handed 2 048
     reports takes them all. Found while planning the worklet test's stream case, which moves to the next turn: stream
     frames into the `CommandSink`, so that `forwardCommands` sends everything a forward carries through one sink - the
     real one flushing its batch first, keeping frames after the play that opened their ring - and the test's
     recording sink records them.
     **Step 6c: a stream in the worklet test; an eighth bug (Oct 14).** The worklet test's main side forwards now, as a
     page's does: its output is a stand-in platform whose forwarding functions record each message - a frame's commands
     in one batch, samples, notes, a stream's frames (a fourth kind of record, its rate in the record's last word) - and
     feed the local host, the reference; its forward is the mixer's own (`mixFrame`, `forwardToOtherMemory`), with its
     batching and its order; the notices the Node test copies in are handed over by the platform's `take_notice_bytes`
     at the next frame; the records collect until the Node test takes them, so a frame run to read notices loses none.
     (Folding stream frames into `CommandSink` - last turn's plan - was not needed: the test needed a mixer that
     forwards, and the engine is unchanged.) The stream section: a mono 750 Hz sine in a 2 048-frame ring, played; five
     rounds of eight quanta - 5 120 frames, two and a half rings - each bit for bit with the local host, the worklet's
     reports handed back and the ring refilled from the room they return (1 022 frames or more a round); stopped, its
     end read, its ring's release one command. The test found the eighth bug: the worklet program's `callExport`
     handled at most three arguments, `accept_stream_frames` takes four, and the fourth fell into `else =>
     unreachable` - a page's worklet would have trapped at its first stream frames. `js_call4` declared, a fourth case
     added, the fallback a panic that says the limit. Left of 6c: the page's stream table on the mixer, its
     browser-graph half deleted; the sound tutorial.
     **Step 6 done: a page's streams on the mixer (Oct 14).** The stream table has one path now: `plays_on_mixer`
     gone, with every function's browser-graph half and the entry's graph fields (its context, play head, look-ahead,
     the recycle ring of buffers); `load`, `update` and `isProcessed` take their mixer helpers' bodies,
     `continueOnMixer` is `continueStream`, the three tests that skipped on wasm skip no more. On a page the mixer
     forwards each stream (steps 6a-6c). The `web.audio` functions the graph halves called stay: music and the sounds'
     older calls still use them until step 7. A scripted edit first matched functions of the same names in an earlier
     struct of the file - the first `pub fn unload(` found - and was undone from the snapshot and redone confined to the
     stream table. Checked: the 14 stream tests; the page and the `audio_stream_synth` page build; the synth headless,
     held a second - 850 Hz (its window 800 tall), level exactly 0.3000, largest second difference 0.0037, the sine's own;
     the worklet test with its stream. The sound tutorial: 2.2 keeps a stream's basics, with a sketch of the ring's two
     positions, and points to 2.6 "Streams on a page" - the forwarding, its two rings, the reports, the generation; 2.7
     "Music and the analyser", the two left on the graph. The device's comments on the older layer's context name only
     music now.
     **Step 7 designed: Vorbis in Zig (Oct 14, Simon shared stb_vorbis.c and minivorbis - libogg 1.3.4 and libvorbis
     1.3.7 in one header, the decoder and the encoder's core, not `vorbisenc`).** Studied: stb_vorbis's shape is the
     guide - Ogg pages and packets (its `start_page`, `next_segment`, `get8_packet`), codebooks (codewords assigned by
     the spec's first-free rule, `compute_codewords`; a 10-bit fast table and a sorted search for longer codes; vector
     tables by `lookup1_values` and `float32_unpack`), the three headers (`start_decoder`), an audio packet (mode and
     windows; floor 1 read as points, each predicted from its neighbours and corrected, the curve drawn after the
     residues - deferred; channels with no floor silent unless coupled; residues 0, 1, 2 by classification passes;
     inverse coupling, magnitude and angle; floor times residue; inverse MDCT), the overlap-add (`vorbis_finish_frame`:
     the left half added to the last block's saved right half under the window sin(pi/2 sin^2), the right half saved;
     the first block gives none; the last page's granule trims the end). It refuses floor 0 - nothing since libvorbis
     1.0 makes it - and so will zimr, saying why. libvorbis (minivorbis) is the reference for the spec's corners. The
     sample: `assets/sample.ogg`, stereo 44 100 Hz, 320 kbit/s, blocks 256 and 2048, 96 s, 97 pages; `codecs.audio.ogg`
     today only sniffs a file's rate, channels and length.
     The plan. The decoder in `codecs.zig` (`codecs.audio.vorbis`, beside `ogg`), written from the Vorbis I
     specification with stb_vorbis's structure as the guide; the inverse MDCT in zimrnum (`imdct`: an N-point inverse
     MDCT through one complex FFT of N/4 points with a twiddle before and after - zimrnum's `fft` - checked element by
     element against its O(N^2) definition, as `fft` is against `dft`). In steps, each tested:
       7a. Ogg: pages (capture pattern, header, CRC-32 of polynomial 0x04c11db7, segment table) and packets - lacing,
           packets across pages - over a file in memory, as music loads. Test: the sample's 97 pages, every CRC, its
           three header packets.
       7b. Vorbis headers: a bit reader (least significant bit first); identification, comment, setup - codebooks
           (lengths ordered, sparse or full; codewords; lookup types 1 and 2), floors (1; 0 refused), residues (0, 1,
           2), mappings (coupling, submaps), modes. Test: the sample's setup read, each codebook's codewords complete
           (Kraft's sum one, or a single entry).
       7c. Audio packets and overlap-add, to samples. Test: the sample decoded whole, compared sample by sample with
           stb_vorbis - built by zig's C compiler in the test step, the one check that is not a decoder against itself
           - within a few units in the last place; and continuity: no jump at block edges past the signal's own.
       7d. Music on the mixer: `z.music` decodes ahead into a stream (2.6), a few packets a frame as its ring has
           room, the stream voice converting 44 100 Hz to the mixer's rate; looping from the first audio packet;
           volume, pitch, pan, pause as a stream's; the example `music_streaming` checked headless.
       7e. Seeking (bisection over pages by granule position, as stb's `seek_to_sample_coarse`), then the older
           browser-graph layer deleted - music was its last user but for the analyser, which needs a home of its own on
           the mixer first (a tap on the rendered output).
     **Step 7a: Ogg pages and packets (Oct 14; Simon: "use zig, zimrnum, zimrmath idiomatically... the best possible
     order. Review as you go").** The order: 7a, then the inverse MDCT in zimrnum with its tutorial, 7b, 7c, 7d, 7e.
     `codecs.zig` is a fast test root now (`zig build test-codecs`: every root imported it already). In
     `codecs.audio.ogg`: the page layout drawn in a comment; `Page`, `readPage` (checked against its checksum:
     `PageCrc`, std's `crc.Generic` with Ogg's parameters - polynomial 0x04c11db7, from zero, unreflected, nothing
     xored, none of the catalogue's - over the page in three runs, its own field as zeros); `Packet` (its bytes in
     place, or gathered where it spans pages; its page's granule position when it is the last ending there; whether it
     ends the stream); `PacketReader` (one logical stream, the first; others' pages passed over; damaged pages and
     bytes that are no page skipped and counted, the next "OggS" sought; `seekToPage` for loops and seeks). A file-scope
     `readInt` alias, the JPEG struct's own dropped. Review found a bug, fixed and shown failing without the fix: a
     packet gathered across pages went on past a skipped page - a hole in its middle, handed to the decoder; a page
     skipped, or missing from the sequence numbers (`next_sequence_number`), now drops the gathered packet, and the
     rest of it on the next page is passed over. Tests: every page of the sample (97, every checksum, covering the file,
     sequence numbers in order, the last at granule 4 236 528); its packets (the headers 1, 3, 5 with "vorbis", every
     sound packet's first bit 0, granule positions rising to 4 236 528 with the last packet); hand-made pages (a
     255-byte packet ending with a 0 segment; a packet across two pages gathered); a packet across a lost page dropped
     whole, the page damaged or missing; a damaged sample page skipped, the packets after counted exactly. Noted for
     7c: a packet may be empty (a single segment of 0), and decodes to nothing; the sample's packets never span pages,
     so only the hand-made pages test gathering.
     **Step 7, the inverse MDCT in zimrnum (Oct 14).** `imdctDirect` - the definition, O(N^2), any N, its phase kept
     exact as the integer (2t + 1 + N)(2k + 1) modulo 8N over 8N, where a float product near 2N^2 would have lost its
     fraction - and `imdct`: N a power of two, a DCT-IV unfolded into the 2N samples (out[t] = Y[t + N/2] for the first
     quarter, -Y[3N/2 - 1 - t] for the middle half, -Y[t - 3N/2] for the last quarter: `writeImdctOutput` writes each Y
     to its two places), the DCT-IV through one complex `fft` of N/2 points (packed X[2j] + i X[N-1-2j], turned by
     e^(-i pi (4j+1)/4N), transformed, turned by e^(-i pi j/N); Y[2j] the real part, Y[N-1-2j] the imaginary negated) -
     verified numerically first (to 3e-11 at N = 1024 in doubles), the caller giving the scratch, nothing allocated.
     Unscaled, as `fft`: stb_vorbis notes its own output "1/2 too small, and compensated"; Vorbis's scale is the
     decoder's, found against stb's samples in 7c. zimrnum's scalar turns are `scalarSinTurns`/`scalarCosTurns` (its
     `sinTurns`/`cosTurns` are the tensor operations). `fft` improved on the way: its stages computed each twiddle once
     per block - the loops swapped, each is computed once per stage, the results bit for bit the same. Test: the fast
     transform against the definition at every power of two from 2 to 1024 (f64, 1e-10 N), at 1024 in f32; four
     overlapping blocks of a random signal, sine-windowed, forward by the definition and back by `imdct`, give the
     signal back times N/2 wherever two meet. The zimrnum tutorial's 13.4 "The inverse MDCT": the overlapping blocks
     and their aliasing drawn, the definition, the worked example at N = 2 (each half's symmetry), the window's
     condition, the unfolding (N = 4 written out), the FFT route. A mistake on the way, undone: the section's fold block
     was written by hand without the generator's end marker (`</div><!--/zn-source-->`), and `zimrnum-ref`, filling it,
     ran on to the next marker and swallowed chapter 14's heading and first example - the page restored from the
     snapshot, the section written with an empty marked block, and the folds and reference rows left to `zimrnum-ref`
     (notes for the two in `tools/zimrnum_ref.zig`). `doc-folds` regenerated one of the sound tutorial's blocks, its
     source changed by the streams' work. Green: the imdct, fft and convolution tests, the reference table's test, the
     lint and format check, `doc-gate`.
     **Step 7b: the Vorbis headers (Oct 14).** `codecs.audio.vorbis`, after `ogg`: a bit reader (least significant
     bit first; zeros past the end, remembered - a header so read is truncated, a sound packet ends there);
     `bitLength` (the spec's ilog), `unpackFloat` (21-bit mantissa, 10-bit exponent biased by 788, computed in doubles),
     `lookup1Values` (the lattice's side by halving in saturating integers - exact, no logarithm to correct);
     `readIdentification` (version 0, channels and rate not 0, block sizes 64 to 8192 in order, the framing bit);
     the comment header (vendor and tags copied into the arena); codebooks (`readCodebook`: sync, dimensions,
     entries; lengths ordered, sparse or full; `assignCodewords` by the spec's first-free rule - one free node a depth,
     the spec's own example as its test, an over-filled tree refused; lookups 1 and 2 unpacked into each entry's
     vector, cumulative where flagged; at most 2^20 entries and 2^22 vector values, where encoders write 2^16 -
     bounding the allocation a damaged header could ask); floor 1 (partitions, classes, subclass books, multiplier,
     its points' X list - at most 65, unique - sorted, each point's low and high neighbours among those before it);
     floor 0 refused (`UnsupportedFloor0`); residues 0-2 (range, partition size, classifications, classbook, the
     8-pass cascade of books, each with a lookup); mappings (submaps, coupling steps - distinct channels in range -
     each channel's submap, each submap's floor and residue); modes; every index checked against its table.
     `readHeaders` reads the three packets into one arena (`Headers`, freed together). Tests: the bit order and
     zeros past the end; the float format (1.0, -1.0, 0.5), lattice sides, bit lengths; the spec's codeword example,
     a sparse code, an over-filled tree; the sample's headers against what stb_vorbis reads (built once by zig cc to
     print them: Lavf58.29.100, one comment, 44 codebooks - 15 with lookups, 625 entries and 4 dimensions at most -
     floors of 19 and 29 points, residues of type 2 to 256 and 2048 (type 2 counts both channels), two mappings
     coupling channel 0 as magnitude and 1 as angle, a short mode and a long), every code filling its tree; each
     floor's points ordered and their neighbours right. Found on the way: the new struct's tests were never run - a
     nested struct's tests run only if it is referenced (`audio`'s comptime block now names `vorbis`), and its code
     was not compiled until then either. Lint: `std.math.mul` replaced by `@mulWithOverflow`; locals named `length`
     and `floor` - zimrmath's names - renamed. Noted for 7c: the bit reader reads a run at a time, fine for headers -
     sound packets want an accumulator and a Huffman table; libvorbis decodes a single-entry codebook specially; a
     codeword no entry has, in damaged data, ends the packet. All 160 of `codecs.zig`'s tests pass (5 skipped, as
     before).
     **Assertions in `codecs.zig`, as zimr writes them (Oct 14, Simon: "look at how we use assertf... do the same in
     codecs").** zimrmath's rules: `assertf(ok, @src(), fmt, args)` the canonical assert, its message naming the
     subsystem and the values (as the robot files write it: "srbd: state is {d}, want {d}"); `assert` only where the
     condition explains itself; `assertUnreachable` for a bare `unreachable`, `panicf` where a value is wanted; and
     above all: in a ship build an assert is a promise to the optimizer - one a file's bytes can break is undefined
     behaviour. So a codec asserts the program's invariants only, and handles its input. `codecs.zig` reviewed, all 41
     asserts and 8 bare `unreachable`s: the TrueType/CFF port (from stb_truetype, which asserts freely) asserted on
     font data - now handled: `load` refuses a loca format past 1 (`InvalidLocaFormat`), `glyfOffset` a glyph past the
     count (`GlyphNotFound`); CFF `seek` kept its clamp and lost the assert that, in a ship build, let the clamp be
     optimized away; `skip` saturates; `get` reads an offset size outside 1 to 4 as 0; `cffGetIndex` and
     `cffIndexGet` give an empty index or entry for a bad size or an entry past the count, their arithmetic widened
     (`offsize * count` had been 16-bit, `count + 1` overflowed at 65 535) or saturated (`end - start`). The
     rasterizer's invariants, the kerning functions' table checks (their callers test first), the operand byte (its
     loop tests first), the UTF-8 decoder's state, the retargeter's parent order and the vorbis code's two: `assertf`
     with their values. The PNG switch's validated default: `assertUnreachable`; the borrowed wave's allocator stubs:
     `panicf` (three return values) and `assertUnreachable` (free); `bvh_findJoint`'s missing name: `panicf`, naming
     it. File-scope aliases (`assertf`, `assertUnreachable`, `panicf`), the four local `assert`s gone. A test of the
     damaged CFF index (offset size 7; an entry past its count; offsets backwards; a 0-byte read) - each would have
     tripped an assert before. The same in this session's `sound.zig` work: the renderer's untranslated forwarded
     stream `panicf`, the fade's `.none` `assertUnreachable`, the full queues' and notices' pushes and the stream ring's
     number `assertf`; `audio_worklet.zig` imports no zimrmath and keeps its `@panic`. Left as they were: `sound.zig`'s
     older plain asserts, `ui.zig`'s 254 bare `unreachable`s. Green: codecs 161 tests (5 skipped), the stream and queue
     tests, the worklet test, the page, `check` (the sound tutorial's fold regenerated), lint and format.
     **The progression track follows the player (Oct 14, Simon: "the next chord waits until the player touches the
     button... touching before the time, the new chord starts immediately... to follow unsynchronized external
     music").** A checkbox under the bpm slider, "wait for the player" (`progression_waits_for_player`). The timeline is
     still one beat count; the track counts the chords played in order (`progression_chords_taken`). Following, the
     beat may not pass the arrival of the first chord not yet played (`progressionArrivalBeat`): it holds a millionth of
     a beat short (`progression_hold_beats`), so the chord stays the one on its way, drawn at its button. Played - from
     the chooser, the key's window, the star or a borrowed chord's button, matched on root and quality against the
     chosen scale, so a borrowed step wants its own button (`takeProgressionChord`, called by `takeTarget`) - the beat
     jumps to its arrival: early, the chord starts at once; waiting, it goes on; either way the next sets out. Ticked
     on, the count starts from the chord on its way; a new progression resets it. A chord waiting pulses twice a second
     on the clock - the beats are held - and is ringed. Checked headless, 1-6-4-5: two and a half bars after the start,
     I held at its button, ringed, nothing else moving; I touched - I to play, vi setting out; vi touched a beat later,
     three before its time - vi to play at once, IV setting out.
     **An old browser told what it lacks, not a syntax error (Oct 14, Simon's iPad: "BRIDGE PAGE ERROR SyntaxError: No
     identifiers allowed directly after numeric literal ... :177").** The c2js runtime writes 64-bit integers as BigInt
     literals (`32n`, `0xFFFFFFFFn`: 357 in the scale star's page, the first in `__clz`, two lines after `__panic` -
     line 177 of a slightly older build); Safari before 14 cannot parse one, and stops the whole main script with exactly
     that message. Such a browser cannot run zimr at all - BigInt itself came with Safari 14 (`BigInt64Array` with 15),
     AudioWorklet with 14.1, WebGPU on by default with 26 - so the fix is the page saying so. c2js's page now checks, in
     plain old JavaScript, before the main script: WebAssembly, BigInt and `BigInt64Array` (`window.__wzMissing`); the main
     script waits under `type="text/x-zimr-main"` (`id="__wzmain"`), which no browser parses, inline or as a `data-src`
     for the served pages' shared `zimr.js`; a loader after it either reports what is missing - adding WebGPU if it is
     missing too - and which browsers run zimr pages (Chrome 113, Safari 26, Firefox 141), or puts the main script into a
     script the browser runs (inline at once; external, `start()` on its `onload`) and calls `start()` once the page is
     loaded, as before. WebGPU alone is still the bridge's to report (a page without wasm needs none). Checked in Node on
     the built pages' own scripts, stand-ins for the main script: with BigInt, the main script inserted and `start()`
     run; with BigInt hidden, the main script - a BigInt literal in it - never parsed, and the panel naming BigInt and
     WebGPU; the served page fetching `../zimr.js` and starting only on its load. The scale star and the stream synth,
     standalone and served, built; lint and `check` green.
     **The songs' keys in the progression list (Oct 14, Simon: "indicate in the dropdown the original version
     tonality, so it is easy to follow the song with the correct tone").** `Progression.original_key: ?SongKey` - the
     version where there are several (Sinatra's 1964 "Fly Me to the Moon"; Corelli's La Folia), the key as named, and
     the tonic to choose in Ionian: the numbers count from the relative major, as Nashville numbers do, so a minor
     song's scale is its relative major (Hotel California: B minor, as D Ionian - B Aeolian would give other chords).
     `writeSongKey` writes it after the name: "(D major)" where the tonic is the key's own, "(B minor, as D Ionian)"
     where not. The keys: Canon D major; Hotel California B minor; Let It Be C major; Fly Me to the Moon (Sinatra) C major
     (key detection gives A minor - the 1954 song was in A-flat); La Folia (Corelli) D minor, as F; Creep G major;
     Wonderwall F# minor, as A (capo 2 on E minor shapes); Smells Like Teen Spirit F minor, as A-flat - a tonic the list
     of naturals does not offer. The forms (blues, circle of fifths, Andalusian cadence, royal road, ragtime, the twenty
     common progressions) have none. Checked headless: the list's end in C; and in D, Hotel California's label lists
     Bm-F#-A-E-G-D-Em-F# and Canon's D-A-Bm-F#m-G-D-G-A - the recordings' chords.
     **Fullscreen on iPhone and iPad (Oct 14, Simon: "the fullscreen button does not work on Safari iPhone and iPad
     even recent versions").** Found: iPhone Safari has no element Fullscreen API on any version - a video alone goes
     fullscreen; WebKit's bug 212934 (non-video fullscreen on iPhone) was closed WONTFIX in January 2026 - so no button
     can work there; iPad has it since 12 (prefixed) and 16.4 (unprefixed), and the page's button swallowed every error
     (`catch(e){}`), so why it fails on Simon's iPad was invisible. Done: the page's head (c2js) - `viewport-fit=cover`,
     `apple-mobile-web-app-capable` (and Android's `mobile-web-app-capable`), `apple-mobile-web-app-status-bar-style`
     `black-translucent`: added to the Home Screen and opened from its icon, a page runs as a web app without the
     browser's bars (since iOS 26 every page so added). The canvas (bridge) fills the screen's safe area - its CSS box
     at the insets' corner, its size the viewport's less the insets, the height `100dvh`, after whole-window fallbacks
     for browsers without `env()` or `dvh`; pointer positions are measured from the canvas's rectangle, so they hold.
     The `[ ]` button sits inside the safe area; hides when the page runs as a web app (`navigator.standalone`,
     `display-mode: standalone/fullscreen`); where the API is missing, a tap shows a hint - in a frame, to open the page
     on its own; elsewhere (iPhone), to add it to the Home Screen; a refusal - a rejected promise, or the prefixed
     API's `webkitfullscreenerror` - is shown with its reason and logged. The engine's `z.requestFullscreen`: the
     prefixed request, exit and element as fallbacks, `webkitfullscreenchange` heard, every refusal logged with its
     reason. Checked in Node: the button's script in eight simulated browsers (iPhone; iPhone and Android as web apps;
     a frame; Chrome entering and leaving; an iPad refusing by promise and by the prefixed event); the engine's toggle
     run from its Zig string pieces through `new Function` (request, exit, the iPhone note, a refusal logged, the
     prefixed request). The backends tutorial's 13.8 gains the browser's side, with a sketch of the safe area. Lint,
     `check`, doc gate green. Waiting on Simon: the button's message on his iPad.
     **The track's ring on a borrowed chord; following the player by default (Oct 14, Simon's screenshot: Hotel
     California in D, the ring round iii F#m while the track asked for III F#).** The ring for the chord to play took
     the sounding scale's chord on the step's degree (`s.scale.chords[degree - 1]`) and its place on the chooser - the
     scale's own chord, never the borrowed one, while the arriving chord, drawn beside it, already landed on the
     borrowed chord's small button. Now one rule places the track's chord, `progressionChordButton` - a borrowed chord
     on its small button (`chooserBorrowedButton`), any other on its root's chord at its drawn size - used by the
     arriving chord, its waiting ring and the ring of the chord to play, which takes the button's own size and the
     chord's shape. "wait for the player" is on at the start (`progression_waits_for_player = true`). Checked headless,
     Creep in C (C-E-F-Fm): the box ticked unasked; I waiting at its button; I played, then the borrowed III - the ring
     round III's small button, F setting out. Still as designed, and asked of Simon: a borrowed chord chooses its root's
     chord (the star turns to it) and alters the scale only while held - after a tap, iii stays lit and the scale is the
     key's own again.
     **A song chosen sets its key (Oct 14, Simon: "switch to the recommended scale automatically when available, like
     D Ionian for Hotel California, when choosing this progression. But after that let the user change it").** In the
     options, the track's dropdown changing to a song with a key whose tonic is offered (`songKeyTonicLetter`: the
     seven naturals; null for Teen Spirit's A-flat) sets `picked_scale` to that tonic in Ionian - applied with the rest
     of the panel's picks by `changeScale`, so a hand-picked scale and this one go the same way (held notes let go, the
     layouts made again, the labels in the new key the next frame). Nothing holds the scale afterwards. Checked
     headless: Hotel California chosen - D Ionian, its label Bm-F#-A-E-G-D-Em-F#; the tonic then set to E by hand - E
     Ionian, the song still chosen, C#m-G#-B-F#-A-E-F#m-G#; Smells Like Teen Spirit chosen - the scale stays E.
     **Larger left diagrams, named keys, the track playing its chords (Oct 14, Simon: chord names 40% bigger and
     buttons 20% bigger on the left diagrams; names and numbers on the bottom notes; a checkbox to trigger the chord
     buttons automatically, so the player can play melodies on the star).** The chooser's buttons were already as large
     as its spacing allows (`ofRoom`: the closest places, one chosen a quarter larger, 5% between) - so the column
     grows instead: `chooser_share` 0.21 to 0.252, measured at the phone's proportions (900 by 415 - the size unit
     17.27 to 20.55, +19%; at 0.30 only 20.66, the height then the limit); the key's window takes the chooser's unit,
     so both grow. `drawChordButton`'s numeral at 0.7 of the half-size (was 0.6) and its letters at 0.525 (0.45) - 40%
     larger in all - the lines at -0.27 and +0.45, inside a circle's narrower top and bottom. The keyboard's long keys
     named as the buttons: the degree's number above, the note's name below (`Scale.noteName`, so an altered note shows
     as altered), in each key's middle, which the short keys leave clear; dark on a key sounding. "play the chords":
     `playProgressionChords`, each frame, makes what the track holds what is due (`dueProgressionChordCount` -
     following the player, the awaited chord once at its button; otherwise the chords arrived): nothing with the track
     off, the box unticked or the first bar not over; the due chord, struck afresh at each (a chord repeated over bars
     sounds at each, and counts as played when following), as a finger holds its button - the chooser's, or a borrowed
     chord's small one - through a pointer slot of its own (`progression_player_pointer_id`, a twelfth slot), which
     `readPointers` leaves alone: its chord lights its button, alters the scale while held, and is let go by a scale
     change, after which it is played again. The options only set the box; nothing else knows of it. Checked headless:
     the window (larger buttons and names, keys "1 C" to "1 C"); Creep chosen (G Ionian with it), the box ticked - after
     the first bar, G played by the track (1, 3, 5 lit on the star and the keys, I ringed and lit); a bar later, B
     major, borrowed (5 shown as D#, its key renamed and its short key gone; the III button lit and ringed; "B major" on
     the circle).
     **The left diagrams boxed and fitted; the star moved; the 2 and 4 proxies (Oct 14, Simon's screenshot: the two
     left diagrams overlapping).** The overlap was the last turn's doing: the key's window takes the chooser's unit, so
     its buttons grew with the chooser's and its shape - only centred, never fitted - ran out of its half of the column.
     The key's window (`FifthsLayout`) is now a `Geometry` per size unit, made from the scale's chords at their own
     sizes (`chordSizeInUnits` - vi is a main chord in a major key) and pairwise clearances (`clearance`: the larger
     chosen, 5% between): the inner ring by its majors; the minor ring's middle by iii over I; its side cells over IV and
     V (`minor_side_turns`, at least the angle that clears iii; the ring moved out until they clear the majors) - so
     the minors are no wider than the majors, as asked; the outer ring by vii over iii, moved out if it would not clear
     ii and vi. `largestSizeUnit` fits the shape in its area; the shared unit is the smaller of the chooser's and that.
     Both diagrams have a thin box (3 pixels inside their parts, the star's note path's color) and are laid out 5
     pixels inside them. Measured at the phone's proportions (900 by 415): ring-sized clearances and 8 pixels gave the
     two units 18.57 and 17.07; pairwise, in balance at half the column each: 18.57/18.54 at 8 pixels, 19.35/19.32 at 5 -
     19.3, +12% on the original 17.3; the 20.5 of the last turn was only had by overlapping. The star 4% of the width
     further from the column (`star_gap_share`). Proxies (`NoteProxy`): the notes between the chosen chord's - the root's
     next and the third's next, the 2 and 4 with I chosen, 7 and 2 with vi - drawn halfway between the bottom line's
     notes, 30% of their notes' size, in their shapes and colors at alpha 150, a faint edge, no name, brighter while
     sounding; a touch within 1.8 times their half-size plays the note itself (`.note`), before the nearest-note
     search, so sliding along the line plays 1 2 3 4 5. Checked headless at 900 by 415 (fitted, no overlap; the 2's
     proxy held - D lit on the star, circle and keys; vi chosen - proxies 7 and 2) and at 1000 by 560 (C Ionian, B
     Aeolian - the 4's proxy a circle, as its note is there).
     **The star's chords as triplets (Oct 14, Simon: "the chords buttons will be drawn as three overlapping buttons...
     the V text twice as big... same for all chord buttons on this diagram, so they look like little triplet
     shapes").** `ChordTriplet`: in front, at the left, the chord's own shape in its root's color with its numeral; a
     third of the width to the right and behind, its third in that note's shape and color; as far again, its fifth -
     each two thirds hidden by the one before, all the chord's size, the third at the chord's centre, so the triplet
     takes the single button's place. The numeral at 1.4 times the half-size (was 0.7), smaller where a long one would
     not fit within 90% of the shape's width (`fittedTextSize`: vii). A touch measures to the nearest of the three
     shapes (`ChordTriplet.distanceTo`, in `nearestTarget`), so any part of a triplet plays its chord. Drawn fifth, third,
     then the front, after the notes. (Simon named the fifth of V "yellow"; D, the 2, is the app's brown - each note
     behind takes its own color.) Checked headless at 900 by 415: every chord a triplet - V cyan with B's purple and D's
     brown behind, I red with E and G, vi blue with C and E; a touch on V's brown crescent plays V.
     **The track chooses, silently; the stuck notes explained (Oct 14, Simon: "we dont want the autoplay to cause sound,
     we just want it to rotate the diagram... my notes get stuck when i play on the main diagram while the track is in
     autoplay").** The stuck notes, found by reproducing Simon's case - La Folia in F (its song key), "play the chords"
     on, a finger tapping across the star through eight chords, A major twice: the old track held each chord with its
     own pointer at the thumb's strength, so a note of the chord a finger played and lifted fell back to the thumb's
     strength and rang on until the chord changed - no hold count left over (the end showed the chord's three notes
     only), but heard as a stuck note. Now the track holds nothing: `playProgressionChords` chooses each chord as it
     falls due (`chooseChord`: the star turns, nothing sounds), applies a borrowed chord's alterations - so a melody over
     A major in F has C sharp - and puts them back when the next chord is the scale's own, when the box is unticked or
     the track turned off (`restoreTrackAlterations`, `has_track_altered_scale`; a finger holding a borrowed chord keeps
     its own); following the player, the chord counts as played. The track's pointer, its slot and `readPointers`'
     exception are gone. Checked headless by the same run: the old code still sounding at the end (rms 0.144 - V held by
     the track); the new, silent in its last quarter second (rms 0, peak 0), the taps sounding throughout (rms 0.125),
     nothing lit, the star on V, the scale F Ionian again.
     **Sharp tonics; the star larger; the circle of thirds white; the options panel smaller (Oct 14, Simon: "tonic list
     can gain sharps. Expand a bit the main diagram towards the top and to the right... a thick white line on the links
     between the notes of the circle of thirds... make [the options panel] a bit smaller, and close it when tapping
     outside").** Sharps: `Scale.tonic_accidental` (0 or 1), `ofTonic` (`of` the natural shorthand), `tonicPitchClass`
     for pitches and MIDI keys; spellings of five states, double flat to double sharp (`spelled_note_names`,
     `spelled_solfege_names`, `spellingOf`, `alterationsForChord`); the comptime check over the twelve listed tonics -
     at most one accidental on a natural tonic, two on a sharp one; the tonic list A to G# (`listed_tonics`,
     `ListedTonic`, seven visible, scrolling); the header the chosen scale's tonic spelled (`noteName(1)` - not the
     sounding scale's, which a borrowed chord may alter); Teen Spirit's key "F minor, as G# Ionian" (`songKeyTonic`),
     its seventh F##. The star: the header only as wide as its text (`header_content_right`, measured from the UI's
     last item, plus `header_padding`), and the star's room up to the window's top margin wherever that text ends
     before the star's left edge - a long name keeps it below the header line; the layout's cache keyed by the
     header's edge too; under the circle 0.45 of its side, was 0.55. The note path (`drawNotePath`): the notes'
     outline color, 1.4 times their stroke (`note_path_thickness_share`). The panel: along the left, 70% of the width
     (at least 460, no wider than the window allows), its height as before; a press outside it closes it - not on the
     header's button, nor while a list is open - and the panel keeps the pointers that frame, so that the finger plays
     nothing (`isPointInRectangle`). Checked headless at 900 by 415: the star larger and higher, the header ending at
     183, the white circle of thirds; the panel at 630 wide, scrolling; a tap on the star beside it - closed, nothing
     lit with the finger down; the tonic list A to D#, scrolling; C# Ionian - every name sharp, I C#, ii D#m, vii B#;
     at 1000 by 560, Teen Spirit chosen - G# Ionian, 7 F## fa##, vii F##.
     **iii lower and to the right; the star at rest by default; the chosen and coming chords outlined (Oct 14, Simon's
     screenshot - ii chosen, iii at the top - and: "a checkbox defaulted to false for rotating the diagram... touching
     by autoplay or user on the chooser should highlight with big outline the related chord notes and the chord itself
     ... red blue or cyan depending on the role... a predicted chord... thinner outline... start faint and farther and
     converge... pulse on tempo").** iii: the outside shift at the top-right rest place 0.5 to 0.75 (toward its root),
     and a new reach table for chords outside (`chord_reach_outside_by_rest_place`, `chordReachAt`: 1 but 0.55 there) -
     the shift alone slid it up the curve's top-right bulge to the window's edge; now it stands beside E, just over the
     G-E link, and the star, no longer pushed against the top by it, grows. The star's aim (`StarAim`, `starAimFor`,
     `aimStar`): the chosen chord's turn and side while "turn the star" is ticked (off at the start, `turns_star`), the
     tonic chord's otherwise - a choice that leaves the star where it is starts no move, so the fingers lose nothing;
     the box sends the star to its aim; a scale changed aims it again; the proxies follow the aim's root
     (`starAimRootDegree`). Outlines (`drawChordOutlines`, after the chords): the chosen chord's notes thick, in their
     part's color - root red, third blue, fifth cyan (`role_outline_colors`) - and its triplet's front white; skipped
     while fingers hold two or more of the left diagrams' chords (`heldLeftChordCount`); the coming chord's - the
     track's arriving one - thinner, starting 0.9 of a note's half-size out and faint, closing in and brightening with
     the chord's travel, on the note at arrival; both pulsing on the track's beat (`outlinePulse`: the beat, or the
     clock at the tempo while the track waits for the player), none without a track. Checked headless at 900 by 415: I
     at rest outlined; ii chosen - the star still, 2 red, 4 blue, 6 cyan, ii's button white; turning ticked, ii - the
     star turned, iii beside E; 1-4-5-1 halfway through its lead-in - I's thin rings halfway in, over its thick ones.
     **Notes at the top untouchable (Oct 14, Simon: "I cant touch notes to close to the top. Why").** The header's band
     (`WindowParts.isInHeader`) was the whole width above the parts, less the circle - every touch there given to the
     dropdowns (`readPointers`' `is_for_dropdowns`); the star reaching up into it beside the header (the turn before)
     put the top of its top notes there - with the star turned, 5 G sol and 3 E mi at the window's top. The band is now
     the header's box: above the parts and left of its right edge (`WindowParts.header_right` - the measured text and
     padding, or 360 before it is measured - the same edge that decides whether the star reaches up). Checked headless
     at 900 by 415, turning on, ii chosen: a finger on 5 G sol's top edge (y 20) plays G; one on the header's text,
     nothing.
     **Silent mode on iPhone; the outlines' third yellow; the 7 no longer pulled down; proxies for every note (Oct 14,
     Simon: "Yes [the audio session line]. And the current chosen third note should have yellow outline instead of
     blue... no need for the white outline, make it black... the red yellow or cyan outline even bigger... more room
     between 5 and 7 notes, by removing the bias that made the 7 come down... make the intermediate proxies a bit
     smaller... all the notes... their proxy on the other side... small, with no outlines").** Sound on iPhones: Safari
     plays Web Audio in the ambient session, which Silent mode mutes - the likeliest reason some iPhones were silent;
     `page_audio.askForPlaybackSession` sets `navigator.audioSession.type = "playback"` (Safari 16.4+) before the
     context is made (no looping silent clip for older iOS - reported not always enough; to try on Simon's phone first);
     the sound tutorial's section 6 says so. The page audio test, failing since 6a - its notice size 4 hard-coded, the
     stream-read notice having grown `RendererNotice` to 12 - now asks the module (`zimr_audio_test_notice_byte_count`,
     `worklet_abi.notice_byte_count`): passes, as does the worklet test. The star: the third's outline yellow (the
     zigzag's color); the chosen notes' own outline black (`drawNote`'s `is_chosen`, `chosen_note_outline_color`); the
     colored outlines thicker (0.26 of a half-size, was 0.16) and a little further out (0.18); `warpAt` the same on
     both sides - the pinky's pull and stretch and the fifth's stretch gone, the 7 back on the curve, room between 5
     and 7 - and the star's room now stopping at the circle's left side (`star_under_chromatic_share` 1.0: the 7 and
     its chord stood in the circle's corner; the star some 15% smaller at 900 by 415); proxies for all seven notes,
     each halfway on the link between its neighbours in the scale (`noteProxies`), 22% of a note (was 30%), no outline
     - `starAimRootDegree` and `targetAt`'s root parameter gone. Checked headless at 900 by 415: at rest, 1 3 5
     outlined red, yellow, cyan inside black; the seven proxies; the 7 up, clear of 5; nothing in the circle; turned to
     ii, likewise.
     **The right column boxed; what sounds in its own box; proxies easier to touch; the star's dot lines gone (Oct 14,
     Simon: "Have all proxy notes be playable. Remove the prev and next moving dot lines from main diagram. Put the
     center lissajou and the chord white text in the bottom right corner. Have both right side things in boxes like
     the left side").** Proxies: each tapped at its centre played its note (2 4 6 1 3 5 7) - but answered only within
     1.8 of its own half-size, some 13 pixels on a phone; now each takes three quarters of the room between it and its
     two neighbours' edges, a square counted to its corner (`NoteProxy.reach`, `note_proxy_room_share`), never less
     than before - taps 12 and 16 pixels off the 4's and the 6's play them. The star's moving dot lines from a sounding
     note to its neighbours gone (`drawPitchSteps`, `drawPitchStep`, `onlySoundingDegree`); the left diagrams keep
     theirs. `WindowParts.sounding`: below the circle's square, as wide, down to the content's bottom - the circle's
     square now in the content's corner, no longer lifted into the margins (`chromatic_corner_shift` gone), so that its
     box fits; held upright, a strip across below the star (`upright_sounding_share`, 30% of the width); touches there
     play nothing (`isInSounding`). The Lissajous figure (`drawChordCurve`) and the sounding name (`drawChordNumeral`,
     half the box's shorter side, fitted) drawn in it; all four parts boxed alike. Still to do, asked in the same
     message: the tonic 30% larger in every diagram, the white path as arcs (straight between the bottom notes), the
     notes equally spaced.
     **The star's curve: an ellipse cut by its bottom line, the notes equally spaced; the path along it; the tonic 30%
     larger on the star; the triplets in the fit (Oct 14, Simon: "In all diagram, have the 1 note... be 30 bigger...
     Have the white circle connecting the notes... be a white circle arc for all segments except between the bottom
     notes... Have the same distance between subsequent notes").** `StarCurve`: the ellipse with its bottom cut off by
     a straight line at the angle where the arc above is five times half the line (sought by halving, the arc measured
     by Simpson's rule, `ellipseArcLength`), so the curve is seven equal steps long; a place is a fraction of its
     length, clockwise from the top, as a turn's was of a turn - the rotations, the rest and every place keep their
     meaning - turned back into an angle on the arc by a table of 65 lengths (`angleAtArcLength`); points measured from
     the curve's middle, halfway between the arc's top and the line, about which the chords' rings are scaled (from
     the ellipse's centre the outer ring's line crowded the row and the star shrank to 20 pixels a note); the curve
     made again wherever the radii change (`StarLayout.setRadii`). The old warped ellipse stays the chooser's
     (`chooserCurveDirection`, renamed). Outer rings at 1.3 and 1.4 times offered as well - the shorter shape fits
     closer rings - and chosen. `drawNotePath` along the curve, 24 pieces a link: arcs above, the line below. The tonic
     `tonic_size_share` 1.3 times its size (`noteSizeInUnits`). The fit now counts each chord as its triplet's three
     shapes (`StarLayout.chordTripletShapes`, shared with `ChordTriplet`; `largestUnitApartTriplets`), spread at the
     size the last round found: a triplet's front had reached into the 1. Proxies halfway along their link on the curve,
     their reach from there. The chosen chord's outlines are not counted in the fit and may overlap neighbours. Checked
     headless at 900 by 415: steps 125 to 129 pixels all round; at rest 1 3 5 on the line, the 1 larger; turned to ii,
     2 4 6 on the line, the notes slid along the same curve. Still to do: the tonic 30% larger in the chooser, the key's
     window and the circle of the twelve.
     **The chords' shapes as fans to the arcs; the chords at their thirds; vii outside by its free link; the curve
     smaller (Oct 14, Simon: "Reduce the main note circle size by 35% so the exterior chord triangles have more
     room... no intersection at any chosen rotation... we want the white arc to be the divider... fill the shape...
     with two sides and the arc... the 7 chord button... place it outside at a good place").** Every link of the curve
     is faced by one chord outside and one inside (at rest: 1-3 I and vi, 3-5 I and iii, 5-7 V and iii, 7-2 V and
     none, 2-4 none and ii, 4-6 IV and ii, 6-1 IV and vi), so a chord's shape is now two fans from its button to the
     arcs of its two links (`drawChordShapes`, `drawChordFan`, `curve_pieces_per_link` 24 shared with the path):
     inside and outside meet only along the arc, no two cross. Each chord at its third's place on its ring
     (`StarLayout.chordCentre`, the table in its doc) - the shift and reach tables and their helpers gone
     (`valueAtPlace`, `placesFromRest`, `chordReachAt`, `chordShiftAt`, `diminished_outward`). The diminished chord on
     the outer ring by the one link no chord faces outside - 2 to 4, half a place past its third, with the major side
     outside; 7 to 2, half a place before it, with the minor - sliding between as the sides trade, its one fan to that
     link. The outer rings' candidates 1/0.65 larger (2.0 to 2.7): the curve some 31% smaller across within its room,
     the outer chords' fans the star's points. Checked headless at 900 by 415, turning on, all seven chords chosen: no
     two shapes cross; vii at the top with I chosen, at the left with ii; vi chosen - I inside and iii outside meet
     along the 3-5 arc; plain notes about 19 pixels in half-size, the row about 22, the tonic about 36. Still to do:
     the tonic 30% larger in the chooser, the key's window and the circle of the twelve.
     **vii at its third; the curve 10% larger; notes drawn smaller; proxies between edges; keys rise; the function's
     name; solfege optional (Oct 14, Simon: "The vii chord should be aligned with its third note... Make the circle
     10% bigger. Make the root note 10% smaller, and all others 5% smaller. Put the proxy notes precisely in the middle
     of the segments between notes, considering current note size. Increase height slightly of played notes on bottom
     keyboard. Under the lissajou write the long name of the chord... Put the drawing of solfege names... under a
     checkbox, disabled by default").** vii on the outer ring at its third's place, its one fan still to the link no
     chord faces outside. The outer rings' candidates divided by 1.1 (1.8 to 2.45). Notes drawn at 95% of the room the
     fit keeps for them, the tonic ("the root note", the 1) at 90% (`note_drawn_share`, `tonic_drawn_share` in
     `noteHalfSize`; the fit reads `noteSizeInUnits`, so the gaps widen rather than the unit growing back). Proxies at
     the middle of the link's visible part, between where the curve leaves the first note and enters the second, as
     drawn (`isOnNote`, `noteEdgeOnLink`: halving, 20 times). A sounding key rises 30% of the keyboard's height
     (`sounding_key_rise_share`). The sounding box's bottom fifth names the function (`function_name_band_share`,
     `drawFunctionName`, `soundingFunctionDegree` - a note alone its own, a matched chord its root's -
     `functionNameOfDegree`: Tonic to Submediant, the seventh "Leading tone" a half step below the tonic, else
     "Subtonic"). "solfege names" in the options, off at the start (`shows_solfege`): the star's notes then show their
     letters only. Checked headless at 900 by 415: V held - "V" over its figure, "Dominant" under it, keys 2 5 7
     raised, letters only on the notes, vii above D; all seven turns with turning on - vii outward from D each time,
     no two shapes crossing. Still to do: the tonic 30% larger in the chooser, the key's window and the circle of the
     twelve.
     **The key's window: smaller buttons, I raised over the IV-V step, clearer dots; black keys (Oct 14, Simon: "On the
     top left diagram, make the notes globally 30% smaller, and make their size increase when played 20% smaller...
     Make sure the successors dot lines are clear and visible. Move the 1 chord red square a bit more and make the IV
     V successor line go under the red square... Make the black keys on the keyboard really black with no outline and
     make them taller").** The top-left diagram is the key's window (`FifthsLayout`), not the chooser, which keeps its
     sizes. Its buttons drawn at 70% of the chooser's (`FifthsLayout.button_share`), the chosen a fifth larger instead
     of a quarter (`chosen_button_scale`), by `buttonHalfSize` - its rings keep the chooser's spacing, so the gaps
     widen; the window keeps its size unit; its borrowed buttons follow. The tonic's cell raised (`tonicLift`, in
     `cellCentre`, so touch follows) just enough that the straight IV-V step passes under its chosen size with a dot's
     spacing to spare - the ring's own curve, 1 - cos 30 degrees of its radius, being too little. `drawColumnStar`
     takes each diagram's own half-sizes, its dots starting at the buttons' edges; the dots 20% dimmed at rest (was
     45%, `column_dots_resting_dimming`) and a third larger (0.24 of their spacing). The black keys pure black, no
     outline, from a sounding key's raised top down - over its corners. Checked headless at 900 by 415, F held: the
     window's buttons smaller, I above the IV-V dots, every step clear; F raised, its corner under the black key.
     **Chords strummed (Oct 14, Simon: "When pressing a chord button in any of the 3 diagrams... we want the third and
     fifth notes to play at a delay of 0.1 and 2*0.1, this number exposed with a slider").** Every chord target - the
     star's triplets, the chooser, the key's window, the borrowed buttons - holds its notes through
     `holdChordDegrees`: the root at once, the third and the fifth waiting (`PendingHold`, `pending_holds`,
     `most_pending_holds`) one and two delays later (`chord_strum_seconds`, 0.1 at the start; "strum" slider, 0 to
     0.4 s), started once a frame (`startDueHolds`, after `readPointers`); a note with no free slot starts at once.
     Released (`releaseChordDegrees`), a note still waiting is taken off instead of let go (`takePendingHold`) - by
     degree and layer, as holds are counted, so another chord's waiting note taken instead keeps the counts right.
     Checked headless at 900 by 415: a chord held lights its root at 0.03 s, its third by 0.13, its fifth by 0.25; one
     tapped for 0.05 s leaves nothing lit. The track still only chooses (asked Simon whether it should now strum).
     **The key's window as a wedge of the wheel, its chords as guitar chords (Oct 14, Simon: "The top left diagram has
     dm and em inverted. We should make this one more interesting, and show guitar chords there instead of just chord
     buttons. Find the best way").** The minors' order fixed as the wheel has it - each over its relative major: ii
     over IV, vi over I, iii over V (Am and Em had been swapped; Dm was right), vii over vi. `FifthsLayout` rewritten:
     a wedge of three rings of twelfth-turn cells round a centre below the box - inner radius 1.4 ring thicknesses,
     the wedge 3.41 thick tall and 4.81 wide, the thickness the larger that fits the box - each cell drawn as a piece
     of the wheel (`drawWheelCell`), the chosen chord's filled faintly, a sounding one more, and its chord as fingered
     on a guitar (`drawGuitarChord`: name in the root's color; strings upright, lowest left, four frets, the nut or
     the window's first fret's number; x over a string not played, a ring over an open one, a dot on a fret pressed in
     its note's color; a barre as a bar under its dots), one box size for all (`diagramBox`). The fingerings
     (`guitarChordOf`, `searchGuitarStrings`, `guitarChordCost`, `guitarBarre`; once a layout, kept in the window):
     every fingering window by window up the neck playing the root lowest, all three notes and no other, only the
     lowest strings left out, within four frets, four fingers at most, a barre counting one; the cheapest kept - 3 a
     fret of position, 2 a string not played, 1 a finger, 1 a fret of stretch, -1 an open string, 1 for a barre. The
     stretch term added after a mirror of the search showed x50232 beating xx0232, 502220 beating x02220, and 025000
     tying 022000. A comptime check holds C x32010, G 320003, D xx0232, A x02220, E 022100, Am x02210, Em 022000, Dm
     xx0231 and F 133211. The window's star of steps and its notes' polygon gone (`drawFifthsPolygon`,
     `isCornerBeforeByAngle`, the window's Geometry, `tonicLift`, `buttonHalfSize`), the chooser keeping both; the
     chooser's size no longer capped by the window's; borrowed buttons at a diagram's top right corner. Checked
     headless at 900 by 415: the wedge, I chosen filled red, each chord as charted; a tap on the middle ring's right
     cell plays Em, lit everywhere.
     **The key's window: chords in their shapes, as large as the box allows; the steps back; notes lit on the charts
     (Oct 14, Simon: "We dont need the curved gray lines around the guitar shapes. Around the shape we can place a
     circle or square outline of the note color. Try to make the guitar shape as big as possible. Just draw the chord
     name em not iii. Try to bring back the successor dots. Move the vii chord to the right a bit so we can see its
     successor 1. Light up the string notes if they are played").** The wedge's outlines and fills gone
     (`drawWheelCell`); the cells keep their places on the wheel - rings a spacing apart, the inner ring's middle 1.93
     spacings out so that its cells are a spacing apart too - and each chord is drawn there as its button's shape,
     0.42 of a spacing in half-size, filled dark over the dots (faintly in its color while it sounds) and outlined in
     its color, bright and thicker while chosen; the spacing the largest at which the shapes' extent fits the box
     (`ofArea`, `unitCellCentre`, `shapeHalfSize`). The chart inside: 86% of a square, 68% of a circle - the square
     inside it (`diagramBox`); its name the letters alone. The star of steps drawn again under the shapes, its dots
     from their edges. vii 15 degrees right of the middle (`diminished_shift_turns`): its step to I passes vi's right
     side. A chart's dots and open-string rings dim, and lit 30% larger while their note sounds - wherever it is
     played. Borrowed buttons at a shape's top right corner. Checked headless at 900 by 415: the shapes filling the
     box's height and width, C chosen bright; Em held - its circle filled, every E, G and B lit on every chart.
     **The chooser shorter, the guitar charts larger, every sounding note on every chart (Oct 14, Simon: "Reduce by 30%
     the scale of the left bottom chooser by reducing vertical spacing by 20% and button size by 10%. Try to increase
     the size of guitar shapes by 50%. Draw the strings with a lighter gray. Put the chord text outside the outline...
     Reduce space between guitar shape buttons. When touching any note anywhere, we should draw any guitar string touch
     in any guitar shape that could allow it... ways to do an am7 or dsus2").** The column split 65/35 (`fifths_share`
     was 0.5): the chooser 30% shorter, its curve squished 20% more (`vertical_squish` 0.56, was 0.7), its buttons
     about 10% smaller by its own fit. The key's window now straight rows bending down at their sides
     (`FifthsLayout`: `unitCellCentre`, `side_drop_share` 1.2 so that the IV-V step passes under I; columns 2.15
     half-sizes apart, rows 2.6 with a name 0.5 above each shape; vii over iii, its step to I beside vi): the wheel's
     curve had spent the height three rows and their names need, the width a third empty. The half-size the largest
     that fits - about 25 pixels at 900 by 415 - the chart filling 90% of a square, 70% of a circle, its name above it
     outside (`nameHeight`); charts about 38 pixels tall, from 21. Strings and frets a lighter gray
     (`guitar_line_color`). Every note sounding that a chart's window could play - any string, open or at any of its
     frets - a ring in its color (`drawSoundingPlaces`, `GuitarPlaces`), besides its own dots lit. Checked headless,
     the digits holding Am7 (6 1 3 5) and Dsus2 (2 3 6): each chart ringed where those notes lie - Am's open G and the
     high E's third fret for Am7, Dm's open high E for Dsus2.
     **The charts' own notes always whole (Oct 14, Simon: "Even when not played, the main guitar notes for all chords
     should be highlighted. Make them 30% bigger even if they overlap").** A chart's own dots and open-string rings
     drawn in their notes' whole colors and 30% larger (`chart_note_scale`), sounding or not, overlapping where they
     meet; a sounding one ringed in white instead of brightening; the rings where other sounding notes could be played
     stay plain-sized. Checked headless at 900 by 415: at rest every chart's fingering bright; Am7 held - its notes
     ringed white on every chart, the other places ringed small.
     **The star app's code reviewed and commented, first pass (Oct 14, Simon: "Review this code add comments everywhere.
     Give a large comment at the top explaining the whole thing").** The top comment rewritten whole: the window's
     parts with a sketch, the scale, the star (curve, chords, fans, outlines, turning, the fit), playing (pointers,
     holds, the strum, Shepard tones, pedals), the progression track, the guitar chords, and the file's order. Review,
     by a survey of every backticked name in a comment against the code and of words for what changed: stale
     `buildScaleDropdowns`, `chooserChordVelocity` and `letter_names` (twice) corrected; triangles where chords now
     draw fans (`TriangleDimming` renamed `FanDimming`); the bulges re-explained by what they do now, on the chooser's
     curve only; the chord's name shown in the sounding box, not the star's middle; the first of two sections named
     for the star's curve renamed for the chooser's; `isBelowStar`'s doc line, found stacked on `isInStarArea`'s,
     moved back; `isInStarArea` excluding the sounding box, as its doc now says; the outer ring sizes' doc naming
     `ofRoom`, not `ofWindow`. Every declaration and field now documented (182 had none: 149 doc comments added,
     the standard-library and math aliases under one group comment) - `State` and `WindowLayout` among them. Next:
     inline comments in the 23 long function bodies with few (`drawGuitarChord`, `curveNotes`, `guitarChordCost`,
     `drawChromaticCircle`, `largestSizeUnit`, `initState`, ...).
     **The star app's remaining comments (pending).** Inline comments in the 23 long function bodies with few
     (`drawGuitarChord`, `curveNotes`, `guitarChordCost`, `drawChromaticCircle`, `largestSizeUnit`, `initState`, ...):
     set aside when Simon turned back to the sound plan (Oct 14).
     **The keyboard as a piano; the disk full (Oct 14, Simon: "Hum some processes seem to be too long. Are we hitting
     a compiler bug or a looping test? ... When choosing a different tonality like a# or scale like dorian, we want the
     piano to show the actual notes we should play. The used blacks keys should take the correct color, and be at the
     correct place... the keyboard shape to go root to root. The unused whites should be gray and do no sound").** The
     long runs: no loop and no compiler bug - nothing was running; the star page builds in 22 s warm (its comptime
     guitar check costs 1 s), the fast suite runs in 21 s (285 passed); but the disk stood at 98%, .zig-cache 8.3 GB
     of every version of everything built that day, and the build refuses at 97% - with one processor shared by two
     sessions' builds and an orphaned one. The cache and zig-out cleared (51% then); the star page rebuilt cold in
     238 s. The keyboard (`PianoLayout`, `isBlackPitchClass`): a piano's keys from the tonic to the tonic above,
     white and black where a piano has them, laid out for the scale sounding - a borrowed chord's raised note on its
     own key; a key the scale uses in its degree's color, named by number and spelled name, the others grey (white)
     or black, and silent (`WindowParts.keyboardDegreeAt` - a black key over the upper part near a boundary that has
     one; `targetAt` given the sounding scale); a black tonic framed by the white keys either side of the octave, nine
     whites, the two framing ones outside it and silent. Checked headless at 900 by 415: C Ionian as before; A# Ionian
     - C 2 B#, D 3 C##, F 5 E#, G 6 F##, A 7 G## white, A# 1 and D# 4 black, the rest grey or black; A# Dorian - C#
     3 and G# 7 black; a touch on the unused B silent; on the black A# - the 1, both tonic keys lit.
     **A progression editor (Oct 15, Simon: "Lets make a progression editor. Choosing one in the dropdown should just
     place it there. I am thinking a simple array of 4 or 8 boxes as chosen in options. Dragging a chord from anywhere
     into a box puts this chord there with its name as in the bottom left chooser. It changes the progression live.
     Move down a bit the main diagram so the track fits at the top").** `State.progression_boxes` (8 at most, each a
     `ScaleChord` or empty) and the options' "boxes" (4 or 8, `progression_box_counts`). The track is the boxes now:
     `trackStepCount`, `trackBoxIndex`, `trackChord`, `hasTrack`, `playingBoxIndex` - the boxes holding a chord, in
     order, round and round, the empty ones passed over; every reader of the chosen progression rewired to them
     (advancing, the chord awaited, playing the chords, the outlines' pulse and the coming chord's, the chooser's
     track and its buttons) and the borrowed chords offered are the boxes' chords from outside the scale. A
     progression picked fills the boxes from the first, the rest empty (`placeChosenProgression`, after a song's key
     is set, so its chords are the new scale's); more boxes, the progression carries on into the empty new ones
     (`extendChosenProgression`), edits kept. Dragging (`ChordDrag`, `carryChords`): a finger that comes down on a
     chord - star, chooser, key's window, borrowed button, box (`chordOfTarget`) - picks it up, gliding onto one does
     not (`pointer_ids_last_frame`); past 12 pixels a ghost follows it and the box under it lights in its colour;
     lifted over a box, the box takes it (`dropChord`). A box plays its chord as the chooser does (`targetAt`). Layout:
     `WindowParts.editor`, a band a tenth of the window high (30 to 64 pixels, `editorHeight`) across the star
     column's top, beside the header; the star a margin below; upright, between the top band and the star. Drawn
     (`drawProgressionEditor`): each box as the chooser's button, the playing box outlined white, swelling on the
     beat. Checked headless at 900 by 415: four empty boxes, the star below; 1-5-6-4 picked - I C, V G, vi Am, IV F;
     ii dragged from the chooser onto the fourth - its ghost, the box lit orange, then ii Dm there; 8 boxes - the four
     kept, ii included, four empty; playing the chords, the wait off - the second box lit, V chosen everywhere.
     **The awaited chord pulses; the prediction outline on its button (Oct 15, Simon: "Make it so that the target
     notes and chord of the progression that should be hit, in the wait for player mode, continue pulsating in size
     quickly to indicate that we still need to hit it. Have the prediction outline also be around the chord buttons in
     the main diagram").** `awaitedChord` - following the player, the chord awaited once it has reached its button,
     until played - and `waitingScale`: from its size to a fifth larger, three times a second, quicker than the beat.
     Applied to its notes on the star and their outlines (`noteWaitingScale`, `drawNoteOutline` now taking the state),
     the star's button on its root (`starChordWaitingScale`), the chooser's, the key's window's and the borrowed
     buttons - the chord itself, a borrowed one's own button (`leftChordWaitingScale`) - and its box in the editor;
     `outlinePulse` asks `awaitedChord` too. The coming chord's button on the star gets a thin white outline closing in
     with its notes' (`drawChordOutlines`); the editor's playing box uses `outline_color`, the chosen button's white.
     Checked headless at 900 by 415, 1-5-6-4: mid-travel the I button ringed in white, closing in; waiting, two
     captures half a pulse apart - the 1, 3 and 5, the I button, the chooser's I, the key's window's C and the first
     box all larger in the second.
     **The button's prediction outline, the drop's preview, the playhead (Oct 15, Simon: "Make the prediction outline
     twice as thick for the chord button, and make it start from 5 times farter. But reduce the prediction time for
     the outline by. 50%. Draw the dragged chord into progression boxes. Draw the on the track the playhead as a think
     white line").** Read as: the three for the button's outline only, the notes' kept. The coming chord's button's
     outline twice as thick (`coming_button_thickness_factor`), from five times as far (`coming_button_reach_factor`),
     over the bar's second half only (`coming_button_shown_share`), closing in over it. A carried chord over a box is
     drawn in it, as it would hold it, outlined in its colour, the ghost under the finger hidden there
     (`carriedOverBox`); lifted elsewhere, the box keeps its own. The playhead: a 2-pixel white line across the playing
     box through its bar, held at its right edge while the track waits. Checked headless at 900 by 415: a third into
     the first bar, no button outline; three quarters, the button's outline halfway in; ii carried over the fourth
     box, ii drawn there, no ghost, then IV again when lifted off it; playing, the line a third across V's box.
     **One prediction time; the outlines on the keyboard and the circle (Oct 15, Simon: "Make the prediction time be
     the same for the notes and chords. Add prediction and current highlights on the keyboard notes and the top right
     circle").** `comingOutline` (`ComingOutline`: the chord coming, how far its outlines have closed in, their
     opacity) - the one place the coming outlines' timing is decided: shown over the bar's second half for every view
     (`coming_outline_shown_share`, which replaced the button's own). The star's notes now appear at the bar's middle
     with its button. The keyboard (`drawKeyOutlines`, its keys with a degree collected as drawn - `OutlinedKey` - and
     outlined over them all) and the circle of the twelve notes (`drawNoteShapeOutlines`, its notes' places and sizes
     collected): the chosen chord's notes in thick outlines of their parts' colours - not while two or more left
     chords are held - and the coming chord's in thin ones closing in, the sizes as shares of a key's half-height or a
     note's half-size, as on the star. Checked headless at 900 by 415, 1-5-6-4 played, the wait off, three quarters
     into the second bar: I playing - C, E, G in thick red, yellow, cyan on the star, both C keys, E and G, and the
     circle - and V coming - G, B, D thin in red, yellow, cyan on all three, V's button ringed in white.
     **Box counts from 2 to 16, fitted to the progression picked (Oct 15, Simon: "Selecting a progression should
     change the number of boxes to match. Give more options for number of chords. 2,3,4,6,8,12,16").**
     `progression_box_counts` 2, 3, 4, 6, 8, 12, 16 (4 first, `progression_box_count_first_choice`);
     `progression_box_most` is the last of them. A progression picked sets the count to the fewest boxes holding its
     chords (`boxCountChoiceFor`): the list's 33 have 3 (three of them), 4 (21), 5 (two, into 6, the last box empty),
     8 (six) and 12 (one). Checked headless at 900 by 415: 2-5-1 picked - "3 boxes", ii V I; 1-5-6-4 picked, then 12
     chosen - its four kept and eight empty, each box about 33 pixels wide.
     a. The audio context at 48 000 Hz, resumed at the first click, tap or key.
     b. The worklet's module: the program's text and one line calling `start()`, loaded from a Blob URL - or from a
        `data:` URL where the page's origin is opaque (a file opened from disk, a sandboxed frame).
     c. The node: `new AudioWorkletNode(context, "zimr-renderer", { numberOfInputs: 0, outputChannelCount: [2],
        processorOptions: { module } })`, where `module` is the app's compiled module, kept by the bridge from
        instantiating the app.
     d. Each frame, `forwardCommands` with a sink that gathers the frame's command bytes into one `commands` message,
        sent before each `samples` message so that the order holds.
     e. The port's `notices` messages: their bytes copied into the app's memory and handed to `acceptNotices`.
     f. Without a worklet - an old browser, or an origin that forbids loading one - a ScriptProcessorNode whose
        callback calls the app's own renderer on the main thread: pulled there, as the headless output is.
     g. The web platform declares which of the two its output is. `Mixer` gains the first kind, a renderer in another
        memory: `mixFrame` forwards the commands and reads the notices, and `sendToRenderer`, finding the queue full,
        forwards the commands rather than applying them to the unused local renderer (the design point above).
     h. The readout of step 4 from the browser's numbers: the context's `baseLatency` and `outputLatency`, and the
        key's time to its block. The output latency is the browser's floor; on a desktop it can stay under the target,
        on a phone (Android especially) it is often 20 - 40 ms alone.
     *Verified:* a Node test of both sides together - the bridge's sound code and the worklet's program, joined by a
     pair of stand-in ports - plays `composer_drum`'s kicks 48 000 frames apart; the script-processor path plays the
     same frames; Simon hears `composer_drum` and `audio_mixer` in Chrome and Firefox, and on his phone. *Done when*
     those pass, and no browser output posts blocks of samples any more.
  8. **The push path removed.** No output pushes: `AudioRing`, the margin and its window of gaps,
     `startNewVoicesInsideQueue`, `mixNewVoicesInto`, the contract's `queue`, `queued_frames` and `mix_into_queued`,
     and the push halves of the headless and Windows outputs all go. *Verified:* every sound test, rewritten where it
     drove the push path; the headless timing test (a sound played at frame 10 starts at output frame 8 000); every
     audio example built for the web and Windows. *Done when* none of those names is left in the source.
  9. **Chapter 14 of the backends tutorial rewritten** for the design as it then is: the two sides and their queues,
     pulling, the worklet - a second instance of the app's module, its entry points, its messages - and the
     script-processor path; the comparison with raylib, sokol, SDL3, Mach and JUCE brought up to date. *Done when*
     the chapter describes no push path.
  10. **Then, in this order:** streams and music on the mixer (a decoder feeding a voice as it plays); the decoders -
     Vorbis, a port of `stb_vorbis`, then QOA (step 6 above); the analyser, an FFT of the mixer's output for a spectrum
     view (step 7); sample-accurate scheduling (5.e); quality when measured - the resampler, a limiter (step 9). And
     `sound.zig`'s header, which still describes the browser's audio graph as the API's path, rewritten for the mixer.
- **C6.** Text editing: the editor's remaining parts in `ui.zig`; the clipboard; input-method composition
  (`WM_IME_*`).
- **C7.** Pointer lock (`ClipCursor`, raw input `WM_INPUT`), after GLFW's and sokol's.
- **C8.** Gamepads (D11): XInput, DirectInput with the database.
- **C8 done Oct 9 - gamepads, end to end.** No platform fed gamepads before - the runtime's raylib-style queries
  read state nothing wrote, and the web and Windows refused `gamepad`. Now the engine reads every slot each frame
  (`wgpu_app.readGamepads`, `input.setGamepad`: the contract's W3C order onto raylib's numbers, a button down from
  half its travel, the triggers also axes 4 and 5; a test pins the mapping); the queries and `setGamepadVibration` -
  through `platform.current.setGamepadRumble` now, its C8 directives gone - are exported (`z.isGamepadAvailable`,
  ...). Windows: XInput loaded by name (`xinput1_4`, `1_3`, `9_1_0`), an empty slot asked again only after a second,
  a rumble stopped when its time is up. Web: `js_gamepad_state` (17 buttons and 4 axes into the module's memory) and
  `js_gamepad_vibrate` (`dual-rumble`), registered at last - `web.zig` declared the latter, the bridge never had it.
  Headless: a scripted pad holder (`setScriptedGamepad`), filled by the script commands `gamepad_connect`,
  `gamepad_disconnect`, `gamepad_button`, `gamepad_axis` - state, not events: the session keeps each pad and hands it
  to the loop whole (`Loop.set_gamepad`); in a window, a slot a script has played answers before XInput
  (`native_loop.scriptedGamepad`), so a script runs alike in both; a headless rumble is logged. Seen: two scripted
  pads in `input_gamepad` - buttons lit, a stick and a trigger where the script put them, the rumble of a press logged.
  Example: `input_gamepad`. A clamp that could not compile (`@as(f32, maxInt(u32))`) had hidden behind a comptime return.
- **C10.** Loading by path natively: the loaders' `fetch` (`codecs`, the runtime's `Loader`, `errors`) reads files
  where there is no browser to fetch from.
- **C9.** Simon's Windows session: every example tried by hand from the native gallery (B10), a checklist over the
  flagships and every input kind; the diagnostics switches; his report's fixes.

### Phase D - Linux on X11 (verified here)

- **D1.** The window, after GLFW's `x11_window.c`: libX11 at run time; `WM_DELETE_WINDOW`, `_NET_WM_NAME`, `ConfigureNotify`,
  focus, map state, `Xft.dpi` scale; `VK_KHR_xlib_surface`.
- **D2.** Input: keys by XKB key names (L10); text through XIM (L11); buttons 1 to 3, 8, 9; the wheel as 4 to 7;
  detectable auto-repeat.
- **D3.** Services: the `CLIPBOARD` selection; pointer lock through XInput2 raw motion and a grab; cursor shapes; ALSA;
  evdev gamepads; saved state.
- **D4.** Verification, `zig build linux-x11-check`: Xvfb and lavapipe; `hello_world` and the launcher for a fixed
  number of frames; screenshots compared; an XTest driver types, clicks and scrolls, and the input log is compared
  with what the browser would send. Done: passes here in under five minutes.

### Phase E - macOS (built here, run by Simon)

- **E1.** The Objective-C runtime from Zig, loaded at run time (D4): typed `objc_msgSend` calls, classes and selectors
  cached, autorelease pools, classes registered at run time (the app delegate, the view).
- **E2.** The app after sokol's macOS code and GLFW's `cocoa_window.m`: `NSApplication`, an `NSWindow` whose view is
  backed by a `CAMetalLayer`; frames from `CADisplayLink` (L2); the window delegate (close, resize, focus, backing
  scale).
- **E3.** Presenting: KosmicKrisp or MoltenVK in the bundle; `VK_EXT_metal_surface`; the portability extensions.
- **E4.** Input: `kVK_*` (D7); modifiers from `flagsChanged`; text and composition through `NSTextInputClient`; precise
  and line scrolling into notches.
- **E5.** Services: `NSPasteboard`, pointer lock (`CGAssociateMouseAndMouseCursorPosition`), cursor shapes, CoreAudio,
  GameController, saved state.
- **E6.** The `.app` assembled and signed ad hoc here (D14). Simon runs it from a checklist.

### Phase F - Android (built here, run on Simon's phone)

- **F1.** NativeActivity after sokol and `android_native_app_glue`: the app's thread, the pipe, the blocking handoffs
  (L5); the lifecycle (L4, L6).
- **F2.** Presenting: `libvulkan.so` at run time; 1.3 required (D3); the surface attached and detached with the window
  (D8); `SUBOPTIMAL` from rotation.
- **F3.** Input: touches (with cancel), `AKEYCODE_*` (D7), the soft keyboard through JNI; the accelerometer into
  `inputPushMotion`.
- **F4.** Services: AAudio, saved state (the activity's internal path), gamepads.
- **F5.** The `.so` built here against stub libraries (D4); the APK assembled on Simon's machine; `adb` and `logcat`
  checklist.

### Phase G - iOS (on a Mac)

- **G1.** The app after sokol's iOS code: `UIApplicationMain`, a view backed by a `CAMetalLayer`, `CADisplayLink`;
  backgrounding detaches the surface (D8).
- **G2.** MoltenVK until KosmicKrisp reaches iOS; touches, Core Motion, the soft keyboard (`UITextInput`), the safe
  area, `AVAudioSession` and CoreAudio, GameController, saved state.
- **G3.** Built and signed on a Mac; an iPhone checklist.

### Phase H - Wayland (verified here, partly)

- **H1.** A protocol generator in Zig (`tools/wayland_scan.zig`, as `vk_gen` reads `vk.xml`): Zig interface tables from
  `wayland.xml`, `xdg-shell.xml` and the extensions used.
- **H2.** The window after GLFW's `wl_window.c`: libwayland-client at run time, `xdg_toplevel`, libdecor for
  decorations where the compositor draws none, fractional scale, `cursor-shape`, pointer constraints, data devices.
- **H3.** Input through xkbcommon: the XKB-name table of X11 (D7), composition through `text-input-v3`.
- **H4.** Verification under weston's headless backend with lavapipe.

### Phase I - The course (with every phase)

After each phase: a review like Oct 7's, and its tutorial chapter - the platform contract; the headless platform;
Linux on X11; macOS through the Objective-C runtime; Android through NativeActivity; iOS; Wayland; audio (mixer,
Vorbis, outputs); gamepads; jobs; saved state.

## 6. What is verified where

| Platform | Built here | Run here | Run by Simon |
|---|---|---|---|
| Engine and examples | yes | yes: headless platform on lavapipe, every flagship (D12) | - |
| Web | yes | page builds; headless browser not available | phone and desktop |
| Windows | yes | the Vulkan host's code paths through the headless platform | the launcher, a checklist |
| Linux X11 | yes | yes: Xvfb, screenshots, synthetic input (D4) | optional |
| Linux Wayland | yes | partly: weston headless | optional |
| macOS | yes: `.app` assembled here (D4) | no | a checklist |
| Android | yes: `.so` built here (D4) | no | the phone, a checklist |
| iOS | no: needs the SDK on a Mac | no | on a Mac |

## 7. Risks

- **What only devices show**: driver bugs (the Adreno history), compositor and desktop quirks, input methods. Each
  checklist targets them; each platform file follows a reference that has met them.
- **MoltenVK's coverage** of the host's 1.3 features on iOS (checked at bring-up; KosmicKrisp may reach iOS first).
- **Android drivers below 1.3**: refused by name.
- **Audio fidelity**: the native mixer must match the browser's graph (volume curves, pitch, looping); the headless
  checks compare mixed output with reference renders.
- **The NVIDIA FIFO pacing issue** sokol reports on Windows: watched in Simon's session.
- **Synchronization validation** (A4).
- **iOS needs a Mac** for the SDK and signing.

## 8. Reviews against the references

Every second turn, the work so far is compared with SDL, sokol, raylib and Mach, and the backends tutorial grows.

**Oct 7, Mach** (`mach-main`: `src/Core.zig`, `src/core/`, `src/sysaudio/`) - the one reference written in Zig:

- **Platform selection**: a comptime switch on the OS, as ours; no check of a platform's declarations - a missing
  function fails at its call site. Our contract's check (B1) names what is missing; kept.
- **Events**: Mach adds trackpad gestures - zoom and rotate, each with begin, update, end and cancel. On the web and
  Windows a pinch arrives as a wheel event with Ctrl held, so nothing changes for them; the gestures join the API
  with macOS (Phase E).
- **Window properties**: Mach's app writes the desired state (title, cursor, fullscreen) and the platform's `tick`
  applies the difference. Ours are requests whose outcomes are events, which the browser's delayed grants need; kept.
- **Windows**: no drag-loop timer, raw input, horizontal wheel or IME - thinner than SDL's, which stays the reference
  for Windows behaviour.
- **X11 keys**: Mach maps keysyms (`XLookupString`), which follow the keyboard layout - AZERTY's Z reports where
  QWERTY's W is. GLFW and sokol use XKB key names, physical positions; our D7 follows them.
- **Libraries at run time**: Mach's Linux layer and its ALSA backend (`libasound.so.2`, then `libasound.so`) load at
  run time, as D4.
- **Audio**: pulled by a write callback on an audio thread; Linux tries PulseAudio, PipeWire, JACK, then ALSA. Sokol
  uses ALSA alone. Our push queue feeds a thread that pulls from it; ALSA stays the one Linux backend, PulseAudio the
  known fallback.
- **Threads**: Mach renders on its own thread; zimr keeps one thread for the engine, as the browser has.

- **A6. Object lifetimes, audited against WebGPU's model** (from the Oct 7 review): every object a WebGPU object keeps
  alive - bind groups keep their buffers, texture views and samplers; pipelines keep their layouts (done) - must
  outlive the app's release in the host too. Mach's sysgpu counts references on every object; SDL's GPU layer counts,
  per resource, the command buffers using it. Check each release path of the host against them. **Done Oct 7**: the
  bridge destroys buffers and textures explicitly (`destroy()`), everything else it only releases; the host matches -
  pipelines hold their layouts, bind groups hold their views and samplers (counted, one `Holder` enum), released
  objects wait for the submission that may last use them (open encoders count until their submit, so a finished,
  unsubmitted command buffer is covered); shader modules and bind group layouts need no holding. `vk-host-test`'s
  `lifetimes` check releases a view and a sampler before and after their group; with the holds broken, the
  validation layer reports the four leaked objects and the check fails.

**Oct 7, object lifetimes and precision** (prompted by the pipeline layout destroyed under its pipelines):

- **Mach's sysgpu**: every object counts its references (`manager.reference()`, `release()`); a pipeline takes one on
  its layout - the model our fix follows, and the one the A6 audit extends.
- **SDL's GPU layer**: resources count the command buffers that use them, and are destroyed once none does.
- **sokol_gfx's Vulkan backend**: the pipeline layout belongs to the shader object; the app keeps a shader alive while
  its pipelines live - a rule zimr cannot ask of WebGPU code, where releasing a layout early is correct.
- **Precision**: none of the references checks its math against the specifications' bounds; zimrnum's conformance
  table, run natively, is what found `expm1` relying on `log` near 1. The rule now in the tutorial (12.7): a GPU
  function relies on no builtin beyond what Vulkan and WGSL promise.

**Oct 7, the contract (B1)** against SDL3 (`SDL_events.h`, `SDL_video.h`), sokol (`sokol_app.h`), raylib
(`src/platforms/rcore_template.c`) and Mach (`src/Core.zig`):

- **How a platform is checked.** SDL3's video backends fill a structure of function pointers, a null pointer meaning
  unsupported, found at run time. sokol is one file with a section per platform, chosen by the preprocessor. raylib
  gives a new platform a template file to fill (`rcore_template.c`) - the model for `template.zig`. Mach chooses its
  platform with a comptime switch and calls it directly; its `assertHasDecl` helper is defined but unused. Ours is
  the only one that checks names and exact types at compile time and lists every problem at once, with each refusal
  written in the platform's own source. Kept.
- **Keys: position and label.** SDL3's key events carry both a scancode (position) and a keycode (what the current
  layout prints on the key), and SDL3 advises keycodes for shortcuts; the browser has `code` and `key`. Our `KeyDown`
  has the position only, so Ctrl+Z would be the key at QWERTY's Z on an AZERTY keyboard, where W is printed.
  **Adopted, for B3:** `KeyDown` gains the character the key types on the current layout, without modifiers (the
  browser's `key` when it is one character; Windows' `MapVirtualKeyW(..., MAPVK_VK_TO_CHAR)`), for shortcuts;
  positions stay for movement keys.
- **Dropped files.** SDL3 (`DROP_BEGIN`, `DROP_FILE`, `DROP_TEXT`, `DROP_POSITION`, `DROP_COMPLETE`) and sokol
  (`FILES_DROPPED`) report files dragged onto the window; we have nothing. **Deferred, decided in B4:** an event
  naming how many files dropped and where, and a request reading one into a buffer - the browser hands over file
  contents asynchronously, a desktop a path.
- **Phones.** SDL3's background and foreground transitions and low-memory warning, sokol's `SUSPENDED`/`RESUMED`,
  SDL3's safe area (the screen's notches and rounded corners, `SDL_GetWindowSafeArea` and its change event) and its
  on-screen keyboard shown and hidden. **Deferred to Phase F**, as `suspended`, `resumed`, a `safeArea()` query
  reported by `resized`, and the keyboard's two events.
- **Device changes.** SDL3 reports audio devices added, removed and reformatted, and a render device lost.
  **Recorded** for the audio step (B7: WASAPI's default device changing) and the GPU host (a lost device rebuilt).
- **Window management.** raylib's platform positions, sizes, maximizes, minimizes and decorates windows and lists
  monitors; SDL3 reports displays added, moved and rescaled. A browser can do none of it, and no example needs it.
  **Left out**, deliberately; a desktop tool needing it would add requests the web refuses.
- **Event shapes.** Mach separates `key_repeat` from `key_press`, where we flag `repeat`; Mach and SDL3 report a
  scale change apart from a resize, where our `resized` carries the scale. Equivalent; kept. raylib polls input each
  frame (`PollInputEvents`) and presents graphics itself (`SwapScreenBuffer`): our platforms push events into a loop
  they own, and presenting belongs to the GPU host.
- **Time.** raylib returns seconds as a double; we return nanoseconds as an integer, which loses no precision over
  a long run. Kept.

**Oct 7, the native examples (B10)** against raylib (`examples/Makefile`), Mach (`build.zig`), sokol (its samples)
and SDL (`test/`): every one builds each example as its own program, as zimr now does. raylib names the platform
with a Makefile variable - `PLATFORM_DESKTOP` by default, `PLATFORM_WEB` for a page per example - and Mach registers a
`run-<name>` step per example, both defaulting to the desktop. zimr defaults to the web and names the native variant
by suffix (`<example>-windows`), which `zig build -l` lists; when Linux and macOS arrive, a `-Dplatform` option may
scale better than a suffix per platform - decided then. None of the four ships a gallery that starts native
examples as processes; raylib and sokol keep theirs on the web.

**Oct 7, texture views** against the references. SDL3's GPU API has no view objects: a colour target names its
texture, mip level and layer each time (`SDL_GPUColorTargetInfo`), and sampling always sees the whole texture.
sokol's attachment descriptions likewise name a mip level and a slice. raylib generates mipmaps
(`GenTextureMipmaps`) and offers no texture arrays. Mach follows WebGPU, as zimr does: a view is an object, made
once and reused, naming its levels, layers and dimension. zimr's views map one-to-one onto Vulkan image views,
which is why the host creates them eagerly rather than per use.

**Oct 7, pointer motion and presence** against sokol (`sokol_app.h`, read) and what is known of SDL and raylib.
sokol's web mouse callback takes `movementX`/`movementY` while the pointer is locked and the step between positions
otherwise - zimr's rule exactly - and its Windows backend asks `TrackMouseEvent` for WM_MOUSELEAVE, as zimr's does;
it reports `SAPP_EVENTTYPE_MOUSE_ENTER`/`LEAVE` events and a per-event `mouse_dx`/`mouse_dy`. SDL reports relative
motion (`xrel`/`yrel`) beside the position in every motion event. raylib's `GetMouseDelta` is the step between
positions and its `IsCursorOnScreen` follows GLFW's cursor-enter callback; under `DisableCursor`, GLFW moves a
virtual position, so raylib's step-based delta keeps working there, which a browser's frozen position does not
allow.

**Oct 7, pointer lock** against sokol (`_sapp_win32_lock_mouse`, read): raw input and `ClipCursor` as zimr,
but confined to one point at the client centre with the cursor's position saved and restored - adopted. sokol
differences absolute raw reports (remote desktops, tablets) into motion, noting the path as untested; zimr skips
them for now. SDL's relative mouse mode and GLFW's disabled cursor (which raylib's `DisableCursor` uses) rest on the
same raw input on Windows.

**Oct 7, the window requests** against sokol (`_sapp_win32_set_fullscreen`, read): borderless fullscreen as
zimr does it - a popup style over the nearest monitor's rectangle - storing the window rectangle where zimr stores
the placement (which also restores a maximized window). sokol has no keep-awake or open-address requests. SDL
offers both: `SDL_DisableScreenSaver` (SetThreadExecutionState on Windows) and `SDL_OpenURL` (ShellExecuteW).
raylib's `ToggleBorderlessWindowed` is the borderless kind; its `ToggleFullscreen` changes the display mode.

## 9. The rest of the sound plan (Oct 14)

**Where C5 stands.** Done, of "the order from here" (Phase C, Oct 12): 1 the glitches, 2 the hot paths, 3 the Shepard
instrument, 4 the scale star (its two-hand form, progressions, borrowed chords), 5 streams on the mixer, 6 streams
across to the worklet (a page's streams on the mixer, forwarded; the browser's graph keeps only music and the
analyser), 13 the sound tutorial; of 12, the page frame's handle scope and the full queues; of 7, 7a (Ogg pages and
packets), the inverse MDCT in zimrnum, 7b (the Vorbis headers); and `codecs.zig`'s assertions reviewed (the font code's
data now handled, not asserted). Open: 7c to 7e, 8 to 11, the rest of 12 - each below with what it is, its design, its
sub-steps and their tests, when it is done, what Simon checks, its size, and its risks.

**Where it stands, Oct 15.** Done since: 7c (the decoder, against stb_vorbis and, where stb is wrong, libvorbis),
7d (music on the mixer), 7e1 (seeking by pages), 7e2 (the analyser on the mixer, natively and on a page). 7e3's
removal is written - no `web.audio` left in `sound.zig`, the bridge's graph functions gone, the worklet and page tests
green - and wants its checks and its record. Open: the end of 7e3, 7f (new, below), 8 to 12.

**Every turn ends green.** Its targeted tests (`zig build test-codecs`, `test-sound`, `test-zimrnum`, filtered),
`lint-check`, the page built in `release`, the worklet test (`audio-worklet-test`) where the mixer or the worklet
changed; a journal entry and a snapshot. The full `gate` at the end of each numbered step, its parts run one at a time
in the foreground (`lint-check`, `lint-coverage`, `test-fast`, `check`, `audio-worklet-test`, `audio-page-test`,
`external-check`, `template-check`): this sandbox has one processor and kills a background run within minutes. A
tutorial changes in the turn its subject does, and is presented.

---

**7c. Vorbis: sound packets to samples** - 3 turns

*What.* `codecs.audio.vorbis.Decoder`: interleaved f32 frames at the stream's own rate, from a whole file in memory,
decoded packet by packet, nothing allocated once it has started.

*Design.*
- `Decoder.init(allocator, bytes)` reads the headers (7b) and allocates in their arena, sized by the long block, all a
  packet needs: each channel's spectrum (n/2) and block (n), the previous block's right half, the IMDCT's scratch (n/4
  complex values), floor 1's points (65) and its curve, the residue's classifications (channels times partitions),
  one window slope per block size. `deinit` frees the arena.
- Bits: a sound packet is read through a 64-bit accumulator, refilled a byte at a time - the headers' `BitReader` reads
  a run at a time, fine for headers only. Past the packet's end: zeros, and the packet ends there, the rest silence,
  as the specification says.
- Codewords: each codebook gets a table indexed by its next 10 bits, giving an entry and its length for codes of up to
  10 bits; longer codes go through a list of their bit-reversed codewords, sorted, searched by halving - stb_vorbis's
  scheme. A single-entry codebook gives its entry, reading its length's bits - as stb does, checked against it. A
  codeword no entry has, which only damage makes, ends the packet.
- A packet: its first bit 0; its mode (`bitLength(modes - 1)` bits); for a long block, the flags of the windows before
  and after. Each channel's floor 1: whether it is used; its two end heights, then each partition's heights by its
  class's books; each point predicted between its neighbours (`low_neighbors`, `high_neighbors`) and corrected; the
  curve drawn from point to point in order of X by the specification's integer line drawing, each value looked up in
  the 256-step decibel table - drawn after the residue (stb's deferred floor), for used channels only. The residues,
  submap by submap: types 0, 1 and 2, each partition's classification read with the classbook, passes 0 to 7 adding
  their books' vectors; a channel whose floor is unused gets none, unless coupled to one whose floor is used. Inverse
  coupling, its steps in reverse order. Floor times residue. The IMDCT: zimrnum's `imdct`, n/2 coefficients into n
  samples, scaled as Vorbis wants - the factor found against stb's samples (stb notes its own is a half off). The
  window: each slope sin(pi/2 * sin^2(pi/2 * (i + 1/2) / L)) for a slope of length L, the slopes' lengths set by the
  block sizes on either side; the overlap-add with the previous block's right half.
- Frames out: from the previous block's centre to this one's; none from the first packet; the last trimmed to the final
  granule position; none from an empty packet. `readFrames(out)` gives frames left from the last packet first, then
  decodes packets as needed; 0 at the end. `rewind()`, for loops: the reader moved to the first sound page
  (`PacketReader.seekToPage`), the overlap cleared, the first packet again giving none.

*Sub-steps.*
- 7c1 - the accumulator, the codeword tables, floor 1. Tests: every codebook of the sample decodes every one of its own
  codewords - written by the test from `codewords`, least significant bit first - back to its entry; floor 1's line
  drawing against the specification's `render_line`, worked by hand on a small floor; each window's two slopes meet
  w^2 + w'^2 = 1.
- **7c1 done (Oct 14).** `codecs.audio.vorbis`: `PacketBits` - the 64-bit accumulator, topped up a byte at a time to
  more than 56 bits, `peek` up to 32, past the end zeros and `is_past_end`; `CodebookDecoder` - the fast table by the
  next 10 bits (every index whose low L bits are the codeword reversed), the longer codes sorted by key (the codeword
  at the top of 32 bits), found by halving and checked, a single-entry book giving its entry; floor 1 -
  `readFloor1` (7.2.3), `floor1FinalHeights` (7.2.4 step 1, `floor1PredictedHeight` its `render_point`),
  `drawFloor1Line` (`render_line`, clipped to the curve), `drawFloor1Curve` (step 2); `floor1_inverse_db` built at
  compile time as 10^((i - 255) * 35/64 / 20) - a progression of exactly 35/64 dB a step, equal to the printed table
  to all eight of its digits; `fillWindowSlope` (4.3.1). Tests: the accumulator across bytes, zeros and its mark
  past the end; every codebook of the sample decoding each of its codewords back to its entry (the long path among
  them); floor 1's lines and heights worked by hand (5 to 1 over 7: 5 5 4 4 3 3 2; a point predicted at 30, moved to
  28, 32, 70); the table's ends; each block size's slopes power complementary to 1e-6. `test-codecs` 165 of 170 (5
  skipped). The sound tutorial's section 11, Reading Ogg Vorbis: pages and packets, the headers, a packet's bits,
  codewords (the specification's tree, the two tables), the floor (prediction, the integer line, the decibel table),
  windows (power complementary).
- **7c2 done (Oct 14).** Written in a turn that stalled before it could reply - its edits on disk, unreported - and
  found, checked and recorded in the next, after a second, partial start on the same code (a spectrum decoder) had
  been taken out again. `codecs.audio.vorbis.Decoder`: `init` from a whole file (headers, codebook decoders, every
  buffer sized for the long block in the headers' arena), `readFrames` (the last packet's frames first, then packet
  after packet), `decodePacket` (mode and window flags; each channel's floor read, drawn after the residue; residues
  by submap - `decodeResidue`, `decodeResidueVectors`, `decodePartition` with `PartitionLayout` spread or row, type
  2 interleaved; a floor-unused channel skipped unless coupled to a used one; coupling undone last step first,
  `uncouple`; floor times residue; zimrnum's `imdct`; `applyWindow` with `BlockWindow` - each slope half the smaller
  block, a short slope inside a long block centred a quarter from its end; `overlapAndKeep`), `trimToGranule` (the
  last packet cut to the final granule). The reference, `zig build vorbis-reference`
  (`tools/vorbis_reference/`, stb_vorbis.c built by zig's C compiler into that test alone): stb 4 236 528 frames,
  the engine 4 236 528; the largest difference 2.98e-7, the plan's bound 1e-4; amplitude ratio and correlation
  1.000000 - the IMDCT needs no scale beyond zimrnum's. Tests in `codecs.zig`: the sample decoded whole (its frame
  count, every sample finite, its peak). The sound tutorial's 11.7 to 11.9: the residue, coupling, from spectrum to
  samples - their entries now in its contents.
- 7c2 - residues, coupling, the IMDCT, the overlap-add: the sample decoded whole. The reference:
  `tools/vorbis_reference/`, stb_vorbis.c (public domain; a reference, never shipped) and a Zig test of its own step,
  `zig build vorbis-reference`, linking stb through zig's C compiler, decoding the sample with both and comparing frame
  by frame. Pass: 4 236 528 frames each, and every sample within 1e-4 of stb's - sums taken in another order differ by
  far less, a wrong sign or index by the signal's own size.
- **7c3 done, and with it 7c (Oct 14).** `Decoder.rewind` - the reader back at the first page of sound
  (`first_sound_page_offset`, the reader's next page after the three headers, Vorbis beginning its first sound
  packet on a page of its own), the overlap forgotten, nothing pending; an empty packet gives nothing and leaves the
  overlap for the next (`decodePacket`). Tests: rewound after 100 reads, and again from the end, the sample decodes
  to the same frames (`FramesDigest`: count, sum of squares, every sample's bits mixed in); beside a plain decoding,
  the first sound packet giving no frames, an empty packet none and the frames after it unchanged, a packet cut in
  half giving its full count of finite frames; a damaged 40th page skipped and counted once, the decoding running to
  the end. Vorbis tests 13 of 13; the test binary 289 passed, 5 skipped. The gate, its parts run one at a time
  (lint-check, lint-coverage, test-fast, check with the corpus 62 of 62, audio-worklet-test, audio-page-test,
  external-check, template-check): green. Two background gate runs had been killed in the sandbox after a few
  minutes - the first leaving an orphaned build that competed with the second, whose test binary then failed under
  load and passes alone - so a gate here runs its parts in the foreground, each within the command's time.
- 7c3 - the edges: the first packet's frames discarded and the last's trimmed (the frame count is the final granule);
  an empty packet; a packet cut short in its residue (decoded, its rest silent); `rewind` (the second pass equal to the
  first); a damaged page (skipped, counted, the decoding going on).

*Done when* the sample decodes to stb's frames within 1e-4, the edges tested, `gate` green.

*Risks.* Speed: decoding runs on the game's thread, about one packet a frame (a long block each 23 ms at 44 100 Hz);
the IMDCT through zimrnum's FFT is not stb's tuned kernel - measured on Simon's phone once 7d plays, tuned only if a
frame shows it. The IMDCT's scale and the window's slopes between block sizes are where decoders go wrong; the
comparison with stb catches both. No mono file to test with - the sample is stereo; mono goes through the same code
with one channel and no coupling, and is tested on a hand-made packet if one can be built from the sample's setup.

**7d. Music on the mixer** - 1 to 2 turns

*What.* `z.music` plays through the mixer on every platform - a decoder feeding a stream, which a stream voice reads -
natively, headless, and on a page through the worklet (step 6). Ogg plays natively for the first time.

*Design.* A music entry holds its decoder - Vorbis, or a WAV reader over its samples - and a stream of the stream table
(`streams`). `music.update`, called each frame as raylib's `UpdateMusicStream` is, decodes while the stream wants frames
(`isProcessed`: half its ring free), half a ring at a time. At the decoder's end, if looping, `rewind` and write on -
the seam continuous in the ring; if not, the stream plays out and the music stops. `play`, `pause`, `resumeMusic`,
`stop`, `setVolume`, `setPitch`, `setPan`: the stream's. `getTimePlayed`: frames decoded less the frames still in the
ring, over the rate; `getTimeLength`: the final granule over the rate. `loadFromMemory` reads the headers only - nothing
is decoded ahead, so a song loads at once. The music keeps its file's rate (44 100 for the sample); the stream voice
converts it to the mixer's 48 000.

*Verified.* Headless, `music_streaming` held 3 s: its capture's level, and its largest second difference within the
sample's own (no break between blocks, nor at the ring's turns); looping: the sample played past its end, the seam's
second difference within the signal's own; time played rising with the frames played. The page built; Simon hears it
on his phone.

*Done when* the sample plays, loops without a click, and its time reads right, natively and on a page; the sound
tutorial's 2.7 rewritten as "Music".

- **7d done (Oct 15).** Written by a turn that stalled before replying, its edits on disk (`sound.zig`'s music
  rewritten, the example, the tutorial's 2.7), and finished in the next. `z.music`: a source - the Vorbis `Decoder`,
  or a WAV converted to frames whole (`WavSource`) - feeding a stream of the stream table; `update` reads half a ring
  while the stream asks (`isProcessed`), and at the source's end a looping music rewinds and reads on into the same
  write, the seam inside the ring; one not looping plays out and stops (`queuedFrames` 0). `getTimePlayed`: frames
  written less those queued; `getTimeLength`: the final granule over the rate; `seek` (`positionSource`) decodes from
  the start to the frame, exact and slow until 7e1's page seek. Nine music tests in `sound.zig`. Checked headless
  with `music_streaming` (450 by 800): PLAY, 3 s - sound from the tap on, RMS 0.047, the largest second difference
  1.20 of the signal's 99.99th percentile, no break between blocks or at the ring's turns; the screen "3s / 96s";
  seeking to 0.5 s before the end and playing 3 s across the loop - the largest second difference 1.39 of the signal's
  own, and the 10 ms levels round the seam the reference's (libsndfile's decode of the sample) end-then-start to
  within a few thousandths: the song fades to near silence over its last 40 ms and ramps up over its first 10 - a
  102-frame run of exact zeros at the seam is the song's own. The page built. The example's caption shortened to fit
  its 450 pixels and its title and line moved under it. The queue test of `sound.zig` ("a queue between two threads")
  made each side yield when the queue is full or empty (`std.Thread.yield`, spinning where it cannot): spinning, it
  took minutes on this one-core machine, a time slice per eight items - `test-fast` had timed out on it. Gate, by
  parts in the foreground: green. On Simon's phone: to hear.

- **Review of 7c2, 7c3 and 7d (Oct 15).** The decoder against damaged input: every index a packet uses - mode,
  mapping, submap, floor, residue, book - checked when the setup is read; a residue's book without vectors refused
  there and checked again when decoding. One fault, in 7d: `music.update`, at the source's end, rewound a looping
  music and read again - for ever, within one frame, for a source giving no frames even from its start (a file whose
  sound is all damaged, or whose last page claims a length its packets do not hold; a decoder failing to allocate
  reads as none). It now rewinds once without frames between, and the source then ends as a music not looping does
  (`is_just_rewound`). Test: the sample cut at its first page of sound, a length claimed, looping - `play` returns and
  the music ends. Seeking a Vorbis music decodes from the start to its frame on the caller's thread - some 0.7 s
  stalled for a seek near the end of the sample: known, and 7e1's page seek. The long runs Simon asked about: the
  queue test's spinning on this one-core machine (fixed in 7d), the disk full (cleared), and builds of two sessions
  at once. `test-fast` 286 passed, 5 skipped.

**7e. Seeking, the analyser, the graph removed** - 2 to 3 turns

- 7e1, *seeking.* `Decoder.seekToFrame(frame)`: halving over the file's pages by granule position to the last page that
  ends before the frame; decoding from its next packet, that packet's frames discarded (it only primes the overlap),
  then frames discarded up to the exact one. `music.seek(seconds)`: the stream stopped and its ring retired, the decoder
  moved, writing again. Tested in the reference step: the frames from 30 s on equal stb's after `stb_vorbis_seek`; a
  seek to 0, to the last frame, past the end (clamped).
- **7e1 done (Oct 15).** `Decoder.page_marks` - the stream's pages of sound that end a packet, their offsets and
  granules, listed when the decoder is made (`markPages`: checksums checked, other streams' pages and damaged ones
  passed over). `Decoder.seekToFrame(frame)`: halving over the marks for L, the last page ending at or before the
  frame; decoding from the mark before it, S - the reader passes over the packet continued into a page and the first
  packet decoded only primes, so starting at L could lose the frames just after its granule, the packet ending there
  begun on S; frames before the first packet ending a page - its granule anchoring every position after - dropped;
  then on to the packet holding the frame, started at it. A frame before S can exist: from the stream's start,
  positions known from 0. The stream's last packet trimmed to its granule as in `readFrames`. `music.seek` and
  `play` position a Vorbis music by it (`positionSource`) - a few thousand frames decoded wherever it lands, no longer
  everything before it. Test: seeks to 0, 1, 1 000, 30 s + 7, 61 s + 12 345, 5 000 before the end and the last frame
  each give the next frames bit for bit as the stream read straight through - which itself matches stb within
  2.98e-7, so stb's own seek is not compared again; at the end and past it, nothing; from 100 000 before the end, the
  rest to the end exactly. Codecs 170 passed, 5 skipped; `test-fast` green.
- **A deep review of 7c to 7e1 (Oct 15, Simon: "Review deeply the last few turns. Look for bugs, opportunities for
  improvements").** The sample was the only stream the decoder had been held to - stereo, residue type 2, one submap,
  one coupling step - so residue type 1, mono, more channels and several submaps had never been checked. A corpus of
  eight streams beside the reference (`tools/vorbis_reference/corpus/`, made by libvorbis through libsndfile 1.2.2;
  106 KB of Ogg and 56 KB of reference frames): mono at 44 100 and 22 050 (low quality) - residue type 1; stereo at
  8 000 (low) and 48 000 (high); three, four and five channels; and 5.1, its low-frequency channel a second submap
  with a two-point floor and a type 1 residue beside the other five's type 2. Each stream within 4.8e-7 of stb_vorbis,
  frame counts equal - but for 5.1, where stb_vorbis is wrong: its peaks reach 23 where libvorbis's stay under 0.87;
  the engine matched libvorbis within 3e-7, and ffmpeg's decoder (its 5.1 order undone) both within 4e-7. Found by
  following the bits: every packet's floors and residues ended within its last byte, the spectra and blocks sane - the
  fault was the reference's. That stream is held to every 53rd frame of libvorbis's own decoding instead
  (`CorpusStream.libvorbis_strided`). Residue type 0, which libvorbis never writes, stays unchecked. And
  `seekToFrame` now starts two marked pages before L, at R: from S, S's last packet - whose granule gives the first
  position - could be the one passed over, leaving no position known before the stream's last packet if L ended the
  stream, its padding then untrimmed; from R, S's last packet is always decoded. The seek test bit for bit as before.
  Opportunities left: music refuses more than two channels (a downmix would play 5.1); a WAV music is converted whole.
- 7e2, *the analyser on the mixer.* The renderer writes each block, mixed to mono, into a ring of its last 2048 frames -
  one writer, the renderer; read whole by the main side. Natively and headless the main side copies it; on a page it
  asks the worklet (`{ kind: "analysis" }`, at most once a frame, only while an analyser is attached), which posts the
  ring's frames in order. The main side: a Blackman window, `zimrnum.rfft`, magnitudes in decibels, -100 to -30 dB onto
  0 to 255, smoothed by 0.8 from one read to the next - Web Audio's `getByteFrequencyData` at its defaults, so that
  `audio_spectrum_visualizer` draws as it did. `attach`, `read`, `detach` keep their names and arguments. Tested:
  headless, a 440 Hz sine's peak in 440 Hz's bin, and the bytes against the same sums done in the test.
- **7e2a done (Oct 15): the analyser on the mixer, natively and headless.** `Renderer.analysis_ring`: the last 2048
  frames mixed, each the mean of its channels (Web Audio's own downmix), written after each block
  (`recordForAnalysis`) - each sample's bits by an atomic store, the position with release; `copyAnalysisFrames`
  reads the last N with acquire, oldest first. The mixer holds `analyser_capacity` (4) `AnalyserSlot`s - each its
  size and its bins' smoothed magnitudes - and one analysis's room. `analyser.attach` claims a slot (a power of two
  from 32, at most 2048), `read` analyses (`analyseFrames`: the Blackman window, `zn.rfft`, |X[k]| / N, smoothed 0.8,
  -100 to -30 dB onto 0 to 255, floored, a silent bin's minus infinity 0), `detach` frees it; on a page - the mixer
  forwarding to the worklet - the browser's node still, until the worklet hands its frames over (7e2b). The section
  moved after music, a consumer of everything mixed. Test: the 440 Hz test sine as a looping music, 16 blocks, a
  2048 analyser - the peak in bin 18 or 19 above 200, and all 1 024 bytes within 1 of the same steps summed in the
  test in f64, the transform a plain sum. Headless, `audio_spectrum_visualizer` draws for the first time natively:
  880 Hz a sharp peak mid-axis, 110 Hz the low bars. Its page built. Sound tutorial 2.8 "The analyser".
- **7e2b done (Oct 15): the analyser on the mixer on a page.** The analysis is the mixer's everywhere; the browser's
  `AnalyserNode` no longer serves it (`Analyser.id` gone; its bridge functions are 7e3's to remove). On a page a read
  takes the frames the renderer worklet's last answer brought and asks for the next (`ForwardingOutput.ask_analysis`,
  `take_analysis_frames`, optional - a test output has none, and its analyser reads silence): the web platform's
  `askAudioAnalysis` and `takeAudioAnalysisFrames`, `web.dom.audio_ask_analysis` and `audio_take_analysis_frames`,
  the bridge's `js_audio_*`, page audio's `askAnalysis` (one request waiting at a time; none unless the worklet
  plays), `acceptAnalysis` (the answer's bytes kept as a `Float32Array`, pinned, the last one freed) and
  `takeAnalysisFrames` (the newest frames set into the app's memory). The worklet: `{ kind: "analysis" }` answered by
  `sendAnalysis` - `worklet_abi.copy_analysis` (`workletCopyAnalysis`, the ring into `WorkletState.analysis_frames`),
  the bytes sliced out of the instance's memory and handed over as `{ kind: "analysis", bytes }`. The worklet and page
  test module gained zimrnum (`audio_test_zn_mod`), the mixer's analysis room typed by it. Tests: the worklet's
  answer to a note held 20 quanta is the last 2 048 frames it played, each the mean of its channels, bit for bit
  (`audio-worklet-test`); through page audio and the paired ports, nothing before an answer, then the newest 1 024
  frames copied into the app's memory, bit for bit the last blocks' means (`audio-page-test` - its context now keeps
  the right channel's blocks too). The visualizer's page built. Sound tutorial 2.8's last paragraph rewritten.
- 7e3, *the browser's graph removed.* With music and the analyser moved, its last users are gone: the bridge's older
  `js_audio_*` functions (decoding, buffers, sources, gains, the analyser node, the second context), `web.zig`'s imports
  of them, `sound.zig`'s `web.audio` calls (47 today) and their lint directives. A page then holds one audio context,
  the worklet's. Checked: `audio_stream_synth`, `music_streaming` and `audio_spectrum_visualizer` captured headless and
  built for the page; the other sound examples built (`audio_keyboard`, `audio_mixer`, the scale stars);
  `audio_page_test.cjs` and `audio-worklet-test`.

*Done when* `gate` is green with no `web.audio` left in `sound.zig`, and Simon hears the three examples on his phone.

*State, Oct 15.* The removal is written (a turn that stalled before it could report: `web.zig` 746 lines fewer, the
bridge 526, `sound.zig` 145): no `web.audio` in `sound.zig`; lint, `test-sound`, `audio-worklet-test` and
`audio-page-test` green; the visualizer's and the stream synth's pages built. Left: the three examples captured
headless, the gate, the record - one short turn.

- **7e3 done (Oct 16).** Its checks, the removal having been written by a stalled turn: the three examples run headless
  with their sound captured and measured - `music_streaming` played, its last half-second the song itself from 70.683
  s at correlation 0.9997 after a seek the tap set to 70.19 s and a second's play (the decoder, the stream, the
  mixer's rate conversion and the seek, all exact); `audio_stream_synth` held at mid-height, 440.0 Hz, the
  logarithmic pitch's middle; `audio_spectrum_visualizer`'s 880 Hz tap, 880.0 Hz. The gate, its parts in the
  foreground: `lint-check`, `lint-coverage`, `test-fast` (13 runs), `check` (the corpus 54 ok - 62 in an earlier
  gate's log, a count of different runs, nothing failing), `audio-worklet-test`, `audio-page-test`, `external-check`,
  `template-check` - green. A page holds one audio context, the worklet's.
- **7f prepared (Oct 16).** The five sound examples built for Windows in `release` (40 to 60 seconds each):
  `audio_keyboard`, `music_streaming`, `audio_spectrum_visualizer`, `audio_stream_synth`, `audio_scale_star_hands`,
  packed with a checklist (`zimr-windows-sound-test.zip`) - each heard; the music's loop and seeks; the analyser's
  bars; headphones plugged in mid-play; the readout's lines. Waiting on Simon's report.

- **The sound tutorial rewritten (Oct 16, Simon: "Audit the sound tutorial. Make it 20 or 40% smaller, better
  organised. Neutral tone... No anecdotes, war stories, things that could exist but dont. Focus on explaining how the
  code works, how to use it").** Prose from about 14 300 words to about 8 500, the page from 192 KB to 170 KB (the
  code folds are most of its bytes). Nine chapters: sound as numbers; using sound (starting the output first); voices
  and their names; a block's arithmetic, the limiter now with the summing it guards (with `limitAndBend` and
  `softClip`); the two sides; outputs, the browser taking in the forwarded streams and the analyser's frames; the
  instruments, the Shepard section limited to the instrument; timing, the frame's wait as its first term; Ogg Vorbis,
  with a section on seeking by pages (`seekToFrame`) and the coupling rule (`uncouple`). Gone: the unbuilt input paths
  (bindings, `on_input`, placing notes by their timestamps), the comparison with other engines, the scale star's own
  behaviour, the WAV header table. Corrected: seeking (no longer from the start), the block's last stage (no longer
  held to -1..1 - and `Mixer.mixInto`'s comment, which said so). `check`: 29 code blocks, none stale.

**7f. Sound heard on Windows** - 1 turn, then Simon's ears (new, Oct 15)

*Why now.* The WASAPI output was written and reviewed on Oct 10 and has never been heard: every step since - the
mixer's streams, music, the decoder, the analyser - stands on it untried on a machine. Steps 8 to 11 measure and tune
what it plays; they mean nothing until it plays. *What.* The sound examples built for Windows (`zig build
<app> -Dplatform=windows`: `audio_keyboard`, `music_streaming`, `audio_spectrum_visualizer`, `audio_stream_synth`,
`audio_scale_star_hands`) and a checklist for Simon: each heard; music looping without a click and seeking; the
analyser's bars moving; headphones plugged in mid-play moving the sound (the default-device change); the readout's
stream line and its underrun count. *Done when* his report is here; its fixes are the next turn's, and his readout's
numbers are step 11's input.

**8. The worklet path measured** - 1 turn, then Simon's numbers

*What.* The latency readout complete on a page, and its numbers written here. It shows `t2` (request to applied) and
`t3 + t4` (applied to heard) from the worklet's clock; missing are `t1` from the key's own time, and the browser's own
latencies on the line.

*Design.* The bridge passes each key and pointer event's `event.timeStamp` - on `performance.now()`'s clock, which
`audioClockMilliseconds` reads - with the event; the contract's events gain a time in milliseconds (0 where a platform
has none, as Windows until step 9's input thread). A note or play started in the frame that read the event is
requested at the event's time, so `t1` is the frame's wait. The readout's line adds `baseLatency` and `outputLatency`.

*Verified.* Headless, scripted events with times give the `t1` expected; `audio_page_test.cjs`, a `keydown` carries its
time to the event. *Done when* Simon's readout for `audio_keyboard` on his phone is here term by term - `t1` (the
frame's wait, about 8 ms at 60 Hz), `t2`, `t3 + t4` - and has decided whether 9 and 10 come next or the worklet's
buffer first.

- **8, first half done (Oct 16).** A press's time, end to end: the contract's `KeyDown`, `MouseButton` and `Touch`
  carry `time_ms` (0 where the platform does not say - Windows and headless for now); the bridge passes
  `event.timeStamp` to `input_push_key_down`, `zimr_input_push_touch_down` and `input_push_mouse_button_down`
  (`eventTimeOrZero`: a missing time is a NaN, read as 0); the input keeps each key's press time and the latest press
  (`InputState.key_press_times_ms`, `last_press_time_ms`, `pushPressTime`; `z.getKeyPressTime`,
  `z.getLastPressTime`). `NoteEvent.pressed_at_ms` and `PlayOptions.pressed_at_ms` carry it to the renderer,
  `LatencySample.pressed_at_ms` back; the readout's line gains `frame`, t1 - request less press - or a dash, the
  total counting it. `audio_keyboard` passes the key's time, and the pointer's for a note its press started. Found:
  on the worklet's path the page's table had no lines at all - the worklet's renderer measured nothing (its blocks
  carry no timing: `RendererHost.render` sets no `current_block_timing`) and notices carried no measurements; the
  plan above was wrong to say t2 and t3 + t4 showed there. Now `RendererNotice.start_measured` carries a renderer's
  measurements back (`takeNotices` drains them; `keepRecentStart`). Left for the second half: the worklet's blocks
  timed on the page's clock - the context's `currentTime` mapped to `performance.now()`'s through the page's
  `getOutputTimestamp()` pairs - so that the worklet measures. Tests: the input's press times; a play's and a note's
  press time measured and returned; the line with and without a press time, its columns under the header's.
  `test-sound` 266 passed, `test-fast`, the worklet and page tests green; `audio_keyboard`'s page built.

- **8, second half done (Oct 16): the worklet measures on the page's clock.** The context's timeline tied to the
  page's clock: page audio, at each reading of `getOutputTimestamp` (`readOutputContinuity`, four a second), sends
  `{ kind: "clock", contextMs, pageMs }` - the moment heard, less `outputLatencyMilliseconds`, is when it was rendered
  (`tieWorkletClock`); the instance keeps it (`workletTieClocks`, `WorkletState.clock_tie`) and times each block by its
  `currentFrame` (`workletTimeBlock`, called by the program before each render), the time both its ask and its first
  frame out - on this path a block leaves as it is made, the browser's buffering all in `past`. Found on the way: a
  note forwarded to the worklet lost its times - its message carried key, down and velocity - so no page could have
  measured a note; `ForwardingOutput.send_note` now passes `requested_at_ms` and `pressed_at_ms`, through the web
  platform, `js_audio_forward_note`, the bridge and page audio's `forwardNote` into the message (`requestedAt`,
  `pressedAt`), and the program hands them to the instance first (`workletStampNote`; `callExport` takes four numbers at
  most). The Node tests' records gained the times, and both tests read a record's size from the test module
  (`zimr_audio_test_record_words`) - the page test had its own 8, which the change broke. Test (`audio-worklet-test`):
  the tie 2 000 ms to 9 000 ms, a note requested at 9 004 ms, its block at frame 96 480 - measured at 9 010 ms on the
  page's clock and returned to the main side. Sound tutorial 8.2: the tie, with that example. Waiting on Simon's
  readout from `audio_keyboard` on his phone - step 8's end.

- **The audio start screen (Oct 16, Simon: "All examples that have sounds should have a splash black page with a
  simple start button in the middle as a simple ui button with the word start. This way we can start the audio system
  before the first sound and hopefully avoid the initial gitch").** `z.showAudioStartScreen(f, &font)`
  (`wgpu_app.showAudioStartScreen`): a black page, one button "start" in its middle in the UI's dark style - drawn by
  the frame's own calls, since seven of the eleven sound examples have no UI host - shown until pressed and the
  output settled (`isAudioOutputSettled`: the web platform's, path 3, 4 or 0 - the worklet running or failed, or the
  script processor - and not 2, starting, or 5, waiting for a gesture; natively the press alone). Its state in the
  audio device's (`is_start_pressed`, `is_start_screen_done`). All eleven sound examples call it first in their update.
  `audio_scale_star/check.script` presses it within its first six frames, its keys' times unchanged - the sound check
  14 windows, 0 failed. Found: `draw2d.TextOpts` said a null font draws in the sink's default; `WgpuGl.text` draws
  nothing without one - the comment corrected. Checked headless (`music_streaming`): the screen, the button lit under
  the pointer, the app after the press. All eleven pages built; lint and `check` green. Sound tutorial 2.1.

*Order, Oct 15: 10 before 9, and 9 only if the numbers ask for it.* `on_input` (10) runs the app's own code as each
event arrives, which covers every app - the scale star included - where bindings (9) cover only keys bound in
advance. On a page both reach the worklet at once provided the command a callback makes is forwarded at once: the
mixer's batch is sent after each `on_input` call, not at the next frame (added to 10's design). What bindings add
beyond it is an input thread on Windows, a start that does not wait for a main thread busy drawing a long frame; with
frames of 16 ms that is worth its two turns only if Simon's readout shows `t1` still long after 10.

**9. Bindings** - 2 turns

*What.* The input path's first half: a key plays its note or sound without waiting for a frame, resolved by the engine
where the key arrives - no app code off the main thread.

*Design.* `z.audio.setBindings(device, bindings)`: `{ key, action }` pairs - a note (key number, velocity) or a sound (a
`Sound` already registered with the renderer, so that the input side registers nothing) - copied by the engine and
swapped in whole, so that an input thread reads one table, never half of two. The key is still recorded for the next
frame's polling, to be drawn.
- Browser: the bridge's `keydown` and `keyup` handlers look the key up first; a note posts `{ kind: "note" }` to the
  worklet's port at once (on the pulled path, no worklet, it is applied on the main thread); a sound posts a trigger.
- Windows: an input thread on raw input (`RegisterRawInputDevices`; keys only while the window has the focus), a
  bitset of the keys it pressed (repeats ignored), every bound note released when the focus leaves (blind spot 7).
  Notes through `sendNoteFromInputThread` (built and tested, unused until now); sounds through a fourth queue, a
  trigger naming registered samples, which the renderer starts in a free main-side slot and reports.
- Headless: at the scripted event, before the frame.

*Verified.* Headless, a bound key's note starts at its event, not at the next frame; `audio_page_test.cjs`, a `keydown`
posts its note with no update run; the input thread's bitset and focus release tested on the host, Windows
cross-compiled. *Done when* `audio_keyboard` binds its keys and Simon's readout shows `t1` near 0 for them, on his
phone and on Windows.

**10. `on_input`** - 1 to 2 turns

*What.* The input path's second half: app code called as each event arrives, between frames, on the main thread.

*Design.* `AppSpec.on_input: ?fn (*Frame, *State, InputEvent) void`: the app's state and the mixer are its to use (one
thread, no locks); it does not draw - its frame has no render pass; the event is still recorded for the next frame's
polling. After each call the mixer sends what the call asked (`mixFrame`'s forwarding, or the commands applied for a
pulled output), so that a note started there leaves before the next frame. Browser: called from the bridge's event
handlers. Windows: the loop waits on its messages and the swapchain's
readiness together (`MsgWaitForMultipleObjectsEx`), so that a message arriving mid-wait is handled at once. Headless:
at each scripted event.

*Verified.* Headless, a sound started from `on_input` is requested at its event's time. The two-hand scale star - the
app Simon plays most - starts its notes from `on_input`, and its readout shows `t1` near 0 on his phone. *Done when*
both platforms call it between frames, measured.

- **10, first half done (Oct 16): `on_input` on every platform's delivery.** `AppSpec.on_input: ?fn (*Frame,
  *State, InputEvent) void` (`InputEvent` = the contract's `Event`), registered by the runner (`App.setInputHandler`)
  and called by `receiveEvent` - the web's exports and the native loop's `deliverInput` alike - for each press and
  release, once the input has recorded it (`dispatchInput`): a frame from `makeFrame(null)` at the last ticked time
  (`App.last_elapsed_s`), then `mixer.mixFrame()`, so that a sound it started leaves at once - forwarded to the
  worklet on a page, already queued for the audio thread natively. Held back while the app's start screen shows
  (`is_start_screen_shown`, set by `showAudioStartScreen`): the press on its button is the screen's. The launcher's
  erased apps (`eraseApp`) do not have it yet. `audio_keyboard` plays its keys and its pointer's presses and releases
  from it (`onInput`), the pointer's glides each frame, and reads the computer keyboard each frame only until a first
  event arrives (`is_input_from_events`) - in a launcher, as before. Checked headless: the start press, then A -
  middle C, 260 Hz in the capture, from `onInput`. Both pages built; lint and `test-fast` green. Sound tutorial 8.1.
  Left: Windows' loop waking for a message mid-wait (`MsgWaitForMultipleObjectsEx`), so that `on_input` runs there
  between frames too; the two-hand scale star on it; and the measurement on Simon's phone - `frame` near 0 for
  `audio_keyboard` now.

- **10, the scale star on it (Oct 16).** `audio_scale_star_hands` reads its fingers and digit keys again on each
  press and release (`onInput`: `readPointers`, `readDigitKeys`, then `startDueHolds`) - both readings follow what is
  held, not what changed, so the frame's own after it finds nothing new; while the options panel is open the press is
  the panel's, which only the frame's UI knows, and the frame reads it. Checked headless at 900 by 415: the start press,
  then I held - C, E and G in the capture. Its page built. Left for 10: Windows' loop waking mid-wait, and Simon's
  phone readout.

- **10 on Windows, designed and held back (Oct 16).** Where the Windows frame waits: not in the loop - it pumps,
  delivers and draws with no wait of its own - but inside the frame's start (`wgpu_vulkan.acquireImage`): the timeline
  wait for the frame slot's last present, then `acquireNextImageKHR(no_timeout)`, which FIFO holds until a vsync frees
  an image. Both run in `beginDrawing`, which an app managing its own frame calls from its own update - so input
  delivered there would call `on_input` from inside `update`. The design: the loop waits for the frame's readiness
  before the frame - the slot's timeline value read (`vkGetSemaphoreCounterValue`), the image acquired with a timeout
  of 0 and kept for the frame - and between tries waits on `MsgWaitForMultipleObjectsEx` for at most a millisecond,
  pumping and delivering what arrives, `on_input` with it; the frame then starts with its image in hand. Held back
  until Simon's first Windows report: that report is the first run of the sound on a Windows machine, and a change to
  how Windows draws its frames now would mix a rendering fault into it.

**11. The Windows device buffer** - 1 turn, when Simon's Windows numbers arrive

*Design.* Blind spot 1: the low-latency stream opens only at the device's own mix format - a 44 100 Hz device falls
back to the standard stream today, silently. Opened at `GetMixFormat`'s rate and channels, the output converting the
mixer's 48 000 Hz, or the renderer running at the device's rate (its arithmetic already takes a rate) - decided by
Simon's numbers. Blind spot 2: the standard stream asks one period, 10 ms, not 20.

*Verified.* Cross-compiled; the readout's stream line on Simon's machine. *Done when* his numbers are here, the buffer
is the smallest his device runs without dropouts, and a default device changed mid-play (7f's headphones) is heard to
follow.

**12. The debts** - 1 to 2 turns

- *Blind spot 5, a note placed by its time.* Every start is applied at its block's first frame: up to a period of
  jitter, 10 ms on Windows' standard stream. The renderer places a start at its own frame in the block - its request
  time against the block's - splitting the block's render there; an instrument's option, the next block staying the
  default (decided Oct 11). The readout shows the jitter: the spread of `t2` over the last ten starts. Tested: two notes
  requested 1 ms apart begin 48 frames apart in the output.
- *c2js:* `js_free`, and the `(&x)->field = value` it drops - each with a c2js case that fails before the fix.
- *`verify_imports` folded into `bridge_import_check`:* one check of the page's imports, run by the gate.

*Done when* each has its test and `gate` is green.

---

- **12, the first debt paid (Oct 16): a note placed by its time.** `Instrument.places_notes_by_time` (off by
  default): a note starts as far into its block as its request came after the block before was asked for
  (`Renderer.placementOfNote` - `previous_block_asked_at_ms`, kept at each timed block's end; `current_block_frame_count`);
  a note with no time, no timed block before it, or a wait longer than a block starts at the first frame. The voice
  mixes from there (`VoiceSlot.start_delay_frames`, `mixVoiceInto`'s `delayed_block`). On a page the same: the request
  and the block are both on the page's clock (the clocks' tie). Test: against the unplaced note, requests 0.5 and 1.5
  ms after the block before start 24 and 72 frames later - 48 apart for 1 ms; one requested before it, at the first
  frame. `test-sound` 267 passed. Sound tutorial 7.2. The readout's jitter line (the spread of `t2`) not done; the c2js
  debts and the import check's folding left.

- **12, the c2js debts looked into (Oct 16).** `js_free` and handles of `undefined`: already fixed - a freed slot
  holds a marker of its own (`__freedSlotMarker`, or a tombstone when debugging handles; `__isFreedSlot`), and the page
  test frees a handle of `undefined` in each of 2 000 frames, the table flat. The dropped `(&x)->field = value`: still
  dropped - a new case, `optional_field_from_literal` (an optional struct field set from a literal through a global, a
  pointer and a local, then read back), fails in c2js: the global's optional reads empty. And `c2js-diff`, which is not
  among the gate's parts, has eight more failures nobody had seen: `global_ptr_array_index`, `memcpy_arrays`,
  `memset_memcpy`, `memset_struct_array`, `odd_width_aggregate`, `ptr_array_elem_store_u64`, `ptr_to_array_field`,
  `u64_array_store` - cases whose headers describe fixes once made. Their C, from this Zig, reaches a named object's
  field through its address in two pairs of parentheses (`&((&tbl))->array[t2]`), and c2js lowers the element's address
  as a property read off the object's address (`((1032)).array[t2]`). Tried and taken out again: rewriting the form to
  `x.field` before parsing (other cases broke) and bringing it to one pair of parentheses (nothing changed) - the
  handler these cases relied on matches neither, and is to be found and read before it is changed. Next: that handler
  and the member assignment beside it, until the nine pass; then `c2js-diff` joins the gate, so that a regression in the
  transpiler of the page's own code is seen the day it happens. The page's shipped code passes its own tests (the
  worklet and page tests), which do not meet these forms - page audio keeps a plain struct and a flag for the optional.

- **Simon's Windows report (Oct 16): "i tested sound on windows and all works."** 7f done. His photo of
  `audio_keyboard` (the Oct 15 test build, before the `frame` column): `output: WASAPI, low-latency stream`; five notes,
  wait 0.7 to 7.5 ms, queued 12.0 ms each, past 0.0, total 12.7 to 19.5 ms. For 11: the low-latency stream opens on his
  device (no fall back to the standard one), and holds 12 ms ahead of each start; `past` reads 0 - the stream's
  latency as WASAPI reports it for this stream, to look into. The Windows half of 10 (the loop waking mid-wait),
  held back until this report, can go ahead.
- **12, the c2js debts paid (Oct 16).** The cause of the eight failures: Zig 0.17's C backend leaves out a cast it
  used to write in an element access through a fixed-array global - `&((struct arr_N_T *)&g)->array[i]` became
  `&((&g))->array[i]`, `&g` already having the wrapper's pointer type - and c2js took the element's type from that
  cast. Without it, the access became a property read off the global's address. Behind it, a record lost earlier:
  a fixed-array global's declaration recorded its address only, where a local array's records its element type and its
  wrapper; the casts had hidden it. Fixed: `recordArrayWrapperOfGlobal`, from both places a global array is declared
  (the string-initialized one in `prescanData` included) - its element type, its wrapper's tag (`global_array_wrappers`,
  new) and, with the layout, the tag as a struct's; `&g` records g's tag for a following `->field`, as the cast did, and
  `parsePostfix` drops a tag nothing read before its primary; one base parser, `parseArrayWrapperBase` (with
  `parseArrayFieldOpening`), for the element address and the element store, which had each a copy, the cast optional
  in both. And the dropped `((&LVALUE))->field = value` - an optional field's null flag after a literal: a narrow store,
  `tryAddressMemberStore`, through the place walker, scalar places only. Tried and taken back: rewriting the form to
  `x.field` before parsing, and to one pair of parentheses. `c2js-diff`: 103 agree with native, 2 JavaScript-only
  cases check out, none failing - the new case `optional_field_from_literal` among them; and it is now in `gate`
  (about 100 s). The worklet and page tests, and the pages, pass on it. Page audio's plain struct and flag, kept for
  the dropped null flag, could now be an optional again.
- **The page's output status an enum (Oct 16, Simon: "I dont like that there are numbers like that which should be an
  enum").** `page_audio.OutputStatus` (`script_processor`, `worklet_starting`, `worklet_running`, `worklet_failed`,
  `worklet_waiting_for_gesture`, numbered 0 to 4 - the gap at 1, a path removed with the browser's audio graph, gone),
  from `outputStatus` across the bridge as its integer (`js_audio_output_status`, renamed from
  `js_audio_output_uses_worklet`) to `web.dom.audio_output_status`, which reads it back with `@enumFromInt` - an
  integer the enum does not name stops a safe build; the web platform's `audioOutputName` and `isAudioOutputSettled`
  switch on it exhaustively. The page test names the statuses. `check` green.

- **Numbers that were names, swept (Oct 16).** In the sound and page code: `Analyser.slot` ("from 1; 0 for none")
  is `slot_index: ?u32` - an optional index, no `+ 1` and `- 1` around it; the test module's four
  `forwarded_*_kind: u32` constants are `ForwardedKind`, an `enum(u32)` the record's extern struct holds, and its
  `testNewestStart(field: u32)` takes `StartTime`; the two Node harnesses compare against named tables numbered as
  the module numbers them. Left as numbers on purpose: counts and sizes, the WebAssembly boundary's booleans (`1` for
  down, `@intFromBool`), the bridge's event codes an app chooses itself, `callExport`'s arity. `test-sound` 267, the
  worklet and page tests, the visualizer's page green.

- **The scale in the star's header (Oct 16, Simon: "show next to the mode name which notes are raised or lowered ...
  also list the chords names ... The dropdown item could use 2 lines ... accessible right from the app without going
  into option ... a button with the name ionian by default ... Same with the scale note, by default C ... at the left
  of ionian").** `audio_scale_star_hands`'s header (`buildHeader`, was `buildOptionsButton`): options, the tonic's
  dropdown, the mode's - their labels hidden (`##`); the options panel keeps the star's own boxes under "Star". The mode
  list, written each frame for the tonic (`writeModeLabels`), two lines an item: the name, and at the right the notes
  altered from the major scale (`writeAlterations`: each degree a semitone below the major scale's a flat, above it a
  sharp, a dash for none - Lydian #4, Dorian b3 b7, Phrygian dominant b2 b6 b7), ASCII as the app spells its notes;
  then the seven chords on the tonic (`chordLetterName` - C Dorian Cm Dm Eb F Gm A° Bb). Five modes in view, the
  list scrolling; its width the widest line's (`modeListWidth`). While a header list is open, `onInput` leaves the
  pointers to the frame (`is_header_list_open`), as for the panel. In the UI (`ComboOpts`): `lines_per_item` - rows
  as tall as that many lines, the closed box showing an item's first line (`firstLine`) - and `list_width`, a list
  wider than its box; a label's visible part is the text before `##` (`visibleLabelPart`); the scroll bar drawn from
  the list's own rectangle. Checked headless at the phone's size: the header, the list open, Dorian picked (the star
  in C Dorian, i, III on Eb, VII on Bb). The page built; lint and `test-fast` green.

- **11, the numbers it needs on the readout (Oct 16).** The 12 ms queued on Simon's low-latency stream, read
  against the code: the stream runs at the device's shortest period (`InitializeSharedAudioStream`), and at each of
  its signals the render thread fills the buffer's whole room (`streamUntilChange`), so a buffer less a period sits
  ahead of each block - 12 ms if the shortest period is the default 10 ms and the buffer about 22. To be decided from
  the device's own numbers: the readout's output line now names them (`audioOutputName` - the period, the shortest
  and the default, the buffer, in milliseconds; from atomics the render thread stores as a stream opens). A Windows
  test package (`zimr-windows-test-oct16.zip`: `audio_keyboard.exe`, `audio_scale_star_hands.exe`, a checklist)
  asks for that line and the `frame` column - the frame's wait on Windows as it is, before the loop's change (10).
  The loop's change, and the buffer's if the numbers call for it, go into the next Windows build together.

- **The backends tutorial's review (Oct 16): chapter 14 compares the platforms' sound.** Read from the sources -
  SDL3's `SDL_wasapi.c` and `SDL_emscriptenaudio.c`, `miniaudio.h`, `sokol_audio.h`, `sokol_app.h`, Mach's
  `sysaudio/wasapi.zig`. 14.1, the stream on Windows: SDL3 and miniaudio take the low-latency stream at the app's
  period, clamped, and write one period at each wakeup; sokol the standard stream, Mach the low-latency one at period
  0, both filling the buffer's room, as the engine does - which keeps a buffer less a period queued ahead of each
  block, where one period at each wakeup keeps a period: for 11, SDL3's and miniaudio's way. miniaudio's notes match
  the engine's fall-back: the low-latency stream takes no conversion flags, and its periods only in the mix format.
  14.2, sound in a browser: SDL3 and sokol a script processor; miniaudio a script processor, or Emscripten's
  WebAssembly audio worklets, which need shared memory and its headers; the engine's worklet shares nothing. 14.3, input
  that starts a sound: sokol_app's `event_cb` as events arrive (from Emscripten's callbacks, the window procedure), like
  `on_input`; SDL3's polled events or `SDL_AppEvent`; raylib's frame input. `check` green.

- **B9, first half (Oct 16): the unwritten platform.** One file, `src/platform/unwritten.zig`, for Linux, macOS and
  Android until each has its own - not three copies of the template, which would be one file thrice. Its 50 requests,
  generated from the template's own, each refuse by name at run time (`refuse`: once per request, through
  `console.log`, naming the system - Android by its ABI) and answer as a platform with nothing yet would - nothing,
  0, null, an empty text, an empty window, a closed socket; `startAudioPull` grants the format asked, and `log` works
  from the start (standard error, `console.zig`). The template keeps refusing at compile time, where the engine calls
  a request; this file refuses at run time because its purpose is the build. `platform.current`: a native build for
  another system than Windows is now on it (was headless - headless runs keep their own host kind). Its contract
  test (`requirePlatform`) in `platform.zig`'s; `test-fast` and lint green. Second half: the native loop's Win32
  code behind a comptime test of the system, refusing the window and its loop elsewhere; the Vulkan loader's names
  for macOS and Android (`native_os.zig`); and `zig build platforms-check` - the launcher compiled as an object for
  the web, Windows, Linux, macOS and Android, no system library needed to link it.

- **B9 done (Oct 16): `zig build platforms-check`, in the gate.** The launcher - every flagship - compiled for the
  web (its page), Windows (its program), and as objects for Linux (`x86_64-linux-gnu`), macOS (`aarch64-macos`) and
  Android (`aarch64-linux-android`) on the unwritten platform: compiled, not linked, so no system's libraries are
  needed. Their engines (`platform_check_engines`, from `platform_check_targets`) are the Windows module's twins with
  `host = "native"` and libc, wired into the engine-shader loop with the others; their contexts the Windows one's with
  the target's parts; their programs `nativeAppObject`. The native loop's `openWindow`, `run` and `finish` refuse off
  Windows (`has_window_loop`, comptime - the Win32 code never compiled there; `error.WindowUnwritten`). The Vulkan
  loader's names by system (`vulkan_library_names`: Linux `libvulkan.so.1`, Android `libvulkan.so`, macOS
  `libvulkan.1.dylib` then `libMoltenVK.dylib`). Found by the check at once: `dlsym`'s untyped pointer cast to the
  loader's entry point needed an `@alignCast` on ARM64, where code is aligned to 4 bytes (`native_os.zig`). Lint,
  `test-fast`, `check` green; backends tutorial 13.6.

- **Simon's second Windows report (Oct 16): "All sounds good."** The readout: `low-latency stream: period 10.0 ms
  (shortest 10.0, default 10.0), buffer 22.0 ms`; five notes, wait 2.2 to 9.7 ms, queued 12.0, past 0.0, total
  14.2 to 21.7. The guess confirmed: the driver has no shorter period than the default, and filling the buffer's room
  kept 22 - 10 = 12 ms queued. `frame` reads "-": Windows' input events carry no time yet (only the bridge passes
  the event's) - to come with the loop's change, which can stamp each message as it arrives.
- **11 (Oct 16): the low-latency stream kept a period and 2 ms full.** The engine reads a period and signals; the
  render thread has a period to write the next, its slack against a dropout whatever the buffer holds - what is kept
  beyond only delays each new sound. `fillTargetFrames`: the stream's period and `fill_margin_milliseconds` (2), at
  most the buffer; the standard stream, its period unreported, still filled; the first fill to the target too
  (`playOnDefaultDevice`). The output line names it ("kept 12.0 ms"). Expected: queued about 2 ms, totals about
  10 ms lower. Read again, SDL3 writes a period only when no more than one is queued (`padding <= sample_frames`) -
  at most a period queued; the backends tutorial's 14.1 corrected to each library's exact rule, and the engine's.
  Test package `zimr-windows-test-oct16b.zip` (both programs, a checklist asking for the readout and for clicks).
  Lint and `check` green.

- **10 on Windows (Oct 16): the frame's wait before the frame, input as it arrives.** The loop (`run`) now waits
  for the frame between `serviceWindow` and `update` (`waitForFrame`): it asks the host whether the frame can begin
  without waiting (`vulkan_host.tryAcquireAhead` - the slot's batch done, read with `readCompleted`; an image
  acquired with a timeout of 0 and kept, `image_acquired_ahead`, which the frame's `acquireImage` takes as it is), and
  between askings sleeps on the message queue and a high-resolution waitable timer together
  (`MsgWaitForMultipleObjectsEx`, `CreateWaitableTimerExW` with `CREATE_WAITABLE_TIMER_HIGH_RESOLUTION`, re-armed
  for 1 ms each time; an ordinary waitable timer where that flag is refused) - an ordinary 1 ms timeout would sleep a
  15.6 ms tick and miss the display's refresh. Each wake handles the messages (`serviceWindow`), so input reaches the
  engine and `on_input` as it arrives; `tryAcquireAhead` answers true whenever there is nothing to wait for here (no
  host, a swapchain to rebuild, an image out of date, an error), left to the frame's own acquire, so the loop never
  spins. Presses stamped at arrival (`ContractEvents.arrival_ms`, set by `serviceWindow`; on the clock sound is
  requested on), so the readout's `frame` reads on Windows. `acquireImage`'s preparation now `prepareAcquiredImage`,
  for both paths. Lint, `platforms-check`, `audio-scale-star-check` (14 windows) green; the sound tutorial's 8.1 and
  the backends tutorial's 14.3 say so. Test package `zimr-windows-test-oct16c.zip`: the readout, the picture's
  smoothness, resizing and minimizing, clicks.

- **Simon's third Windows report (Oct 16): "This is very good. 10ms is imperceptible."** `audio_keyboard`: `kept
  12.0 ms`; five notes, frame 0.0, wait 2.6 to 8.8, queued 2.0, past 0.0, total 4.6 to 10.8 ms - from 14.2 to 21.7 in
  the second build and 12.7 to 19.5 in the first. `frame` 0: `on_input` between frames, the frame's wait before the
  frame (10 done on Windows); `queued` 2: the buffer kept a period and 2 ms (11 done). What is left is `wait`, up to
  the device's 10 ms period, which only a driver allowing shorter periods shortens. The sound tutorial's 8.2 shows
  these lines as its example, and 6.2 explains the streams and the fill target.
- **C4, as it stands (Oct 16).** Its three examples (`worker_png`, `four_ways`, `ui_full_showcase`) build natively
  already - the pending list holds only `net_rtc_smoke`. What is missing is where the work runs: natively a job runs
  inline (`jobs.zig`'s `runInline`), freezing the frame it was meant to spare - the 240 ms PNG encode the module's
  header measures. Saved state: Windows' is its own Win32 file calls; the unwritten platform refuses. The design:
  (1) *jobs on threads* - a pool of a few `std.Thread`s, each taking a job and running its pure kernel; every buffer
  the worker side holds (the job's input, its kernel's arena, its output) from the engine's own thread-safe
  allocator, never the app's, which stays on the main thread - a result copied into the app's allocator at `poll`;
  `parallel()` true natively; the tests' drain loops already written for jobs that land later; (2) *saved state as
  files*, one Zig implementation for every native system - a value a file under the platform's directory for the
  app (Windows `%APPDATA%`, Linux `$XDG_DATA_HOME` or `~/.local/share`, macOS `~/Library/Application Support`;
  Android's comes from its activity, with its port), written to a `.new` file and renamed over the old, as Windows'
  does now - for the unwritten platform, and for Windows in place of its own if it comes out simpler. Next turn: (1).

- **C4, jobs on threads (Oct 16).** `jobs.zig`: natively a job runs on a thread (`native_jobs`, chosen by
  `has_job_threads` - not a browser, not single-threaded); `job_host` is it natively and `web.jobs` in a browser, the
  same calls, so `Job` reads either. Threads are `std.Io.Threaded`'s, one `concurrent` call per job; a job lands by
  its slot's `is_done` (release), which `poll` reads without waiting - the future awaited only then. Every buffer a
  job's thread holds comes from `std.heap.smp_allocator`, never the app's; the result reaches the app's at `take`. A
  running job cancelled is abandoned and reaped once it lands. 64 slots; handles carry a generation. An overrun is
  `output_too_large` (-3), which `Job` maps to `Error.OutputTooLarge` as inline. Found: `compute_host`'s kernels work
  in their module's globals (`M.g.B`, `M.g.P`), snapshotted and restored inline - on a thread they would race the
  app's frame: `Options.kernels_work_in_globals`, set by `komputeRegistry`, keeps such registries inline natively.
  `Job.poll` now keeps a failed kernel's name before cancelling, as `pollInto` did. Tests: polled until landed
  (`landedResult`), the Group drain yielding as frames do, and a new one - the job's thread is not the submitter's
  (`tkThreadId`). `test-fast`, lint, `worker_png`'s page and `platforms-check` green (the first `platforms-check`
  run here was killed for memory - 3 GB - and passed on the second, with the first's work cached). Next for C4:
  saved state as files, one implementation for every native system.

- **C4 done (Oct 16): saved state as files, one implementation for the native systems.** `native_os.zig`:
  `loadValue`, `saveValue`, `removeValue` - each value a file in the program's folder, `<data folder>/zimr/<program>`
  (Windows `%APPDATA%`, Linux `$XDG_DATA_HOME` or `~/.local/share`, macOS `~/Library/Application Support`; none on
  Android, whose folder comes from its activity), the key escaped as Windows' platform escapes it (`%XX` for all but
  letters, digits and `-_.`), a save written to `.value.new` and renamed over the old (through `Dir.cwd()`:
  `renameAbsolute` asserts absolute paths); on `native_os.io()`, the services' `std.Io.Threaded`. The unwritten platform
  uses them on Linux and macOS, refuses on Android. Windows keeps its own tested Win32 version - same folder, same
  names. Jobs keep their own `Io`: sharing `native_os`'s pulled its tests, which need the C library on Linux, into a
  test build without it. Test (`zig test src/native_os.zig -lc`): a value reads back, is replaced whole, is gone
  once removed, its key one escaped file name. Lint, `test-fast`, `platforms-check` green. Next: C10, B7.

- **The review of C4's code (Oct 16, Simon: "Review the new code carefully. Hunt for bugs").** Found and fixed in
  `native_jobs`: (1) `Io.Threaded.concurrent` does not queue - each call it takes starts a thread kept for good, its
  limit unlimited by default, and past a limit a call fails, which ran the job inline: a group of sixteen jobs meant
  sixteen threads. Now the table queues (`SlotState.queued`), starting waiting jobs oldest first (`submit_order`) while
  fewer than `runningLimit` run - the cores less one, from one to four (`zm.clamp`) - from the app's thread at each
  `submit`, `poll`, `take` and `cancel` (`startQueuedJobs`); (2) every job held its whole output bound - 24 MB by
  default - from `submit`: now its thread allocates it as it starts, so a waiting job holds none; (3) the slot was
  written with `slot.* = .{ .generation = slot.generation, ... }`, a struct literal reading the slot it is written
  into - now from locals. Clearer names and named locals throughout (`handle_index_bits`, `SlotState`, `kernel_name`,
  `has_landed`, `recordFailure`), and the table's rule stated: the app's thread's alone, a job's thread sharing only
  its slot until its flag is set. Two Group tests assumed jobs land within a few passes; they poll as an app's frames
  would. New test: twenty jobs, never more on threads than the limit, every one landing with its own result. In
  `native_os`: iOS fell to the Linux folder - now with macOS's (`~/Library/Application Support`, inside its
  container); `extension`, `current_folder`. Checked and fine: the frame wait cannot spin on `WM_PAINT` - the window
  leaves it to `DefWindowProcW`, which validates. `test-fast`, lint, `native_os`'s tests, `platforms-check` green.

- **`zm.clamp`, verified (Oct 16, Simon: "There is clamp in zimrmath, right? I thought there was a lint rule to use
  it").** Both are there: `zimrmath.clamp(v, vmin, vmax) @TypeOf(v, vmin, vmax)`, generic over integers, floats and
  vectors, and zimrlint's `clamp-pattern`, which flags `@min(@max(...))` - it caught the jobs' running limit, now
  `clamp(cores_beside_the_app, 1, 4)` through the file's alias, the `@as` casts dropped (the result type resolves
  from all three). Found on the way: the sandbox's disk full - the cache at 8.1 GB after the day's `platforms-check`
  builds, and the build's own guard refusing to start. Deleting old entries from `.zig-cache/o` left the manifests in
  `.zig-cache/h` naming outputs gone - `configuration failed: FileNotFound`; the whole cache removed instead. Here:
  clear the cache whole, never part of it.

- **The review, continued (Oct 16): the frame wait, `on_input`'s dispatch, the note placement, the worklet's clock.**
  Found: without the high-resolution timer (before Windows 10 version 1803) the frame wait fell back on an ordinary
  timer, or a 1 ms timeout - both wait for the system's 15.6 ms tick, so the frame could start a refresh late, a
  stutter the change would have brought. Now `waitForFrame` asks for the precise timer once
  (`has_asked_for_frame_wait_timer`) and, without one, does not wait ahead: the frame waits inside its acquire as
  before, its input read at its start. Read and sound: `tryAcquireAhead`'s every early true falls to the frame's own
  acquire; a timeout-0 acquire that answers `VK_NOT_READY` leaves its semaphore unsignalled, so reusing it is valid;
  `SetWaitableTimer` clears a signal left from an earlier wait; `dispatchInput`'s `mixFrame` per press - natively the
  notices read, on a page one more forwarded batch - is safe between frames; `workletTimeBlock` converts at the
  engine's 48 kHz, the rate the page opens its context at. Names: `wait_handles`, `due_in_one_step`;
  `placementOfNote`'s `previous_block_asked_at_ms`, `has_both_times`, `into_wait_frames`, and why a request a whole
  block late starts at the first frame. Lint, the Windows build, `test-sound` (268) green. Left to review: c2js's
  changes, the UI combo's options, the start screen, the star's header, the unwritten platform.

- **The review, finished (Oct 16): c2js, the combo's options, the start screen, the star's header, the unwritten
  platform.** c2js: `tryAddressMemberStore` read and sound - a compound assignment is its own token and passes on, a
  struct-typed place is left to the struct copies, a boolean flag stores as 0 or 1 - and given names and comments
  (`start_of_statement`, `after_parentheses`, `opens_with_address_of`, `is_scalar_place`, `stored_expression`); the
  `&g` tag consumed by the `parsePostfix` around it, which clears a stale one first. `c2js-diff` 103 and 2. The
  combo: the outside-click close and the press it takes from the frame both test `dropdown_rect`, already the list's
  own width - a press on a wider list is the list's; that comment's bug story reworded as its rule. The start screen:
  a release over the button counted even when the press began elsewhere - now only a press begun and ended on it,
  as a UI button's (`is_start_armed`); `audio-scale-star-check` 14 windows. The star's labels fit their 96 bytes
  (about 70 at most); the unwritten platform's refusals once each, Android by its ABI. Lint green.

- **The native gallery on the engine's UI (Oct 16, Simon: "make a native gallery launcher app, similar to the web
  gallery, but using our ui primitives ... All examples will be independent native programs").** `zimr_gallery`
  rewritten: two windows of the UI - the list (a search field `/` focuses, a module box, the count, the examples
  grouped by module with their stars, selectable rows; up and down move, Enter starts, Escape clears) and the panel
  (title, description, stars, how the program stands, start or stop, its path). The catalog is the web gallery's
  (`src/web/manifest.json`, stars now read). Programs: `std.process.spawn`, the same call on every system, from
  the gallery's own folder (`executableDirPath`) - no more Windows-only `CreateProcessW`; each watched by a thread
  of its own (`watchProgram`: `wait`, then `exit_code` and the state, released), the frames never waiting; stopped by
  the system's own call by the id taken at start (`TerminateProcess` through `OpenProcess`, or `SIGTERM`) - not
  `Child.kill`, which waits as the watcher does, and not the child's handle, which its wait closes. A scripted run's
  `ZIMR_SCRIPT` is removed from the gallery's environment at its first frame (`forgetScriptSetting`), so a started
  example does not run the gallery's script. The UI: `##` hidden in selectable rows' and text fields' labels too, as
  in the combo (a field whose label is all hidden reserves no room). `zimr-gallery-headless` added. Checked headless:
  305 examples; "audio" 7 of 305; a selection by arrows; `music_streaming` started from the installed gallery -
  running, then closed. Stop on a long-running program is left to Simon's Windows session (headless examples end
  after a second). Windows build and lint green; the backends tutorial's gallery paragraph rewritten, its excerpts
  `startProgram` and `watchProgram`; `check` green.

- **Gallery screenshots, the step (Oct 16, Simon: "Make some sort of build step to generate screenshots for each
  example and integrate them in the gallery").** `zig build gallery-shots`: every example's headless program - the
  ones `<name>-headless` already builds, `addHeadlessRun` now returning them - run from the build root with a script
  on its standard input (`ZIMR_SCRIPT=-`): 120 frames, then a thumbnail saved as zig-out/gallery_shots/<name>.png,
  then the end (`addGalleryShot`). `-Dshots=a,b,c` takes only those. One program for all 305 was not the way: the
  launcher of the forty flagships already exhausts this machine's memory. New in the scripts: `.{ .capture_thumbnail
  = .{ .path, .width } }` (`native_input.Thumbnail`), the frame saved shrunk to that width, its height in proportion,
  each pixel the mean of those it covers (`wgpu_app.shrinkPixels`) - through the capture's function, which takes a
  width now (0 for the whole frame). The audio start screen skipped where `ZIMR_SKIP_START_SCREEN` is set
  (`isStartScreenSkipped`, never on a page), which the step sets, so that the picture is the example's own. Checked:
  `music_streaming` 320 by 568 (10 KB), `audio_spectrum_visualizer` 320 by 180 (4 KB). Lint green. Next: the gallery
  shows them - loaded from ../gallery_shots/ beside its executable, when an example is first chosen.

- **Gallery screenshots, in the gallery (Oct 16).** `zimr_gallery` shows the chosen example's thumbnail in its
  panel: looked for at `gallery_shots/<name>.png` one folder up from the gallery's own (zig-out/windows/) or two
  (zig-out/headless/bin/) - `thumbnail_folders_up` - read, decoded and uploaded the first time the example is chosen
  (`thumbnailOf`), and kept; one absent is remembered so (`ThumbnailSlot.missing`). Shown at its own size shrunk to
  fit 320 by 360 and the panel, its shape kept (`shownThumbnailSize`): the UI reserves its room (`ui.dummy`), and the
  texture is drawn there after the UI renders (`z.drawTexture`, now exported) - the UI's image widget takes only its
  older texture kinds. Textures released at the gallery's end. Checked headless with the installed gallery:
  `music_streaming`'s thumbnail between its stars and its state. Windows build with lint green; the backends
  tutorial's gallery section tells of the step and the thumbnails. Not run here: the step over every example - the
  sandbox's disk holds a few examples' builds at a time.

- **XOR on the CPU and the GPU (Oct 17, Simon: "Make a new example that shows a neural network learning xor on cpu
  and gpu. It should work on windows and web ... grounding our work on finishing the vulkan compute zimrnum port").**
  The example exists: `zimrnum_train` (zimrnum_plan.md stage C) - the XOR network trained on the GPU (`src/gpu/
  zn_train.zig`, eight dispatches a step over one buffer set, only the loss read back) and on the CPU (zimrnum's
  `Graph` and `Optimizer`, the same seed) in lockstep, a step a frame; it is missing from the gallery's catalog
  (`src/web/manifest.json`). Natively it does not start: headless on lavapipe, creating the compute pipeline
  `loss_value` fails; the driver answers -13, `VK_ERROR_UNKNOWN`, which `vk.check` folds into `VulkanUnknown` -
  `createComputePipeline` now logs a refusal's raw code. Ruled out: the entries' interfaces (each lists exactly the
  buffers it uses - read from the module with a throwaway parser, no SPIRV-Tools here), their local size (64), the
  entry name's buffer (64 bytes). `loss_value`'s SPIR-V is the backend's usual lowering - phis carrying state, a
  loop with a conditional break, unreachable merge blocks - which the other kernels share; nothing reads as wrong.
  Next: (1) a check in `vk-host-test` that makes a pipeline for every entry of every zimrnum GPU module (`zn_train`,
  `zn_mlp`, `zn_binary`, `zn_unary`, `zn_matmul`), the grounding test the port lacks; (2) bisect `loss_value` - the
  early return, `@floatFromInt(params.step + 1)`, the call to `zm.float` - against lavapipe; (3) Simon's GPU driver
  on it (`zimr-windows-zimrnum-train.zip`) - if it takes the kernel, the refusal is lavapipe's; (4) the example in
  the catalog, and its view (a decision boundary beside the curves) if Simon wants.

- **Native GPU training, the extent (Oct 17).** `cartpole_duel` headless on lavapipe stops the same way: `zn_mlp`'s
  `mse_value` pipeline, -13. `zn_mlp` is the kit of every RL page, so no RL page trains natively yet. `mse_value` and
  `zn_train`'s `loss_value` share one shape - a single-thread reduction (threads past the first return, a loop
  sums squared errors, a division, a scalar store) - the shape the kernels that do make pipelines lack. The work is
  scheduled in rl_track_plan.md's resumption section (T1, T2).

- **The refusal's cause (Oct 17): invalid SPIR-V from the compiler.** `spirv-val` (SPIRV-Tools, installed with the
  Khronos validation layer from Ubuntu's archive): a constant index into a storage-buffer array gets its base's
  pointer type - zig-spirv-quirks.md's Quirk 5, reproduced in one line. Pages run because WGSL translation ignores the
  type; Vulkan drivers compile it. Over the cache's 57 modules, 7 invalid: two compute (Quirk 5), two graphics shaders
  missing Block on run-time-sized storage arrays, two fragment shaders writing FragDepth without DepthReplacing, and
  the compile-only `zm_gpu_probe`. The fix, next: a legalising pass in the native host before `vkCreateShaderModule`.

- **Native GPU training runs (Oct 17).** `spv_vulkan.legalize`'s sixth adjustment, `accessChainRetypes`, sets
  each access chain's stated type to the pointer to the type it reaches (Quirk 5). Headless on lavapipe with the
  validation layer on: `zimrnum_train` PASS (early agreement 1.04e-7, both converged) and `cartpole_duel` training
  PPO on the GPU, 0 validation errors. The cache's 56 modules all pass spirv-val once legalised. Simon, on starting
  it: "Next zig version we might not need all that, but still, living at the frontier means we do it."

- **The access-chain pass, reviewed for the compiler's readers (Oct 17, Simon: "Expect zig people to read this").**
  Its section in `spv_vulkan.zig` now explains the rule, what 0.17.0 emits (one and two levels: every constant
  element step lags one level), where in the compiler a comptime pointer is lowered (`constantPtr`,
  `Value.pointerDerivation`, `derivePtr`, `ptrElemPtr`, `accessChainId`), what master's source would do, two
  compiler-side guards, and the test for removing the pass. Renamed: `accessChainCorrections`,
  `AccessChainCorrections` (`id_bound`), `stated_result_type`, `correct_result_type`, `stepping_index_ids`. A bug
  fixed: pointer types were compared by id, so a chain stating one of two declarations of the same pointer type
  could be restated as the other - now by meaning (`isPointerTo`), the first declaration of a meaning being the one
  a correction states; tested with each declaration stated. 15 tests; 58 modules valid once legalised;
  `zimrnum_train` PASS headless.

- **The access-chain defect, located (Oct 17, Simon supplied the 0.17.0 source).** 0.17.0's `derivePtr`, `.elem`:
  `ptrElemPtr(..., derived.parent.elem_ty, ...)` - the parent's pointee as the element type; master:
  `derivation.elem_ty`. `Value.zig` and the SPIR-V linker identical between the versions. Master's other backend
  changes: derivation pointer types emitted lazily (`derivedPtrType`, its comment naming Block-less structs - our
  adjustment 5), numeric conversions unified (`buildConvert`), vector bitcasts per lane. `spv_vulkan.zig`'s section
  now states the cause from the source. Simon offered master's compiler to confirm.

- **Back on master (Oct 17, Simon: "Ok we are back on master then").** Toolchain 0.18.0-dev.253+16d31ceed
  (tools/, the PATH of the sandbox's env; `build.zig.zon`'s minimum raised to it); the cache cleared whole. The
  access-chain fix CONFIRMED: the eight reproductions validate as emitted, the two-level one typed right at each step;
  of the 54 modules this build compiles, only FragDepth without DepthReplacing remains raw (adjustment 1, still
  needed) - no mistyped chain (adjustment 6) and no Block-less struct (adjustment 5): both are dead with master,
  their removal proposed to Simon. With master: lint green; `zimrnum_field` built for the web (release, 5.4 MB
  standalone) and run headless on lavapipe: ALL PASS 112/112, validation clean. `test-fast` not yet run on master.

- **Master verified, and two native checks (Oct 17).** On 0.18.0-dev.253: test-fast, c2js-diff (103 agree, 2
  JS-only), test-sound, audio-worklet-test, audio-page-test green. `vk-host-test`: `pipelines` (every pipeline of
  `zn_train` and `zn_mlp`) and `constant` (a kernel writing a `[16]f32`'s element 2 and a `[4][3]f32`'s element
  (1, 2) by constant indices, read back exactly) - all checks green, no validation messages.

- **0.17 left behind (Oct 17, Simon: "We can assume we will not go back to 17. Clean up").** `spv_vulkan.legalize`
  down to four adjustments: the sixth (access chains' result types) removed - master fixes the compiler; the fifth
  (dropping unused Block-less runtime-array structs) removed - master emits none, checked on the two vertex shaders
  that had them (`points_vs`, `fluid_discs_vs`: one Block struct each, valid as emitted); a struct holding a
  runtime array without Block now refused whether used or not (`structWithRuntimeArrayOutsideBlock`, one search, in
  `check` and `legalize`). Gone with them: the use analysis, `declaresType`/`describesId`, nine opcodes only they
  named, their tests (10 left, all green). The backends tutorial's 5.4 lists four. The 0.17.0 toolchain deleted.
  Lint, doc-folds, vk-host-test (all checks) green.

- **Saved values across headless runs (Oct 17).** `ZIMR_VALUES_DIR`: a headless run that names a folder keeps its
  saved values there as files, through `native_os`'s file values (now public with their folder), so a script can
  test resuming across runs and a value may exceed the in-memory 4 KB; set as the run starts, before the app's init.

**Waiting on Simon.** The glitch report on the two-hand scale star since the touch hysteresis - the last suspect; the
readout's numbers (8, and 11 on Windows). (The WGSL corpus's stale fixtures, noted here so they were not lost:
resolved Oct 18 by `tools/wgsl_corpus.zig`, which keys shaders by source path and never accumulates stale pins.)

**Size.** 7c 3 turns, 7d 1 to 2, 7e 2 to 3, 8 one and Simon's numbers, 9 two, 10 1 to 2, 11 one when the numbers come,
12 1 to 2: about 13 to 16 turns.

**Size from Oct 15.** Spent since Oct 14: 7c, 7d, 7e1 and 7e2 in about nine turns, with two reviews. Left: 7e3's end 1,
7f 1 and its fixes 1, 8 one, 10 1 to 2, 11 one, 12 1 to 2, the sound tutorial's chapter on the input path 1 - about
8 to 10 turns, 9's 2 more if the numbers ask for it; and two sessions of Simon's: Windows (7f) and his phone (8).

## 9a. The stretch to the next platforms (Oct 15)

**The goal of the stretch.** Sound on Windows and the web, heard and measured; then the engine ready for Linux, Android,
macOS and iOS - each of them, from there, the contract implemented once more (section 1).

**What "ready" means.** Three things the next platforms need from the engine before their own code, and one from
Simon:
- *The build matrix* (B9): every platform's code compiled here on every change - a Linux, a macOS and an Android
  platform begun from `template.zig`, each request refused by name until written, so that `zig build platforms-check`
  builds the launcher for all five. A platform then starts compiling, not from nothing.
- *The services shared by every native platform* (C4, C10): jobs on threads, saved state as files and loading by path
  are the same Zig on Windows, Linux, macOS and Android - `std.Thread` and files under a per-platform directory -
  written once now rather than once per platform.
- *The surfaces' states* (B7): attaching and detaching a surface without rebuilding the device, and the swapchain's
  three states - required by Android, whose window comes and goes while the app lives, and the minimized window on
  Windows.
- *Simon's Windows session* (C9), with sound in its checklist: the platform each later one is measured against.

**What can wait.** C2 (the drag and menu loops, AltGr), C6's input-method composition and C7 (pointer lock) are
Windows' own code: each later platform writes its own against the same contract requests, which are already decided.
They are finished on Windows when Simon's session asks for them, or between platforms.

**The order, and its size.**

| # | Step | Turns |
|---|---|---|
| 1 | 7e3's end: the examples captured, the gate, the record | 1 |
| 2 | 7f: the sound examples built for Windows, Simon's checklist | 1, then his report |
| 3 | 7f's fixes | 1 |
| 4 | 8: the worklet path measured | 1, then his phone's numbers |
| 5 | 10: `on_input`, the forwarding sent after each call | 1 to 2 |
| 6 | 11: the Windows device buffer, from his numbers | 1 |
| 7 | 12: the debts | 1 to 2 |
| 8 | The sound tutorial: the input path, measured | 1 |
| 9 | B9: the build matrix, three platforms begun from the template | 1 to 2 |
| 10 | C4: jobs on threads, saved state as files | 2 to 3 |
| 11 | C10: loading by path natively | 1 |
| 12 | B7: the surfaces' states | 1 to 2 |
| 13 | C9: Simon's Windows session, and its fixes | 1 to 2 |

About 14 to 20 turns, plus the backends tutorial's chapters and reviews against SDL, sokol, raylib and Mach every
second turn of platform work (9 to 13), and Simon's three sessions (Windows sound, his phone's readout, the Windows
checklist). Step 9 of section 9, bindings, is not in the table: it comes back only if step 5's readout asks for it.

**Then Phase D, Linux on X11,** first because it is verified here (Xvfb, lavapipe): its sound an ALSA output in the
shape of Windows' - a thread pulling the renderer's blocks through the contract's `AudioRing`, as every native output
does - checked by capture, with no device needed. macOS, Android and iOS follow, each output the same shape over its
own system's callback: CoreAudio's render callback, AAudio's data callback, `AVAudioSession` with CoreAudio on iOS.

**The Oct 11 list this replaces**, kept for the record: C1, C3 and C8 were done then; C5's turns since are section 9's
journal; scripts on every platform, C2, C6, C4, C7, C10, B7, B9 and C9 were its items 3 to 9, all in the table above or
under "what can wait".
