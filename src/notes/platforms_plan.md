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
     13. chapter 14 rewritten (step 9)        with the latency model, the paths, the instrument, the input path

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
      device's period (a gap of about a period is ordinary: the browser asks for blocks in bursts). The fix is a
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

  *Turn 4 - the scale star.* `examples/audio_scale_star/audio_scale_star.zig`, as its plan above says: the circle in
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

  *The scale star, in detail (Simon, Oct 12, from his drawing; turns 3 and 4).* An example, `examples/audio_scale_star`, that shows
  the notes and the chords of the major scale and plays them.
  *What it draws.* The seven notes of C major on a circle, in thirds: 1 C do, 3 E mi, 5 G sol, 7 B si, 2 D re, 4 F fa,
  6 A la - each note shown with its degree, its letter and its solfege name. Two neighbours on the circle are a third
  apart, so each chord of the scale is three neighbours: its root, its third, its fifth. Inside, the scale walked step
  by step, 1 to 2 to 3 ... to 7 and back to 1 - on a circle of thirds a step skips three places, which draws the
  seven-pointed star. Outside, the seven chords - I, ii, iii, IV, V, vi, vii (diminished) - each beside its root, with
  lines to its three notes: I to 1, 3 and 5; ii to 2, 4 and 6; iii to 3, 5 and 7; IV to 4, 6 and 1; V to 5, 7 and 2; vi to
  6, 1 and 3; vii to 7, 2 and 4. Upper case for a major triad, lower case for a minor one; vii's diminished fifth shown
  as such.
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

## 9. The next steps (Oct 11)

Done since Oct 9: C1 (the `isWasm()` audit), C3 (window state, monitors, cursors, `keyName`, `openUrl`) and C8
(gamepads). Under way: C5, sound.

1. **C5** - sound, by "C5 from here" (in Phase C): the sound examples' lag cut to what the hardware allows, and the
   input path to reach it. Done: the worklet's program, the instrument, `audio_keyboard`, the latency readout, the
   renderer worklet playing in Chrome, the push path deleted, page audio in Zig. The next five turns are written out
   turn by turn ("The next five turns, precisely"): the glitches by Simon's screenshot and the worklet's start; the hot
   paths' rest; the Shepard instrument; the scale star; streams on the mixer. Then streams across to the worklet,
   music (a Vorbis decoder), the worklet path measured, bindings, `on_input`, the Windows device buffer, the debts,
   chapter 14.
2. **C5, the Windows readout on Simon's machine** - whenever Simon can; it decides the device buffer's step.
3. **Scripts on every platform** - the engine following a growing script file; Simon's runs of the test package.
4. **C2, C6** - the drag and menu loops, focus regained, AltGr; text editing, the clipboard, input-method
   composition.
5. **C4** - jobs on threads, saved state as files.
6. **C7** - pointer lock with raw input.
7. **C10** - loading by path natively.
8. **B7, B9** - the swapchain's states; the build matrix.
9. **C9** - Simon's Windows session, driven by scripts, the headless frames its reference.
