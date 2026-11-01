# Linux port plan - zimr on Linux through X11 and Vulkan, built and checked from Windows

Version 2, Oct 31 2026. **Status (Nov 1): being implemented - stages L1, L2 and L3 written, not yet compiled (no
compiling on this machine but Simon's: the journal lists his checks); L4 next.** Simon, Nov 1: "Implement carefully".
Before that, Oct 31: "I agree with the plan. But I don't want to start implementing now. First make it more precise,
then review it carefully. Try to guess where it will break." Version 2 is that: every change named by file, line and
shape (section 6), two probes run (section 7), and a review predicting the breakages (section 8), which changed the
design in eight places (marked **[review]**).

This is `platforms_plan.md`'s Phase D ("Linux on X11") planned in detail. It starts from `vulkan_port_plan_v2.md`
section 7a (Oct 6) and brings it up to date with what has landed since: the platform contract, the Windows platform,
the headless platform, the unwritten platform, `platforms-check`. Its reference on this machine is mach
(`C:/Users/sclav/Downloads/mach-main/mach`: `src/core/Linux.zig`, `src/core/linux/X11.zig`, `src/sysaudio/alsa.zig`);
for GLFW, SDL and sokol it relies on the Oct 7 study in `platforms_plan.md` (sections 3 and 8), their sources not
being on this machine.

**What changed since 7a was written:** the work moved from the Linux sandbox to Simon's Windows machine, and Simon
tests Linux rarely - in WSL2 on this machine first (LX-D12). So: **Linux is built and checked from Windows, and run
rarely.** Every stage ends in something checked here - a linked Linux binary, compile-time layout asserts, unit tests
of pure functions, an ABI check against official headers, lint. What only a running X server shows is gathered into
one session (section 10).

Line numbers below are the tree's on Oct 31 (`73b20aa`); they drift as the files change, the shapes do not.

---

## 0. The plan on one screen

| | |
|---|---|
| **Goal** | every example a native Linux program: `zig build <app> -Dplatform=linux` -> `zig-out/linux/<app>`, from the same app code, built on Windows |
| **Window** | X11 through libX11 (Xlib), loaded at run time; XWayland covers Wayland desktops, WSLg's included |
| **GPU** | the Vulkan host, unchanged but for its surface: `VK_KHR_xlib_surface` |
| **Loop** | the native loop, one for Windows and Linux; the window system chosen once (`native_window.zig`) |
| **Input** | keys by evdev code (X keycode - 8), one table; text through XIM; buttons, wheel, enter and leave, focus |
| **Sound** | ALSA's `default` device, a render thread pulling the mixer, as WASAPI's does |
| **Binary** | `x86_64-linux-gnu.2.31`: links glibc only (Zig's stubs; probe P1: needs `GLIBC_2.28` at most); X11, ALSA and Vulkan `dlopen`ed |
| **Checked here** | the Linux link; layout asserts; `vk-abi-check` (both targets); unit tests of the translation and parsers; lint |
| **Checked in WSL / on Linux** | `linux-abi-check` (every X11 and ALSA declaration against the headers); one checklist |

| | Stage | Exit, checked here |
|---|---|---|
| L1 | `-Dplatform=linux` in the build, zimr's and projects'; `tools/elf_needs.zig` | ELF linked, GLIBC <= 2.31 (the tool, in `platforms-check`); web, Windows and the template unchanged |
| L2 | The surface seam; the Xlib surface | `vk-abi-check` both targets; Windows builds, `vk-hello-windows` included |
| L3 | `x11.zig`, the loop on X11, the evdev table, `platform/linux.zig` | the Linux link; `native_input` tests; lint |
| L4 | Text (XIM), repeat, labels, cursors, pointer lock, window requests | as L3, with new tests |
| L5 | Clipboard, paste keys, `openUrl`, keep awake, scale changes, monitors | as L3, with parser tests |
| L6 | Sound through ALSA | as L3 |
| L7 | Gamepads through evdev | as L3 |
| L8 | Dropped files (XDND), file dialogs (zenity, kdialog) | as L3 |
| L9 | `linux-abi-check` and the first WSL session | in WSL |
| L10 | A release archive; Linux debug configs for editors | - |
| L11 | Wayland (later) | - |

---

## 1. Where things stand (Oct 31)

**Ready for Linux already** - compiled by `platforms-check` for `x86_64-linux-gnu` on the unwritten platform:

| Part | File | Linux state |
|---|---|---|
| The Vulkan loader | `native_os.openVulkanLibrary` | `dlopen("libvulkan.so.1")`, `dlsym("vkGetInstanceProcAddr")` |
| Environment, clock | `native_os.environmentVariable`, `monotonicMilliseconds` | `getenv`, `clock_gettime(MONOTONIC)` |
| Saved values | `native_os.loadValue` ... | `$XDG_DATA_HOME/zimr/<program>` or `~/.local/share/zimr/<program>` |
| Files, child programs | `native_os.readWhole`, `ChildProgram` | `std.Io`, `std.process.spawn`, `SIGTERM` |
| Jobs | `jobs.zig` (`native_jobs`) | `std.Io.Threaded` |
| WebSockets | `net_core.native_websocket` | `std.Io.net` |
| The headless host | `native_loop.headless`, `platform/headless.zig` | runs on Linux (lavapipe) |
| The Vulkan host | `wgpu_vulkan.zig` | all but the surface |
| The gallery, the lab | `examples/zimr_gallery`, `examples/geno_lab` | `.exe` only on Windows already (`zimr_gallery.zig:281`, `geno_lab.zig:190`) |

An audit of `examples/` for OS facts (`os.tag`, `.exe`, backslash paths, `win32`) found only those two, both written
for both systems; every other example is OS-free. Run-time reads by path: the gallery's thumbnails and the lab's run
folder - names the build itself writes, so their case matches on Linux's case-sensitive file systems.

**Windows-only today**, each a stage's subject:

| Part | Where | What is Windows' |
|---|---|---|
| The window | `win32.zig` (`Window`, lines 1423-2172) | all of it |
| The loop's window, waits, monitors, dialogs, drops | `native_loop.zig` | `var window: win32.Window` (54); `MsgWaitForMultipleObjectsEx` (1320); `EnumDisplayMonitors` (963-1197); `GetOpenFileNameW` (294-443); `HDROP` (445) |
| The surface | `wgpu_vulkan.zig` | `VK_KHR_win32_surface` (834), `createWin32SurfaceKHR` (1128-1135) |
| Input translation | `native_input.translate` (601) | `WM_*` messages, set-1 scancodes |
| The platform | `platform/windows.zig` | Linux is `platform/unwritten.zig`, every request refused |
| The build | `build.zig` | `Platform = enum { web, windows, android }` (1643); Linux only in `platform_check_targets` (2781), as an object |

---

## 2. Principles

1. **Built and checked from Windows.** `x86_64-linux-gnu.2.31`: Zig links glibc from its own stubs - no sysroot, no
   Linux headers. glibc 2.31 is Zig's default floor for x86_64 Linux (`std/Target.zig`), pinned in the triple so a
   toolchain change cannot move it, and the platforms plan's minimum.
2. **Every system library loaded at run time, by versioned name**: `libX11.so.6` (required for a window),
   `libXcursor.so.1`, `libXrandr.so.2`, `libXss.so.1` (optional, each a feature that degrades by name),
   `libasound.so.2` (sound; without it the sound drains unplayed), `libvulkan.so.1` (already). A missing library is
   a message naming it and the package that has it.
3. **Declared by hand, checked three ways**: (a) here, at compile time - each structure's LP64 size and the offsets
   zimr reads, asserted inside `x11.zig` and `alsa.zig`, evaluated by every Linux build (and only there: gated on
   `@sizeOf(c_long) == 8` and Linux, so Windows test builds, which import `x11.zig` through `native_input`, skip
   them) **[review]**; (b) here, `vk-abi-check` for `VkXlibSurfaceCreateInfoKHR`; (c) in WSL, `linux-abi-check`.
4. **Pure where it can be, tested here.** The window turns each X event into a plain `x11.InputMessage`;
   `native_input.translateX11` turns that into the engine's events, tested on Windows as the Win32 messages are; the
   key table, the `Xft.dpi` parser, keysym labels and code points, the clipboard's target choice are tested the same
   way.
5. **Port, do not invent.** GLFW for the X11 window (keys aside), XIM, fullscreen, the disabled cursor, the clipboard,
   XDND; mach for loading Xlib and Xcursor, and for the WM ping; sokol for ALSA's `default`.
6. **Windows unchanged in behaviour.** No Windows code moves; where the loop shares a function, Windows' path computes
   exactly what it did (section 6.5 shows the due times). Every stage's exit builds Windows.
7. **One loop**: scripts, the frame wait, the beat, input delivery, the file queue and the headless frames stay one
   definition for both systems.

---

## 3. What the references do

### 3.1 mach (on this machine)

- **Backends**: Wayland first, X11 the fallback; `MACH_FORCE_BACKEND`; missing features listed per backend.
- **Headers**: `@cImport` of `Xlib.h`, `Xatom.h`, `cursorfont.h`, `Xcursor.h`, `Xrandr.h`, `xkbcommon.h` - needs the
  development headers to build, which this machine cannot have: zimr declares by hand.
- **Loading**: `LibX11.load` opens `libX11.so.6`, then `libX11.so`, and fills a struct of function pointers by field
  name - zimr's `vk.loadDispatch` pattern. Taken (with `libXrandr.so.2`, the real soname, where mach says `.so.1`).
- **`XInitThreads()` first**: older libX11 races Vulkan's present thread on the shared connection. Taken.
- **The window**: `XCreateWindow` on the default visual with a colormap and an event mask; `WM_PROTOCOLS` =
  `WM_DELETE_WINDOW`, `_NET_WM_PING` (answered by sending the event back to the root); `XStoreName`; `XMapWindow`.
  Taken, plus `_NET_WM_NAME`, `WM_CLASS`, `_NET_WM_PID`, size hints (GLFW).
- **Events**: drained while `QLength` is non-zero; `FocusIn`/`FocusOut` with `NotifyGrab`/`NotifyUngrab` ignored. Taken
  (with `XPending`, which also reads the socket).
- **Keys**: keysyms through `XLookupString` - layout-dependent. Not taken (LX-D4).
- **Text**: `xkb_keysym_to_utf32`, no input method. Not taken (LX-D5).
- **Buttons**: 1-3 buttons, 4-7 the wheel (4 up, 5 down, 6 left, 7 right), 8 and up more buttons. Taken.
- **Cursors**: Xcursor theme names, the cursor font as fallback, the hidden cursor from a blank 1 x 1 pixmap. Taken.
- **Fullscreen**: `_NET_WM_STATE` client message to the root. Taken.
- **Not in mach's X11**: DPI, auto-repeat, clipboard, pointer lock, monitors, drops - GLFW's.
- **ALSA**: `libasound.so.2` at run time; `snd_lib_error_set_handler` given a no-op through a cast (its type is
  variadic); inotify on `/dev/snd`. Taken: the loading, the silenced handler.

### 3.2 GLFW, SDL, sokol (the Oct 7 study)

- **GLFW**: XKB key names with a keysym fallback; XIM (`XOpenIM`, `XCreateIC` with `XIMPreeditNothing |
  XIMStatusNothing`, `XFilterEvent`, `Xutf8LookupString`), the locale set to the user's when it is "C"; key presses
  duplicated by XIM skipped by timestamp; `XkbSetDetectableAutoRepeat` with a peek-ahead fallback; `Xft.dpi`;
  `_NET_WM_STATE_FULLSCREEN`; EWMH features read from `_NET_SUPPORTED`; the disabled cursor by grab and warp; the
  `CLIPBOARD` selection (`TARGETS`, `UTF8_STRING`, `STRING`, `MULTIPLE`) and `SAVE_TARGETS` to the clipboard manager at
  exit; XDND; XRandR.
- **SDL3**: the same Xlib family; keep-awake through D-Bus, then `XScreenSaverSuspend`.
- **sokol**: XKB names, `XLookupString` text; `sokol_audio.h` writes ALSA's `default` from its own thread.
- **SDL3's coordinate table**: X11 speaks physical pixels; zimr divides by the scale.

---

## 4. The options weighed

Kept from version 1, in brief; section 5 records the choices.

| Decision | Chosen | Set aside, and why |
|---|---|---|
| X11 library | Xlib | XCB: no input method at all; XCB + Xlib: two event queues |
| Keys | evdev table | XKB names: `XkbDescRec`/`XkbNamesRec` uncheckable here; keysyms: follow the layout |
| Text | XIM | keysym to UTF-32: no dead keys, compose or IMEs |
| Scale | `Xft.dpi` | XRandR millimetres: often wrong, unused by desktops |
| Pointer lock | grab + warp | XInput2 raw motion: `libXi` and two more structures; later if wanted |
| Frame wait | `poll` on the connection | sleep then pump: input waits |
| Sound | ALSA `default` | PulseAudio simple: Pulse only; PipeWire: newest, PipeWire only |
| Code | `x11.zig`, `alsa.zig`, `platform/linux.zig`, `native_window.zig` | a `src/platform/linux/` folder: against v2's D2 |
| Loop | one loop | a Linux twin: two copies that must agree |
| Bench | WSL2 + WSLg first | Linux machine only: too rare; CI: none here |

---

## 5. Decisions - all thirteen AGREED (Oct 31, Simon)

- **LX-D1. X11 through libX11 (Xlib). DECIDED.** Replaces 7a's L-D1 (XCB); `VK_KHR_xlib_surface`; Wayland later
  (L11), XWayland meanwhile.
- **LX-D2. Run-time loading, versioned names** (principle 2).
- **LX-D3. Declared by hand, checked three ways** (principle 3).
- **LX-D4. Keys by evdev code. DECIDED.** `engineKeyFromX11Keycode(keycode) = table[keycode - 8]` (section 6.6); a
  start-up probe - keycode 9 is `XK_Escape`, 36 is `XK_Return` - warns once on a server whose keycodes are not evdev's.
  Departs from `platforms_plan.md` L10.
- **LX-D5. Text through XIM**, GLFW's way (sections 6.4.8, 6.4.9). No `composition` events on X11: the IM draws its own
  preedit, stated in `platform/linux.zig`.
- **LX-D6. Scale from `Xft.dpi`**, re-read when the root's `RESOURCE_MANAGER` changes; one scale for every monitor.
- **LX-D7. One native loop**, the window system chosen once in `native_window.zig`; the X11 `Window` has the members
  the loop and the host read, with Win32's names and meanings.
- **LX-D8. The frame wait polls the X connection** (`XPending`, `XFlush`, `poll`).
- **LX-D9. Pointer lock as GLFW's disabled cursor** (grab, blank cursor, warp to the centre, the warp's echo
  skipped), reported at once, ended on focus loss.
- **LX-D10. Sound through ALSA's `default`**, a render thread in WASAPI's shape.
- **LX-D11. The build: `-Dplatform=linux`** (section 6.1); no new step families.
- **LX-D12. The test bench: WSL2 with WSLg, first. DECIDED** (Simon: "for testing I will probably want to use wsl2 on
  this machine"). XWayland's keycodes are evdev's; lavapipe gives Vulkan 1.3 on the CPU; dozen (Vulkan on D3D12),
  when listed and short of what the host requires, is passed over by `chooseGpu`, and `ZIMR_GPU=llvmpipe` names
  lavapipe. Known WSLg limits: sound only through ALSA's pulse plugin; pointer lock may not hold (RDP sends absolute
  positions). A Linux desktop stays the reference for those and for real GPUs.
- **LX-D13. Decided when their stage starts**: gamepads (evdev, the kernel's standard layout), file dialogs
  (zenity, kdialog), drops (XDND), monitors (XRandR 1.5), Wayland.

**Refinements from the review (section 8), within the decisions above - recommended, for Simon to confirm:**

- **R1. Projects get Linux in L1, not L10** **[review]**: `Project.init` picks `if (platform == .windows) windows_ctx
  else web_ctx` (`build.zig:3530`), so once a Linux machine defaults to `.linux`, a template project there would
  quietly build web pages for a Linux request. The Linux context is built before the phase split and published
  beside the Windows one.
- **R2. `run-<app> -Dplatform=linux` on Windows always goes through `wsl.exe`** **[review]**: `wsl.exe` exists on
  Windows 11 even without WSL - it answers "The Windows Subsystem for Linux is not installed", which is the message
  wanted - so no detection at configure time. The run forwards zimr's settings into WSL (`WSLENV`).
- **R3. `ZIMR_SCALE`** overrides the scale on Linux **[review]**: a desktop that magnifies X programs itself while
  also setting `Xft.dpi` (GNOME on Wayland at scale 2, XWayland without native scaling) would scale zimr twice.
- **R4. Linux programs keep Zig's default backend; a Debug build that misbehaves where a release build does not
  turns `use_llvm` on for Linux** **[review]**: Linux Debug builds use the self-hosted x86_64 backend where Windows
  uses LLVM; probe P2 compiled the variadic call with it, and the sandbox's Debug tests ran on it for months
  (`build_profile_1282.md`), but the windowed engine never has. L9 runs both a Debug and a release build.

---

## 6. The design, precisely

### 6.1 `build.zig` (L1, and `vk-abi-check` at L2, `linux-abi-check` at L9)

| Lines | Change |
|---|---|
| 11-36 (header comment) | `-Dplatform` lists linux; `zig-out/linux/<app>` |
| 1639-1643 | `pub const Platform = enum { web, windows, linux, android };` and its doc: "natively on Windows or Linux" |
| 1647-1652 | `hostPlatform`: `.windows => .windows, .linux => .linux, else => null` |
| 2376-2394 | `WindowsPending`/`windows_pending`/`windowsPendingReason` -> `NativePending`/`native_pending`/`nativePendingReason` (uses: 2425, 7138, 7208, 7220-7228) |
| 2396-2428 | `appBuildFor(..., linux_builds)`: `.linux => if (linux_builds.get(name)) |install| return &install.step`; reason `.linux => nativePendingReason(name) orelse "it runs only on the web"`; the no-platform message names linux |
| 2452-2490 | `appRunFor(..., linux_builds)`: `.linux` -> `linuxRun(b, install, app_step)` (below) |
| after 2757 | `installLinuxApp`, `addLinuxApp`, `linuxRun` (below) |
| 2780-2785 | `platform_check_targets`: Linux removed (macOS, Android stay) |
| 3521-3530 (`Project.init`) | **[review R1]** the option's help lists linux; `const ctx: AppContext = switch (platform orelse .web) { .windows => windows_ctx, .linux => linux_ctx, .web, .android => web_ctx };` with `engine.linux_ctx` |
| 3654-3660, 3745-3753 (`Project`) | `AppRunner.program` runs on Linux natively and through WSL on Windows (`linuxRun`); `addApp`: `if (p.platform == .linux)` installs with `installLinuxApp`, as the Windows branch does |
| 4395-4400 | the option's help: `web | windows | linux | android` |
| 4647-4671 | `build_opts_windows` -> `build_opts_native` (shared by Windows and Linux: the same four options); after the Windows module, the Linux one (below) |
| 5294, 5328 | `zimr_linux_mod.addAnonymousImport(wgsl_import_name, .{ .root_source_file = out.spv })` and `.addImport("<name>_externs", externs_mod)`, beside the Windows lines |
| 5482-5562 | the trainer for Linux beside the lab: `geno_trainer_linux_install`, `installLinuxApp(addGenoTrainer(b, linux_target, ...))`, made under `-Dplatform=linux` |
| 5633-5656 | after the Windows context, the Linux one (below), **before** the phase split, passed to `publishEngine` **[review R1]** |
| 7059-7063 | `var linux_builds: StringHashMap(*Step.InstallArtifact) = .init(b.allocator);` |
| 7202-7247 | a twin block under `if (platform == .linux)`: every example not pending (`addLinuxApp(linux_app_ctx, ...)`), the gallery (with the same `gallery_options`) |
| 7286-7299 | the launcher for Linux, **always** (for `platforms-check`): `linux_builds.put("launcher", ...)` |
| 7300-7340 | `platforms_check_step.dependOn(&linux_builds.get("launcher").?.step)`; its description unchanged |
| 7494-7608 | `appBuildFor`/`appRunFor` get `&linux_builds`; `in_all_examples`: `.linux => linux_builds.contains(name)`; descriptions "(web, windows, linux or android)"; `is_lab_for_linux` adds the Linux trainer |
| 9056-9125 | `vk-abi-check` over two targets (below) |
| after 9174 | `linux-abi-check` (L9, below) |

**The Linux engine and context:**

    const linux_target: ResolvedTarget = b.resolveTargetQuery(std.Target.Query.parse(.{
        .arch_os_abi = "x86_64-linux-gnu.2.31",
    }) catch unreachable); // lint:off catch-suppression: hardcoded-valid triple
    const linux_numerics: NumericsModules = addNumericsModules(b, linux_target, native_optimize, zimrmath_mod);
    const zimr_linux_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/zimr.zig"),
        .target = linux_target,
        .optimize = native_optimize,
        .link_libc = true,                      // dlopen, getenv, poll, setlocale, getpid
    });
    // imports shader_interface, zm, zn (linux_numerics.zimrnum), zrl; options build_opts_native

    // The context: the Windows one's twin, as headless_app_ctx is (build.zig:5695-5702)
    linux_common_mod (examples/example_common for linux_target, imports zimr = zimr_linux_mod, zm)
    var linux_shader_cache: StringHashMap(ShaderDep) = .init(b.allocator);
    var linux_app_ctx: AppContext = windows_app_ctx;
    linux_app_ctx.target, .zimr_mod, .common_mod, .kompute_mod, .zimrnum_mod, .zimrrl_mod, .shader_cache = ...;
    linux_app_ctx.pdb_void_workaround = null;   // native_wgsl_check kept: it scans bytes, any format

**The installs and the run:**

    /// zig-out/linux/<name>, once the native WGSL check passes (`addNativeWgslCheck`).
    fn installLinuxApp(install_builder: *std.Build, ctx: AppContext, exe: *Compile) *Step.InstallArtifact
    fn addLinuxApp(ctx: AppContext, app_mod: *Module, name: []const u8, own_frame: bool) *Step.InstallArtifact

    /// What `run-<app>` does with a Linux program, once `app_step` has built it: on Linux, runs it; on Windows, runs
    /// it in WSL - `wsl.exe --cd <the install folder, a Windows path> --exec ./<name>` - forwarding zimr's settings
    /// (`WSLENV`); anywhere else, fails naming where it runs.
    fn linuxRun(b: *std.Build, install: *Step.InstallArtifact, app_step: *Step) *Step

    WSLENV = <the caller's WSLENV>:ZIMR_GPU:ZIMR_VK_VALIDATE:ZIMR_LOG_INPUT:ZIMR_SKIP_START_SCREEN:ZIMR_FOLLOW:
             ZIMR_SCALE:ZIMR_SCRIPT/p:ZIMR_CAPTURE_DIR/p:ZIMR_VALUES_DIR/p          (/p: a path, translated)

**`vk-abi-check`** (L2): the reference header gains, after `vulkan_win32.h`,

    typedef struct _XDisplay Display;
    typedef unsigned long XID;
    typedef XID Window;
    typedef XID VisualID;
    #define VK_USE_PLATFORM_XLIB_KHR 1
    #include <vulkan/vulkan_xlib.h>

and the check compiles for `x86_64-windows-gnu` and `x86_64-linux-gnu` (`Window` is `unsigned long`: 4 bytes on one,
8 on the other; each target compares against its own translation).

**`linux-abi-check`** (L9): `tools/linux_abi_check.zig`, compiled for `x86_64-linux-gnu` against translate-c of

    #include <X11/Xlib.h>      <X11/Xutil.h>        <X11/Xatom.h>         <X11/cursorfont.h>    <X11/XKBlib.h>
    #include <X11/Xcursor/Xcursor.h>   <X11/extensions/Xrandr.h>   <X11/extensions/scrnsaver.h>   <alsa/asoundlib.h>

with `-Dlinux-headers=<dir>` (default `/usr/include` on a Linux build machine; from Windows,
`//wsl.localhost/Ubuntu-24.04/usr/include`, tried first at L9). It compares, at compile time, as `vk_abi_check.zig`
does: every structure by position (size, alignment, offsets), every constant by its C name (kept in `x11.zig`, as
`win32.zig` keeps Windows' - see 6.4.1), every function-table field against the C prototype (parameter count and
sizes, return size; for `XCreateIC`, its one fixed parameter).

### 6.2 Vulkan: `tools/vk_gen.zig`, `src/vk.zig`, `src/vk_hello.zig` (L2)

| File, lines | Change |
|---|---|
| `vk_gen.zig` 51 | `const Level = enum { global, instance, surface, win32_surface, xlib_surface, device, swapchain };` |
| 91 | `"XlibSurfaceCreateInfoKHR"` after `"Win32SurfaceCreateInfoKHR"` (its `StructureType` value follows by itself: `.values = &.{}` is filled from the structures, line 1277) |
| 430-437 | `.surface` loses `vkCreateWin32SurfaceKHR`; `.{ .level = .win32_surface, .commands = &.{"vkCreateWin32SurfaceKHR"} }`, `.{ .level = .xlib_surface, .commands = &.{"vkCreateXlibSurfaceKHR"} }` |
| 934-936 | `builtin_types` += `.{ .c = "Display", .zig = "anyopaque" }` (the member is `Display*`), `.{ .c = "Window", .zig = "c_ulong" }`, `.{ .c = "VisualID", .zig = "c_ulong" }` |
| 1355-1374 | `tableTitle`: `Win32SurfaceDispatch`, `XlibSurfaceDispatch`; `tableDoc`: "An instance's Win32 surface command (VK_KHR_win32_surface): loaded only on Windows, by a host with a window." and the X11 twin; `SurfaceDispatch`'s doc: "the commands every window system shares (VK_KHR_surface)" |
| `vk.zig` 184 (hand-written head) | `pub const khr_xlib_surface_extension_name: [*:0]const u8 = "VK_KHR_xlib_surface";` |
| 3703- (hand-written loaders) | `loadWin32SurfaceDispatch`, `loadXlibSurfaceDispatch`, as `loadSurfaceDispatch` |
| the generated middle | regenerated: `zig build vk-gen -Dvulkan-registry=C:/VulkanSDK/1.4.363.0/share/vulkan/registry/vk.xml`; the diff read whole - only the Xlib declarations and the moved command may change; anything else (a newer registry's wording) is examined before it stays |
| `vk_abi_check.zig` 33-41 | `"khr_xlib_surface_extension_name"` in `constants_without_twin` |
| `vk_hello.zig` 97, 242, 432, 777-778 | **[review]** `hello.surface_dispatch.createWin32SurfaceKHR` no longer exists: the hello loads `vk.loadWin32SurfaceDispatch` for its one creation call, as the host does |

### 6.3 The surface seam: `src/native_window.zig` (new) and `src/wgpu_vulkan.zig` (L2)

    //! THE NATIVE WINDOW SYSTEM - the window layer a native build draws through, chosen once by its operating system:
    //! Win32 (`win32.zig`) on Windows, X11 (`x11.zig`) on Linux. The native loop and the Vulkan host both name the
    //! window through here, so the choice is made in one place - the host cannot import the loop, which imports it.
    //! (members both windows offer: section 6.4.8) ... macOS and Android compile against Win32's declarations, never
    //! calling them (`native_loop.has_window_loop` is false there), as before.

    const builtin = @import("builtin");
    const vk = @import("vk.zig");
    pub const is_x11: bool = builtin.target.os.tag == .linux and !builtin.target.abi.isAndroid();
    pub const system = if (is_x11) @import("x11.zig") else @import("win32.zig");
    pub const Window = system.Window;
    pub const WindowOptions = system.WindowOptions;
    pub const WindowError = system.WindowError;
    pub const InputMessage = system.InputMessage;
    pub const surface_extension_name: [*:0]const u8 =
        if (is_x11) vk.khr_xlib_surface_extension_name else vk.khr_win32_surface_extension_name;

`wgpu_vulkan.zig`:

| Lines | Change |
|---|---|
| 76 | `const win32 = @import("win32.zig");` -> `const native_window = @import("native_window.zig");`; `builtin` imported |
| 523, 622, 628, 1658, 1829, 1863, 3545, 3559 | `win32.Window` -> `native_window.Window` (fields read: `client_width`, `client_height`, `size_changed`, `scale()` - the same names on both) |
| 726-736 | `BringUpError` += `WindowSystemUnwritten` |
| 834 | `extensions[1] = native_window.surface_extension_name;` |
| 1128-1135 | `try createWindowSurface(self, get_instance_proc_address, window);` |
| new, before `bringUp` | `createWindowSurface` (below) |

    /// The window's surface, by its system's own creation command - the one window-system command that differs between
    /// systems, so its table is loaded here, for this one call: Win32's from the window's module and handle, X11's from
    /// its display connection and window.
    fn createWindowSurface(
        self: *Host,
        get_instance_proc_address: vk.PfnGetInstanceProcAddr,
        window: *native_window.Window,
    ) BringUpError!void {
        if (comptime native_window.is_x11) {
            const creation: vk.XlibSurfaceDispatch = try vk.loadXlibSurfaceDispatch(get_instance_proc_address, self.instance);
            var surface_info: vk.XlibSurfaceCreateInfoKHR = .{ .dpy = window.display, .window = window.handle };
            try vk.check(creation.createXlibSurfaceKHR(self.instance, &surface_info, null, &self.surface));
        } else if (comptime builtin.target.os.tag == .windows) {
            ... Win32SurfaceDispatch, Win32SurfaceCreateInfoKHR{ .hinstance = window.module, .hwnd = window.handle }
        } else {
            return BringUpError.WindowSystemUnwritten;   // macOS, Android: no window opens there
        }
    }

### 6.4 `src/x11.zig` (new; L3, L4, L5)

The file's sections in declare-before-use order, `win32.zig`'s pattern. About 2000 lines when L5 ends.

#### 6.4.1 Header and naming

The `//!` header: X11 in brief (a server owning the screen and input; clients over a socket; the window manager a
client with privileges; ICCCM and EWMH its manners); why Xlib (XIM); loaded at run time; declared by hand and how
it is checked; physical pixels; the window and its members. Two file-level directives, as `win32.zig` has:

    //! lint:off screaming-const: X11's own names (XA_ATOM, XC_left_ptr), as Xlib.h declares them;
    //! linux-abi-check finds each one's twin in the headers by that same name.

Types, constants and functions keep their C names (`XKeyEvent`, `KeyPress`, `StructureNotifyMask`, `XOpenDisplay`);
fields keep the C field names (`keycode`, `x_root`, `send_event`). One exception: X's `Window` typedef is not declared -
`Window` is the window layer's struct, and window ids are `XID`, which `Window` is in C (`typedef XID Window`).

#### 6.4.2 Types

    pub const XID = c_ulong;        Atom, Time, Cursor, Pixmap, Colormap, Drawable, KeySym, VisualID = c_ulong
    pub const Bool = c_int;         Status = c_int;   KeyCode = u8
    pub const Display = opaque {};  Visual = opaque {};   XcursorImage = opaque {}
    pub const XIM = *opaque {};     XIC = *opaque {}
    pub const ErrorHandler = *const fn (display: ?*Display, event: *XErrorEvent) callconv(.c) c_int;
    pub const InputHandler = *const fn (message: InputMessage) void;

#### 6.4.3 Structures, field for field (`extern struct`), with the LP64 sizes and offsets asserted

| Structure | Fields (C order) | Size | Asserted offsets |
|---|---|---|---|
| `XAnyEvent` | type, serial, send_event, display, window | 40 | window 32 |
| `XKeyEvent` | type, serial, send_event, display, window, root, subwindow, time, x, y, x_root, y_root, state, keycode, same_screen | 96 | time 56, x 64, state 80, keycode 84 |
| `XButtonEvent` | as `XKeyEvent`, `button` for keycode | 96 | button 84 |
| `XMotionEvent` | ..., state, is_hint (u8), same_screen | 96 | state 80, is_hint 84 |
| `XCrossingEvent` | ..., x_root, y_root, mode, detail, same_screen, focus, state | 104 | mode 80, detail 84, state 96 |
| `XFocusChangeEvent` | type, serial, send_event, display, window, mode, detail | 48 | mode 40 |
| `XConfigureEvent` | type, serial, send_event, display, event, window, x, y, width, height, border_width, above, override_redirect | 88 | width 56, above 72 |
| `XMapEvent` | type, serial, send_event, display, event, window, override_redirect | 56 | window 40 |
| `XUnmapEvent` | type, serial, send_event, display, event, window, from_configure | 56 | window 40 |
| `XClientMessageEvent` | type, serial, send_event, display, window, message_type, format, data (`extern union { b: [20]u8, s: [10]c_short, l: [5]c_long }`) | 96 | message_type 40, format 48, data 56 |
| `XPropertyEvent` | type, serial, send_event, display, window, atom, time, state | 64 | atom 40, state 56 |
| `XSelectionClearEvent` | type, serial, send_event, display, window, selection, time | 56 | selection 40 |
| `XSelectionRequestEvent` | type, serial, send_event, display, owner, requestor, selection, target, property, time | 80 | requestor 40, property 64 |
| `XSelectionEvent` | type, serial, send_event, display, requestor, selection, target, property, time | 72 | property 56 |
| `XErrorEvent` | type, display, resourceid, serial, error_code (u8), request_code (u8), minor_code (u8) | 40 | error_code 32 |
| `XEvent` | `extern union`: type (c_int), xany, xkey, xbutton, xmotion, xcrossing, xfocus, xconfigure, xmap, xunmap, xclient, xproperty, xselectionclear, xselectionrequest, xselection, xerror, pad (`[24]c_long`) | 192 | - |
| `XSetWindowAttributes` | background_pixmap, background_pixel, border_pixmap, border_pixel, bit_gravity, win_gravity, backing_store, backing_planes, backing_pixel, save_under, event_mask, do_not_propagate_mask, override_redirect, colormap, cursor | 112 | event_mask 72, colormap 96 |
| `XSizeHints` | flags (c_long), x, y, width, height, min_width, min_height, max_width, max_height, width_inc, height_inc, min_aspect, max_aspect (each `extern struct { x, y: c_int }`), base_width, base_height, win_gravity | 80 | min_width 24, win_gravity 72 |
| `XClassHint` | res_name, res_class (`?[*:0]u8`) | 16 | - |
| `XColor` | pixel (c_ulong), red, green, blue (u16), flags, pad (u8) | 16 | - |
| `XRRMonitorInfo` (L5) | name (Atom), primary, automatic, noutput, x, y, width, height, mwidth, mheight (c_int), outputs (`?[*]XID`) | 56 | x 20, outputs 48 |

The asserts: one `comptime` block per structure group,
`if (@sizeOf(c_long) == 8 and builtin.target.os.tag == .linux) { if (@sizeOf(XKeyEvent) != 96) @compileError(...); ... }`.
The numbers are the headers' layout worked out from their text: they catch a Zig declaration that drifts from that
text, not a misread header - `linux-abi-check` is the check of the reading.

#### 6.4.4 Constants (values from the headers; each by its C name)

    Event types   KeyPress 2  KeyRelease 3  ButtonPress 4  ButtonRelease 5  MotionNotify 6  EnterNotify 7
                  LeaveNotify 8  FocusIn 9  FocusOut 10  Expose 12  UnmapNotify 18  MapNotify 19  ConfigureNotify 22
                  PropertyNotify 28  SelectionClear 29  SelectionRequest 30  SelectionNotify 31  ClientMessage 33
    Event masks   KeyPressMask 1<<0  KeyReleaseMask 1<<1  ButtonPressMask 1<<2  ButtonReleaseMask 1<<3
                  EnterWindowMask 1<<4  LeaveWindowMask 1<<5  PointerMotionMask 1<<6  ExposureMask 1<<15
                  StructureNotifyMask 1<<17  SubstructureNotifyMask 1<<19  SubstructureRedirectMask 1<<20
                  FocusChangeMask 1<<21  PropertyChangeMask 1<<22
    Modifiers     ShiftMask 1<<0  LockMask 1<<1  ControlMask 1<<2  Mod1Mask 1<<3 (Alt)  Mod4Mask 1<<6 (Super)
    Window        InputOutput 1  CWBorderPixel 1<<3  CWEventMask 1<<11  CWColormap 1<<13  AllocNone 0
    Focus         NotifyNormal 0  NotifyGrab 1  NotifyUngrab 2   RevertToParent 2   CurrentTime 0   None 0
    Grabs         GrabModeAsync 1   GrabSuccess 0
    Properties    PropModeReplace 0   QueuedAfterReading 1   PropertyNewValue 0
    Atoms         XA_ATOM 4  XA_CARDINAL 6  XA_RESOURCE_MANAGER 23  XA_STRING 31
    Size hints    PMinSize 1<<4  PMaxSize 1<<5  PWinGravity 1<<9   StaticGravity 10
    Input method  XIMPreeditNothing 0x0008  XIMStatusNothing 0x0400  XLookupChars 2  XLookupBoth 4  XBufferOverflow -1
                  XNInputStyle "inputStyle"  XNClientWindow "clientWindow"  XNFocusWindow "focusWindow"
    Keysyms       XK_Escape 0xff1b  XK_Return 0xff0d  XK_Insert 0xff63  XK_v 0x76
    Cursor font   XC_X_cursor 0  XC_bottom_left_corner 12  XC_bottom_right_corner 14  XC_crosshair 34  XC_fleur 52
                  XC_hand2 60  XC_left_ptr 68  XC_sb_h_double_arrow 108  XC_sb_v_double_arrow 116  XC_watch 150
                  XC_xterm 152
    EWMH          _NET_WM_STATE_REMOVE 0  _NET_WM_STATE_ADD 1  (source indication: 1, an application)

#### 6.4.5 The libraries' tables

Each a struct of function pointers named exactly as the C functions, filled by `dlsym` in an `inline for` over its
fields (`std.lang.Type.Struct`'s `field_names`, `field_types`), as `vk.loadDispatch`; a missing symbol is
`error.SymbolMissing` naming it. `dlopen` with `.{ .LAZY = true }`, the versioned name first. Never `dlclose`d: the
Vulkan driver may still use Xlib's code at exit.

`Xlib` (`libX11.so.6`, then `libX11.so`) - each Zig type follows the prototype:

| Group | Functions |
|---|---|
| connection | `XInitThreads() Status`; `XOpenDisplay(?[*:0]const u8) ?*Display`; `XCloseDisplay(*Display) c_int`; `XSetErrorHandler(?ErrorHandler) ?ErrorHandler`; `XConnectionNumber(*Display) c_int`; `XDefaultScreen(*Display) c_int`; `XRootWindow(*Display, c_int) XID`; `XDefaultVisual(*Display, c_int) ?*Visual`; `XDefaultDepth(*Display, c_int) c_int`; `XDisplayWidth`, `XDisplayHeight(*Display, c_int) c_int`; `XFlush(*Display) c_int`; `XPending(*Display) c_int`; `XEventsQueued(*Display, c_int) c_int`; `XNextEvent(*Display, *XEvent) c_int`; `XPeekEvent(*Display, *XEvent) c_int`; `XFree(?*anyopaque) c_int` |
| window | `XCreateColormap(*Display, XID, ?*Visual, c_int) Colormap`; `XFreeColormap(*Display, Colormap) c_int`; `XCreateWindow(*Display, XID parent, c_int x, c_int y, c_uint w, c_uint h, c_uint border, c_int depth, c_uint class, ?*Visual, c_ulong mask, *XSetWindowAttributes) XID`; `XDestroyWindow`, `XMapWindow`, `XRaiseWindow(*Display, XID) c_int`; `XIconifyWindow(*Display, XID, c_int screen) Status`; `XMoveWindow(*Display, XID, c_int, c_int) c_int`; `XResizeWindow(*Display, XID, c_uint, c_uint) c_int`; `XSetInputFocus(*Display, XID, c_int revert, Time) c_int`; `XSelectInput(*Display, XID, c_long) c_int`; `XStoreName(*Display, XID, [*:0]const u8) c_int`; `XSetWMProtocols(*Display, XID, [*]Atom, c_int) Status`; `XAllocSizeHints() ?*XSizeHints`; `XSetWMNormalHints(*Display, XID, *XSizeHints) void`; `XAllocClassHint() ?*XClassHint`; `XSetClassHint(*Display, XID, *XClassHint) c_int`; `XSendEvent(*Display, XID, Bool propagate, c_long mask, *XEvent) Status`; `XTranslateCoordinates(*Display, XID src, XID dst, c_int, c_int, *c_int, *c_int, *XID child) Bool` |
| properties | `XInternAtoms(*Display, [*]const [*:0]const u8, c_int, Bool, [*]Atom) Status`; `XGetAtomName(*Display, Atom) ?[*:0]u8`; `XChangeProperty(*Display, XID, Atom property, Atom type, c_int format, c_int mode, [*]const u8, c_int count) c_int`; `XDeleteProperty(*Display, XID, Atom) c_int`; `XGetWindowProperty(*Display, XID, Atom, c_long offset, c_long length, Bool delete, Atom requested, *Atom actual, *c_int format, *c_ulong count, *c_ulong after, *?[*]u8 data) c_int`; `XResourceManagerString(*Display) ?[*:0]u8` |
| keys, text | `XGetKeyboardMapping(*Display, KeyCode first, c_int count, *c_int per_keycode) ?[*]KeySym`; `XkbSetDetectableAutoRepeat(*Display, Bool, ?*Bool) Bool`; `XLookupString(*XKeyEvent, ?[*]u8, c_int, ?*KeySym, ?*anyopaque) c_int`; `XLookupKeysym(*XKeyEvent, c_int index) KeySym`; `XSupportsLocale() Bool`; `XSetLocaleModifiers([*:0]const u8) ?[*:0]u8`; `XOpenIM(*Display, ?*anyopaque, ?[*:0]u8, ?[*:0]u8) ?XIM`; `XCloseIM(XIM) Status`; `XCreateIC(XIM, ...) ?XIC` (variadic: probe P2); `XDestroyIC`, `XSetICFocus`, `XUnsetICFocus(XIC) void`; `XFilterEvent(*XEvent, XID) Bool`; `Xutf8LookupString(XIC, *XKeyEvent, [*]u8, c_int, ?*KeySym, *Status) c_int` |
| pointer | `XGrabPointer(*Display, XID, Bool owner_events, c_uint mask, c_int pointer_mode, c_int keyboard_mode, XID confine_to, Cursor, Time) c_int`; `XUngrabPointer(*Display, Time) c_int`; `XWarpPointer(*Display, XID src, XID dst, c_int, c_int, c_uint, c_uint, c_int x, c_int y) c_int`; `XQueryPointer(*Display, XID, *XID root, *XID child, *c_int root_x, *c_int root_y, *c_int x, *c_int y, *c_uint mask) Bool`; `XCreateFontCursor(*Display, c_uint) Cursor`; `XCreatePixmap(*Display, XID, c_uint, c_uint, c_uint depth) Pixmap`; `XFreePixmap(*Display, Pixmap) c_int`; `XCreatePixmapCursor(*Display, Pixmap source, Pixmap mask, *XColor, *XColor, c_uint, c_uint) Cursor`; `XDefineCursor(*Display, XID, Cursor) c_int`; `XFreeCursor(*Display, Cursor) c_int` |
| clipboard | `XSetSelectionOwner(*Display, Atom, XID, Time) c_int`; `XGetSelectionOwner(*Display, Atom) XID`; `XConvertSelection(*Display, Atom selection, Atom target, Atom property, XID requestor, Time) c_int` |

`XGetKeyboardMapping`'s first parameter is `KeyCode` as `Xlib.h` declares it without `NeedWidePrototypes`; were it
wide, a `u8` still arrives whole in its register - `linux-abi-check` settles the declaration.

`Xcursor` (`libXcursor.so.1`, optional): `XcursorGetTheme(*Display) ?[*:0]u8`, `XcursorGetDefaultSize(*Display) c_int`,
`XcursorLibraryLoadImage([*:0]const u8, ?[*:0]const u8, c_int) ?*XcursorImage`, `XcursorImageLoadCursor(*Display,
*const XcursorImage) Cursor`, `XcursorImageDestroy(*XcursorImage) void`.
`Xrandr` (`libXrandr.so.2`, optional, L5): `XRRGetMonitors(*Display, XID, Bool, *c_int) ?[*]XRRMonitorInfo`,
`XRRFreeMonitors([*]XRRMonitorInfo) void`. `Xss` (`libXss.so.1`, optional, L5): `XScreenSaverSuspend(*Display, Bool) void`.

#### 6.4.6 The pure parts (tested here)

- `xftDpiOf(resources: []const u8) ?f32`: the value of the line starting `Xft.dpi:` (whitespace after the colon
  skipped), parsed as a float, kept when above 0; null otherwise. Tests: `"Xft.dpi:\t144\n"` -> 144; amid other lines;
  `"Xft.dpi:\t96.000000"`; missing; `"Xft.dpi:\t0"` -> null; `"Xft.dpix:\t1"` -> null.
- `codePointOfKeysym(keysym: KeySym) u21`: 0x20-0x7e and 0xa0-0xff are Latin-1 code points; `0x0100_0000 + cp`
  (cp up to 0x10ffff) is Unicode; anything else 0. Tests: `XK_v`, `0xe9`, `0x0100_20ac` (euro), `XK_Return` -> 0.
- `latin1ToUtf8(bytes, out) []const u8` for `XLookupString`'s Latin-1 text.
- `scaleOf(dpi: f32, override: ?f32) f32`: the override (`ZIMR_SCALE`, **[review R3]**) when set and above 0, else
  `dpi / 96`.

#### 6.4.7 The input message (what the window hands the loop)

    pub const InputKind = enum {
        key_press, key_release, text, button_press, button_release, motion, locked_motion,
        enter, leave, focus_in, focus_out, pointer_lock_changed, fullscreen_changed, paste,
    };
    pub const InputMessage = struct {
        kind: InputKind,
        /// A key message's X keycode (evdev code + 8), or a button message's X button number (1 the first).
        detail: u32 = 0,
        /// A key press of a key already down: the server's auto-repeat.
        is_repeat: bool = false,
        /// A key press: what the key types without modifiers on the current layout, lowercased; 0 for nothing.
        label: u21 = 0,
        /// Pointer messages: where, in the window's physical pixels; locked motion: how far.
        x: i32 = 0,
        y: i32 = 0,
        /// The window's scale when the message was made.
        scale: f32 = 1,
        /// Text and paste: UTF-8, in the window's buffer until its next message of that kind.
        text: []const u8 = &.{},
        /// A lock's or fullscreen's outcome.
        is_on: bool = false,
    };

#### 6.4.8 The window

    pub const WindowError = error{ LibraryMissing, SymbolMissing, NoDisplay, CreateWindowFailed, OutOfMemory };
    pub const WindowOptions = struct { title: []const u8, logical_width: u32, logical_height: u32 };

    pub const Window = struct {
        // The members the loop and the host read - win32.Window's names and meanings:
        client_width: u32, client_height: u32,             // physical pixels
        close_requested: bool, minimized: bool, size_changed: bool,
        is_fullscreen: bool = false, monitors_changed: bool = false,
        input_handler: ?InputHandler,
        min_client_width: f32 = 0, min_client_height: f32 = 0, max_client_width: f32 = 0, max_client_height: f32 = 0,
        // X11's own:
        xlib: Xlib, xcursor: ?Xcursor = null, xrandr: ?Xrandr = null, xss: ?Xss = null,
        display: *Display, handle: XID, screen: c_int, root: XID, colormap: Colormap,
        atoms: Atoms,                          // interned at once, `XInternAtoms`
        supports: EwmhSupport,                 // which EWMH atoms `_NET_SUPPORTED` lists
        dpi: f32, scale_override: ?f32,
        input_method: ?XIM = null, input_context: ?XIC = null,
        has_focus: bool = false, is_text_input_on: bool = false,
        has_detectable_repeat: bool = false, uses_evdev_keycodes: bool = true,
        keys_down: StaticBitSet(256), key_press_times: [256]Time,
        is_pointer_inside: bool = false, is_pointer_locked: bool = false,
        lock_center_x: i32 = 0, lock_center_y: i32 = 0, pointer_before_lock_x: i32 = 0, pointer_before_lock_y: i32 = 0,
        cursor_shape: contract.Cursor = .default, cursors: [cursor_shape_count]Cursor (0 = not made), blank_cursor: Cursor,
        owned_clipboard: []u8 = &.{},          // the text we own as CLIPBOARD, on the process heap
        paste_utf8: [32 * 1024]u8, text_utf8: [256]u8,
    };

    Atoms: WM_PROTOCOLS, WM_DELETE_WINDOW, _NET_WM_PING, _NET_WM_PID, _NET_WM_NAME, _NET_WM_ICON_NAME, UTF8_STRING,
           _NET_SUPPORTED, _NET_WM_STATE, _NET_WM_STATE_FULLSCREEN, _NET_WM_STATE_MAXIMIZED_VERT,
           _NET_WM_STATE_MAXIMIZED_HORZ, _NET_WM_STATE_HIDDEN, _NET_ACTIVE_WINDOW, CLIPBOARD, TARGETS, TEXT, INCR,
           ZIMR_SELECTION, CLIPBOARD_MANAGER, SAVE_TARGETS

**Members both windows offer** (what `native_window.Window` means): the fields `client_width`, `client_height`,
`close_requested`, `minimized`, `size_changed`, `is_fullscreen`, `monitors_changed`, `input_handler`, the four size
limits; the methods `open(options) WindowError!void`, `pump()`, `close()`, `scale() f32`, `setTitle([]const u8)`,
`setFullscreen(bool)`, `requestPaste()`, `lockPointer()`, `releasePointerLock()`, `setInputMethodEnabled(bool)`,
`bringToFront()`, `applySizeLimits()`. A comptime check in `native_window.zig` asserts each is declared, so a member
added to one window and not the other fails the build of both, by name.

**`open(options)`**, in order (GLFW's `createNativeWindow`, mach's `initWindow`):

1. `window.* = .{ ... }` whole (the lint's `whole_init_first`).
2. `Xlib.load()` - absent: `error.LibraryMissing`, logged "libX11.so.6 is not installed (Debian, Ubuntu: libx11-6)";
   the optional tables loaded, each absent one logged once as the feature it costs.
3. `XInitThreads()`.
4. When `setlocale(LC_CTYPE, null)` answers `"C"`: `setlocale(LC_CTYPE, "")` (XIM composes in the user's locale).
5. `XOpenDisplay(null)` - null: `error.NoDisplay`, logged with `$DISPLAY`'s value ("unset" when it is).
6. `XSetErrorHandler(&logXError)` - Xlib's default handler ends the program on any protocol error.
7. Screen, root, default visual and depth; `XInternAtoms`; `_NET_SUPPORTED` read (`EwmhSupport`).
8. The scale: `ZIMR_SCALE`, else `Xft.dpi` (`XResourceManagerString`), else 96.
9. The evdev probe: `XGetKeyboardMapping(display, 9, 28, &per)` - keysym `[0]` is `XK_Escape` and `[(36 - 9) * per]` is
   `XK_Return`, else `uses_evdev_keycodes = false` and one warning.
10. `XCreateColormap(root, visual, AllocNone)`; the attributes: `border_pixel` 0, the colormap, the event mask
    (`KeyPress | KeyRelease | ButtonPress | ButtonRelease | EnterWindow | LeaveWindow | PointerMotion | Exposure |
    StructureNotify | FocusChange | PropertyChange`).
11. `XCreateWindow(root, 0, 0, physical width, physical height, 0, depth, InputOutput, visual, CWBorderPixel |
    CWColormap | CWEventMask, &attributes)` (physical = `round(logical x scale)`, at least 1) - 0: `error.CreateWindowFailed`.
12. `XSetWMProtocols(WM_DELETE_WINDOW, _NET_WM_PING)`; `_NET_WM_PID` (`CARDINAL`/32, `getpid()`); `WM_NORMAL_HINTS`
    (`PWinGravity`, `StaticGravity`: a position given is the client area's); `WM_CLASS` (`res_name` the program's
    name, `res_class` "zimr"); the title (`setTitle`).
13. `XSelectInput(root, PropertyChangeMask)`: the root's `RESOURCE_MANAGER` (scale changes, L5).
14. `XkbSetDetectableAutoRepeat(True, &supported)` -> `has_detectable_repeat`.
15. The input method: when `XSupportsLocale()`: `XSetLocaleModifiers("")`, `XOpenIM(display, null, null, null)`, and
    `XCreateIC(im, XNInputStyle, XIMPreeditNothing | XIMStatusNothing, XNClientWindow, handle, XNFocusWindow, handle,
    null)`; any failure: no IM, one line (text then comes from `XLookupString`).
16. The blank cursor: a 1 x 1 depth-1 pixmap, `XCreatePixmapCursor` with it as source and mask, the pixmap freed.
17. `XMapWindow`; then **wait for `MapNotify`, at most 1000 ms** (pumping, `waitForInput`), reading the size the
    window manager gave in the `ConfigureNotify`s on the way **[review]** - the first frame never presents to an
    unmapped window (section 8, B11).
18. `size_changed = false` (as Win32's `open` ends).

**`pump()`**: `while (XPending(display) > 0)`: `XNextEvent`; the keycode kept (some IMs clear it in
`XFilterEvent`); `filtered = XFilterEvent(&event, None) != 0`; `handleEvent(&event, keycode, filtered)`. Then `XFlush`.

**`handleEvent`**, by type:

| Event | Handling |
|---|---|
| `KeyPress` | 1. GLFW's duplicate filter: `diff = time - key_press_times[keycode]`; the press is reported only when `diff == time` or `0 < diff < 1<<31`, and the time kept. 2. `is_repeat = keys_down.isSet(keycode)`; set it. 3. `label = codePointOfKeysym(XLookupKeysym(event, 0))`. 4. A `key_press` message. 5. Text, when not filtered: with the IC focused, `Xutf8LookupString` (256-byte buffer; `XBufferOverflow` drops the text, logged); without it, `XLookupString` (Latin-1 to UTF-8; no bytes but a Unicode keysym: that code point); non-empty -> a `text` message. 6. The paste command: keysym index 0 `XK_v` with `ControlMask` and not `Mod1Mask`, or `XK_Insert` with `ShiftMask` -> `requestPaste()` |
| `KeyRelease` | without detectable repeat, GLFW's peek: `XEventsQueued(QueuedAfterReading) > 0`, `XPeekEvent` a `KeyPress` of the same keycode within 20 ms -> skipped. Else `keys_down.unset`, a `key_release` message |
| `ButtonPress`, `ButtonRelease` | `button_press`/`button_release` with `detail` the button, `x`, `y` |
| `MotionNotify` | unlocked: `motion` at `x`, `y`. Locked: at the centre - the warp's echo - skipped; else `locked_motion` of (`x - centre`, `y - centre`) and `XWarpPointer` back to the centre |
| `EnterNotify` | `is_pointer_inside = true`; `enter` at `x`, `y` |
| `LeaveNotify` | `is_pointer_inside = false`; `leave` |
| `FocusIn` | mode `NotifyGrab`/`NotifyUngrab` ignored; `has_focus = true`; the IC's focus updated (6.4.9); `focus_in` |
| `FocusOut` | mode ignored likewise; `releasePointerLock()` first (the contract's rule); `has_focus = false`; `keys_down` cleared - the engine releases held keys on focus loss, and the window's own record must agree **[review]**; the IC's focus updated; `focus_out` |
| `ConfigureNotify` | a new `width`/`height`: `client_width`, `client_height`, `size_changed = true`; a locked pointer's centre recomputed |
| `MapNotify`, `UnmapNotify` | `minimized = false`, `true` |
| `PropertyNotify` | the window's `_NET_WM_STATE`: `_NET_WM_STATE_HIDDEN` listed -> `minimized` (a compositing window manager may keep a minimized window mapped) **[review]**, and `_NET_WM_STATE_FULLSCREEN`'s change -> `is_fullscreen` and a `fullscreen_changed` message (L4). The root's `RESOURCE_MANAGER` -> the scale re-read (L5) |
| `ClientMessage` | `WM_PROTOCOLS`: `WM_DELETE_WINDOW` -> `close_requested = true`; `_NET_WM_PING` -> the event sent back to the root (`SubstructureNotifyMask | SubstructureRedirectMask`) |
| `SelectionRequest`, `SelectionClear`, `SelectionNotify` | the clipboard (6.4.10, L5) |
| anything filtered but a key event | dropped: it was the input method's |

**`waitForInput(milliseconds: f64)`**: `XPending > 0` -> return; `XFlush`; `poll(&{XConnectionNumber, POLLIN}, 1,
ceil(milliseconds))`; `EINTR` returns.

**`close()`**: the IC, the IM, the cursors, `XDestroyWindow`, `XFreeColormap`, the clipboard handed to the manager
(L5), `XCloseDisplay`. Called by `native_loop.finish` after the Vulkan host's shutdown, as on Windows.

#### 6.4.9 The requests (L4 unless marked)

- **`setInputMethodEnabled(on)`** (from `startTextInput`/`stopTextInput`): `is_text_input_on = on`; the IC focused
  exactly while `has_focus and is_text_input_on` (`XSetICFocus`/`XUnsetICFocus`) - the Windows rule, an input method
  only inside a text field; outside, text still comes, from `XLookupString` **[review]**.
- **`setCursor(contract.Cursor)`**: made once per shape and kept: with Xcursor, `XcursorLibraryLoadImage(name, theme,
  size)` + `XcursorImageLoadCursor` (names `default`, `text`, `pointer`, `crosshair`, `move`, `ew-resize`,
  `ns-resize`, `nwse-resize`, `nesw-resize`, `not-allowed`, `wait`); without, the cursor font (`XC_left_ptr`,
  `XC_xterm`, `XC_hand2`, `XC_crosshair`, `XC_fleur`, `XC_sb_h_double_arrow`, `XC_sb_v_double_arrow`,
  `XC_bottom_right_corner`, `XC_bottom_left_corner`, `XC_X_cursor`, `XC_watch`); `.hidden` the blank cursor.
  `XDefineCursor`; a locked pointer keeps the blank one.
- **`lockPointer()`**: `XQueryPointer` (the position to return to), `XGrabPointer(handle, True, ButtonPress |
  ButtonRelease | PointerMotion, GrabModeAsync, GrabModeAsync, handle, blank_cursor, CurrentTime)` - not
  `GrabSuccess`: a `pointer_lock_changed` false; else the centre computed, `XWarpPointer` there, `is_pointer_locked`,
  a `pointer_lock_changed` true. **`releasePointerLock()`**: `XUngrabPointer`, warp back, the shape's cursor,
  `pointer_lock_changed` false.
- **`setFullscreen(on)`**: `_NET_WM_STATE_FULLSCREEN` not in `supports`: `fullscreen_changed` false. Else the
  `_NET_WM_STATE` client message to the root (`[ADD or REMOVE, FULLSCREEN, 0, 1]`), `is_fullscreen = on`,
  `fullscreen_changed` on - at once, as Windows reports it; a later change made by the window manager arrives through
  `PropertyNotify`.
- **`show(contract.WindowShow)`**: minimized `XIconifyWindow`; maximized the `_NET_WM_STATE` message with both
  `MAXIMIZED` atoms; normal `XMapWindow` and the `MAXIMIZED` atoms removed.
- **`bringToFront()`**: `_NET_ACTIVE_WINDOW` supported: its client message to the root (`[1, CurrentTime, 0]`); else
  `XRaiseWindow` and `XSetInputFocus(RevertToParent)`.
- **`moveClientTo(x, y)`**: `XMoveWindow` (with `StaticGravity`, the client area's corner).
- **`applySizeLimits()`**: `WM_NORMAL_HINTS` with `PMinSize`/`PMaxSize` in physical pixels (logical x scale; a 0
  limit leaves its flag off), then `XResizeWindow` into them when outside.
- **`keyLabel(key, buffer)`** (for `keyName`): the key's keycode (`native_input.x11KeycodeOfEngineKey`),
  `XGetKeyboardMapping` for it, its first keysym's code point uppercased for letters; no code point: the US label.

#### 6.4.10 The clipboard (L5)

- **`setClipboardText(text)`**: the text copied to the heap (`owned_clipboard`, the previous freed);
  `XSetSelectionOwner(CLIPBOARD, handle, CurrentTime)`; not the owner afterwards (`XGetSelectionOwner`): the copy freed,
  one warning.
- **`SelectionRequest`** (another program pastes): target `TARGETS` -> `XChangeProperty(requestor, property, XA_ATOM,
  32, [TARGETS, UTF8_STRING, STRING, TEXT])`; `UTF8_STRING` or `TEXT` -> the bytes as `UTF8_STRING`; `STRING` -> the
  text as Latin-1, characters outside it as `?`; anything else refused (property `None`); a request with property
  `None` (an old client) uses its target as the property. Then a `SelectionNotify` sent to the requestor. The target
  chosen by a pure function, `answerOfTarget`, tested.
- **`SelectionClear`**: another program owns the clipboard now: `owned_clipboard` freed.
- **`requestPaste()`**: owning the clipboard ourselves: our own text, a `paste` at once. Else
  `XConvertSelection(CLIPBOARD, UTF8_STRING, ZIMR_SELECTION, handle, CurrentTime)`; the answer in `SelectionNotify`:
  property `None` and target `UTF8_STRING` -> asked again as `STRING`; else `XGetWindowProperty(..., delete True)`:
  type `INCR` (a large transfer) refused with a log line; `STRING` converted from Latin-1; the bytes (at most
  `paste_utf8.len`, cut at a character boundary) a `paste` message.
- **At `close()`**: owning the clipboard and a `CLIPBOARD_MANAGER` present: `XConvertSelection(CLIPBOARD_MANAGER,
  SAVE_TARGETS, None, ...)`, answering its requests for up to 200 ms until its `SelectionNotify` (GLFW's
  `pushSelectionToManagerX11`), so the copy outlives the program.

#### 6.4.11 Monitors and keep-awake (L5)

- **Monitors**: with Xrandr, `XRRGetMonitors(root, True)`: each monitor's name (`XGetAtomName`), primary, position and
  size (physical, then logical by the one scale), refresh 0 ("cannot tell"); freed. Without: one monitor, the screen
  (`XDisplayWidth`/`Height`). Listed again after `monitors_changed`, which a `ConfigureNotify` of the root sets (the
  root is resized when monitors change). **`currentMonitor`**: the window's centre (`XTranslateCoordinates` to the
  root) inside a monitor's rectangle; else 0.
- **`keepAwake(on)`**: `XScreenSaverSuspend(display, on)` with Xss; without, one line ("keep-awake needs libXss").

### 6.5 `src/native_loop.zig` (L3)

| Lines | Change |
|---|---|
| 1-23 | the header: Windows and X11; "Windows only, for now" (23) goes |
| 39 | `win32` kept (Windows' parts); `const native_window = @import("native_window.zig");` |
| 54 | `var window: native_window.Window = undefined;` |
| 115-117 | `queueInput(message: native_window.InputMessage)`: `if (comptime native_window.is_x11) native_input.translateX11(message, &input) else native_input.translate(message, &input);` |
| 462-477 | `deliverInput`: Windows `runFileDialog(); queueDroppedFiles();` unchanged; X11 (until L8) `dropDialogRequest()`: a press that asked for a dialog is logged once ("file dialogs on Linux come with stage L8") and cleared |
| 479 | `pub const OpenError = native_window.WindowError || error{ OutOfMemory, WindowUnwritten };` |
| 484 | `const has_window_loop: bool = builtin.target.os.tag == .windows or native_window.is_x11;` |
| 560 | `openWindow(options: native_window.WindowOptions)` - its body unchanged: `setInputMethodEnabled(false)`, `input_handler`, `attachWindow` |
| 1299-1355 | `sleepUntilInputOrDue(milliseconds: f64)` and `canSleepPrecisely() bool` (below); `waitForFrame` calls them |
| 1363-1383 | `waitForBeat` calls them |
| 1399, 1544 | `.hidden => sleepWhileHidden(),` (16 ms: `win32.Sleep(16)`; X11 `window.waitForInput(16)`) |
| 1454 | `sleepBriefly(10)` (Windows `win32.Sleep(10)`; X11 `window.waitForInput(10)`) |
| new | `pub fn theWindow() *native_window.Window { return &window; }` - the requests only one system has go to its window directly (`platform/linux.zig`); Windows keeps its wrappers |

The waits, Windows' due times unchanged:

    /// Whether the loop can sleep precisely until input or a due time: X11 always (`poll` on the connection); Windows
    /// with a high-resolution timer only (`frameWaitTimer`).
    fn canSleepPrecisely() bool

    /// Sleeps until input arrives or `milliseconds` pass. Windows: the timer due at `-ceil(milliseconds x 10 000)` units
    /// of 100 ns - the frame's step (1 ms) gives -10 000, `frame_wait_step_100ns` today, and the beat's wait the value
    /// `waitForBeat` computes today - and `MsgWaitForMultipleObjectsEx`. X11: `window.waitForInput(milliseconds)`.
    fn sleepUntilInputOrDue(milliseconds: f64) void

`waitForFrame`: `if (!canSleepPrecisely()) return .draw;` then, while `!tryAcquireAhead()`,
`sleepUntilInputOrDue(frame_wait_step_milliseconds)` (1.0) and `serviceWindow`. `waitForBeat` the same with
`pacer.millisecondsUntilDue(now_ms)`.

### 6.6 `src/native_input.zig` (L3)

**The evdev table** (`linux/input-event-codes.h` as Zig ships it; X keycode = code + 8), every DOM code of the Windows
table and no other, in the same groups:

| DOM code: evdev code |
|---|
| KeyA 30, KeyB 48, KeyC 46, KeyD 32, KeyE 18, KeyF 33, KeyG 34, KeyH 35, KeyI 23, KeyJ 36, KeyK 37, KeyL 38, KeyM 50, KeyN 49, KeyO 24, KeyP 25, KeyQ 16, KeyR 19, KeyS 31, KeyT 20, KeyU 22, KeyV 47, KeyW 17, KeyX 45, KeyY 21, KeyZ 44 |
| Digit0 11, Digit1 2, Digit2 3, Digit3 4, Digit4 5, Digit5 6, Digit6 7, Digit7 8, Digit8 9, Digit9 10 |
| Backquote 41, Minus 12, Equal 13, BracketLeft 26, BracketRight 27, Backslash 43, Semicolon 39, Quote 40, Comma 51, Period 52, Slash 53 |
| Space 57, Escape 1, Enter 28, Tab 15, Backspace 14, Insert 110, Delete 111, Home 102, End 107, PageUp 104, PageDown 109 |
| ArrowRight 106, ArrowLeft 105, ArrowDown 108, ArrowUp 103 |
| F1 59 ... F10 68, F11 87, F12 88 |
| CapsLock 58, ScrollLock 70, NumLock 69, PrintScreen 99 (`KEY_SYSRQ`), Pause 119 |
| ShiftLeft 42, ControlLeft 29, AltLeft 56, MetaLeft 125, ShiftRight 54, ControlRight 97, AltRight 100, MetaRight 126, ContextMenu 127 (`KEY_COMPOSE`, the PC's menu key) and 139 (`KEY_MENU`) |
| Numpad0 82, Numpad1 79, Numpad2 80, Numpad3 81, Numpad4 75, Numpad5 76, Numpad6 77, Numpad7 71, Numpad8 72, Numpad9 73, NumpadDecimal 83, NumpadDivide 98, NumpadMultiply 55, NumpadSubtract 74, NumpadAdd 78, NumpadEnter 96, NumpadEqual 117 |

    const EvdevName = struct { code: u16, dom_code: []const u8 };
    const evdev_names = [_]EvdevName{ ... };                    // the table above
    const engine_key_by_x11_keycode: [256]?KeyboardKey = ...;   // comptime: [code + 8] = keyboardKeyFromDomCode(dom)
    pub fn engineKeyFromX11Keycode(keycode: u32) ?KeyboardKey
    pub fn x11KeycodeOfEngineKey(key: KeyboardKey) ?u8          // the first row naming it (127 for ContextMenu)

**`translateX11(message: x11.InputMessage, queue: *InputQueue)`** - Windows' rules, from X's numbers:

| Kind | Queued |
|---|---|
| `key_press` | `.key_down = .{ .key, .repeat = is_repeat, .label }` - a keycode with no key queues nothing |
| `key_release` | `.key_up = key` |
| `text` | `queue.pushUtf8(text)`: one `.character` per code point `isTypedText` admits; invalid bytes U+FFFD |
| `button_press`, `button_release` | buttons 1, 2, 3 -> left, middle, right; 8, 9 -> back, forward; 10 and up -> DOM 5 and up; each after a `.mouse_move` to (x, y) / scale. 4, 5 (press only) -> `.mouse_wheel` vertical +1, -1; 6, 7 -> horizontal -1, +1; their releases nothing |
| `motion` | `.mouse_move` at (x, y) / scale |
| `locked_motion` | `.pointer_motion` of (x, y) / scale |
| `enter` | `.mouse_move` at (x, y) / scale, then `.mouse_enter` |
| `leave`, `focus_in`, `focus_out` | `.mouse_leave`, `.focus_gained`, `.focus_lost` |
| `pointer_lock_changed`, `fullscreen_changed` | as on Windows, from `is_on` |
| `paste` | `.paste = text` |

Tests (here): the table - keycodes 9 Escape, 22 Backspace, 36 Enter, 38 A, 50 Left Shift, 66 Caps Lock, 133 Left
Meta, 135 ContextMenu; every DOM code of `scancode_names` has an evdev row and the reverse; no keycode named twice but
ContextMenu's; each translation row from a message built in the test (`translatedX11`, the twin of `translated`).

### 6.7 `src/platform/linux.zig` (L3, written further with each stage)

`windows.zig`'s shape; `audio_output_kind = .pull_on_audio_thread`. Until its stage, a request refuses by name at run
time, once (`refuse`, the unwritten platform's), and answers as a platform with nothing would.

| Request | Linux | Stage |
|---|---|---|
| `now` | `@trunc(native_os.monotonicMilliseconds() * 1_000_000.0)` | L3 |
| `monotonicMilliseconds`, `epochMillis` | `native_os`; `clock_gettime(REALTIME)` | L3 |
| `size`, `setTitle`, `requestQuit` | the loop's wrappers | L3 |
| `log` | `console.log` | L3 |
| `loadValue`, `saveValue`, `removeValue` | `native_os` | L3 |
| sockets | `net_core.native_websocket` | L3 |
| files queue | the loop's (shared); dialogs and drops L8 | L3 |
| `monitorCount`, `monitor`, `currentMonitor` | one monitor, the screen; XRandR at L5 | L3 |
| `keyName` | the US label; the layout's at L4 | L3 |
| `gamepad`, `setGamepadRumble` | a script's slots (`native_loop.scriptedGamepad`), else null; evdev at L7 | L3 |
| `startTextInput`, `stopTextInput`, `setTextInputArea` | the loop's wrappers; the area: nothing to place (the IM places its own window) | L4 |
| `setCursor`, `requestPointerLock`, `releasePointerLock`, `requestFullscreen` | the window (`theWindow()`), the loop's wrappers | L4 |
| `showWindow`, `focusWindow`, `setWindowPosition`, `setWindowSizeLimits` | the window | L4 |
| `setClipboardText`, `requestPaste`, `keepAwake` | the window | L5 |
| `openUrl` | `http:`, `https:`, `mailto:` only, as Windows; `xdg-open <url>` through a `native_os.ChildProgram` kept by the platform (its watcher reaps it) | L5 |
| `startAudioPull` ... `audioOutputName` | the ALSA output | L6 |

### 6.8 `src/alsa.zig` and the output (L6)

    pub const Pcm = opaque {};
    pub const Uframes = c_ulong;  Sframes = c_long;
    pub const SND_PCM_STREAM_PLAYBACK: c_int = 0;     SND_PCM_FORMAT_FLOAT_LE: c_int = 14;
    pub const SND_PCM_ACCESS_RW_INTERLEAVED: c_int = 3;   SND_PCM_NONBLOCK: c_int = 1;
    pub const SND_PCM_STATE_PREPARED: c_int = 2;      SND_PCM_STATE_RUNNING: c_int = 3;
    pub const Asound = struct {                        // libasound.so.2
        snd_pcm_open: *const fn (*?*Pcm, [*:0]const u8, c_int, c_int) callconv(.c) c_int,
        snd_pcm_close: *const fn (*Pcm) callconv(.c) c_int,
        snd_pcm_set_params: *const fn (*Pcm, c_int, c_int, c_uint, c_uint, c_int, c_uint) callconv(.c) c_int,
        snd_pcm_get_params: *const fn (*Pcm, *Uframes, *Uframes) callconv(.c) c_int,
        snd_pcm_wait: *const fn (*Pcm, c_int) callconv(.c) c_int,
        snd_pcm_avail_update: *const fn (*Pcm) callconv(.c) Sframes,
        snd_pcm_delay: *const fn (*Pcm, *Sframes) callconv(.c) c_int,
        snd_pcm_writei: *const fn (*Pcm, *const anyopaque, Uframes) callconv(.c) Sframes,
        snd_pcm_recover: *const fn (*Pcm, c_int, c_int) callconv(.c) c_int,
        snd_pcm_start: *const fn (*Pcm) callconv(.c) c_int,
        snd_pcm_state: *const fn (*Pcm) callconv(.c) c_int,
        snd_pcm_drop: *const fn (*Pcm) callconv(.c) c_int,
        snd_strerror: *const fn (c_int) callconv(.c) [*:0]const u8,
        snd_lib_error_set_handler: *const fn (?*const anyopaque) callconv(.c) c_int,
    };

The output, in `platform/linux.zig`, WASAPI's shape **[review: non-blocking, and the start threshold]**:

    startAudioPull(wanted, render_callback)    grants up to two channels at the rate asked; starts the render thread
    render thread:
      load libasound.so.2; its error handler a no-op (mach's cast: the handler type is variadic)
      loop until stopping:
        open "default", PLAYBACK, NONBLOCK; set_params(FLOAT_LE, RW_INTERLEAVED, channels, rate, 1, 20 000 us);
        get_params -> buffer, period; log once "ALSA default: period P ms, buffer B ms"
        failed: render to nowhere at the real rate for a second (Windows' `drainWithoutDevice`), then try again
        stream until a failure or stopping:
          snd_pcm_wait(100 ms)               1 ready, 0 timeout (check stopping), < 0 -> recover
          room = avail_update                < 0 -> recover
          queued = buffer - room             the block's first frame is out after them: first_frame_out_ms
          render min(room, block capacity) frames, writei them; -EAGAIN: wait again; < 0 -> recover
          state PREPARED after a write -> snd_pcm_start
      recover: snd_pcm_recover(err, 1); still failing -> close and reopen after 100 ms
    stopAudio()                                the flag, then join: the thread wakes within 100 ms (the wait's timeout)

**Why the buffer is kept full, not a period and a margin as WASAPI's low-latency stream:** `snd_pcm_set_params` sets
the start threshold to about the whole buffer, so a stream kept fuller than a period but short of the buffer never
starts playing - silence, no error. Keeping it full reaches the threshold; `snd_pcm_start` after a `PREPARED` write
covers what `recover` re-prepares. Latency is then the buffer, 20 ms. A lower-latency fill (sw params' threshold, or
the start called at once) is a measured refinement after L9.

### 6.9 The rest

- **`platform.zig`**: `pub const linux = @import("platform/linux.zig");` `current`: `.native => if (os == .windows)
  windows else if (native_window.is_x11) linux else unwritten`; a test "the Linux platform keeps the contract, on a
  Linux host", the Windows one's twin.
- **`platform/unwritten.zig`**: its header names macOS and Android.
- **`host.zig`, `native_os.zig`** (header lines 16-17): the native window is Win32's or X11's.
- **`src/web/readme.html`**: `-Dplatform=linux`, `zig-out/linux/`, the WSL bench.
- **`src/notes/tutorials/backends-tutorial.html`**: its folds of `SurfaceDispatch` (vk.zig), `bringUp`,
  `createInstance`, `acquireImage` (wgpu_vulkan), `platform.current` and the loop's `has_window_loop` refresh through
  `zig build lint-fix` (Simon's) **[review]**; the prose around them - "the window's surface: Win32's", the surface
  table's one creation command - rewritten in the same turn; chapter 11 gains "X11 through Xlib" with folds of
  `x11.zig`'s `open`, `handleEvent` and `translateX11` (L3, L4). `native_input.translate` keeps its signature, so
  its fold stays valid.
- **Lint, as written** (house rules): no module variables in `x11.zig` or `alsa.zig` (the libraries' tables live in
  the window and the output); time through `native_os` (`own-clock` allows only `src/platform/`, `native_os.zig`,
  `win32.zig`); the file-level `screaming-const` exemption of 6.4.1; declare-before-use; typed locals; `@trunc`/`@round`
  for float to int; `whole_init_first` in `open`.
- **Import graph** (no cycles): `native_window` -> `x11`, `win32`, `vk`; `x11` -> `contract`, `console`, `native_os`;
  `native_input` -> `x11` (types), `win32`; `wgpu_vulkan` -> `native_window`; `native_loop` -> `native_window`;
  `platform/linux` -> `native_loop`, `x11`, `alsa`, `native_os`, `net_core`, `contract`, `console`.

### 6.10 The later stages, in brief (each asks its own decisions when it starts, LX-D13)

- **L7. Gamepads through evdev**: `/dev/input/event*` opened read-only and non-blocking; a gamepad told by its
  `BTN_SOUTH` and `ABS_X` bits (`EVIOCGBIT`); axes scaled by `EVIOCGABS`'s range; the kernel's standard gamepad layout
  (`Documentation/input/gamepad.rst`: `BTN_SOUTH`, `BTN_EAST`, `BTN_NORTH`, `BTN_WEST`, `BTN_TL`/`TR`, `BTN_TL2`/`TR2`,
  `BTN_SELECT`, `BTN_START`, `BTN_MODE`, `BTN_THUMBL`/`R`, `ABS_X`/`Y`/`RX`/`RY`/`Z`/`RZ`, `ABS_HAT0X`/`Y`) mapped to the
  W3C order; rescanned each second for hot-plug (no inotify needed); rumble through `FF_RUMBLE` (`EVIOCSFF`, then an
  `input_event` write). The kernel's `linux/input.h` ships with Zig, so the structures and ioctls are checkable here.
- **L8. Files**: XDND version 5 (`XdndAware` on the window; `XdndEnter`, `XdndPosition` answered `XdndStatus`,
  `XdndDrop` -> `XConvertSelection(XdndSelection, text/uri-list)` -> `XdndFinished`), the URI list parsed by a pure,
  tested function (`file://` only, percent-decoding, CRLF lines); the Load and Save dialogs through `zenity
  --file-selection` (with `--save --confirm-overwrite`) or `kdialog --getopenfilename`/`--getsavefilename`, whichever
  exists, as child programs whose standard output is the path, the frames waiting meanwhile as Windows' modal dialog
  makes them wait.
- **L10. Release and editors**: a `.tar.gz` of `zig-out/linux/` (step and name decided then); `editor-configs` gains a
  Linux debug configuration (gdb or LLDB through WSL).

---

## 7. Probes run (Oct 31, scratch files outside the repo; nothing in the tree compiled)

- **P1 - link for glibc 2.31 from Windows.** A program using what the port uses - `dlopen`/`dlsym`, `setlocale`,
  `poll`, `clock_gettime`, `std.Thread`, `std.Io.Threaded` file reads, `std.process.spawn`, an `std.Io.net` connect -
  built with `zig build-exe -target x86_64-linux-gnu.2.31 -lc`, Debug and ReleaseSafe: **both link.** Their ELF
  (read with a small reader): interpreter `/lib64/ld-linux-x86-64.so.2`; NEEDED `libc.so.6`, `libpthread.so.0`,
  `libdl.so.2` (ReleaseSafe also `ld-linux-x86-64.so.2`); symbol versions `GLIBC_2.2.5` ... **`GLIBC_2.28` at most**.
  So `dlopen` resolves (through `libdl.so.2`, as glibc 2.31 wants), and the binary starts on glibc 2.28 and later.
- **P2 - `XCreateIC`'s variadic call.** A call through `*const fn (?*anyopaque, ...) callconv(.c) ?*anyopaque` with
  GLFW's eight arguments, built for x86_64 Linux: **Debug (the self-hosted backend), ReleaseSafe (LLVM) and Debug
  with `-fllvm` all compile.** No fixed-shape workaround is needed; whether the self-hosted backend's call is right
  is checked by running (L9: XIM on in a Debug build).

---

## 8. The review: where it will break

Each prediction: why, how likely, where it shows, and what the plan does. "Fixed in the plan" means section 6 above
already carries the remedy; "watched" means a check catches it and the fix is known.

**Build and link**

- **B1. `vk-hello-windows` stops compiling at L2** - certain. `vk_hello.zig` calls `createWin32SurfaceKHR` through
  `SurfaceDispatch` (lines 242, 778), which the split takes away. Fixed in the plan (6.2).
- **B2. The template's projects build web pages for a Linux request** - certain once Linux machines default to
  `.linux`: `Project.init`'s `if (platform == .windows) windows_ctx else web_ctx`, and `addApp` falling through to
  the web branch. No error. Fixed in the plan (R1, 6.1).
- **B3. Every non-flagship example has never compiled for Linux** - likely something, small. `platforms-check` covers
  the 35 flagships; the audit found no OS-specific code elsewhere, but an example could still reach an engine path
  (a native-only branch, a `usize` assumption) the flagships do not. Watched: `zig build all-examples
  -Dplatform=linux` once at L3's end (Simon's machine; a long build), its failures fixed per example.
- **B4. A newer glibc symbol pulled in by the engine** - unlikely (P1: 2.28 for the std paths the port uses), but
  the engine pulls more of std than P1. Watched, for good: L1 adds `tools/elf_needs.zig` (P1's reader, in Zig: the
  interpreter, `NEEDED`, the `GLIBC_*` versions an ELF requires), and `platforms-check` runs it on the Linux
  launcher, failing on any version past 2.31 - so a std or engine change that raises the floor fails the gate the
  day it lands. Past 2.31: the symbol avoided, or the floor raised by decision.
- **B5. The tutorial's folds go stale and `doc-gate`/`doc-sync` complain** - certain at L2 and L3. Fixed in the plan
  (6.9: `lint-fix` refreshes the folds; the prose is rewritten in the same turn).
- **B6. Configure time grows** - a fourth set of ~300 programs would. Avoided: Linux examples only under
  `-Dplatform=linux`; only the launcher always.
- **B7. Windows test builds break on `x11.zig`'s layout asserts** - certain if ungated: `src/tests.zig`
  `refAllDecls(native_input)`, which will import `x11.zig`, on a Windows host where `c_long` is 4 bytes. Fixed in the
  plan (principle 3: asserted only on LP64 Linux).
- **B8. A Linux-only window member, or a Windows-only one, used by the shared loop** - the X11 `Window` lacking a
  member the loop or the host reads compiles on Windows and fails only in the Linux build. Fixed in the plan: the
  member check in `native_window.zig` (6.4.8) fails both builds by name.

**Starting up (seen in WSL)**

- **B9. `XOpenDisplay` fails** - possible under `wsl.exe --exec` if WSLg has not set `DISPLAY`. The error prints
  `$DISPLAY`; WSLg sets it for every process it starts. A Linux console without X: `NoDisplay`, by name.
- **B10. Xlib ends the program on an X error** - certain without a handler (Xlib's default calls `exit`): a
  `BadWindow` at teardown, a `BadAtom`. Fixed in the plan (open step 6).
- **B11. The first frame hangs presenting to an unmapped window** - possible: FIFO presentation to a window not yet
  mapped blocks on some drivers (the same family as minimized windows, 7a's L-D7). Fixed in the plan: `open` waits
  for `MapNotify` (step 17); frames stop while unmapped or `_NET_WM_STATE_HIDDEN`.
- **B12. dozen chosen in WSL, then misbehaving** - possible: Mesa's Vulkan-on-D3D12 lists the real GPU as a device
  and may claim what the host requires while getting it wrong. Watched: the host logs the GPU it chose; checklist
  item 1 records it; `ZIMR_GPU=llvmpipe` is the lever.
- **B13. Validation messages new to the windowed path on Linux** - possible: the swapchain, acquire and present paths
  have run under the validation layer on Windows only (headless runs have no swapchain). A message makes the run
  unclean (`finishNative`). Watched: the first WSL run's log; each message fixed in the host.
- **B14. Settings set in PowerShell never reach the Linux program** - certain without `WSLENV`. Fixed in the plan
  (R2: the run forwards zimr's variables, paths translated).

**Input**

- **B15. Keys pressed twice, or text twice, under an input method** - likely with IBus or Fcitx over XIM, which
  re-send key presses. Fixed in the plan: GLFW's timestamp filter; key events reported whether or not filtered, text
  only when not.
- **B16. Keys held across a focus change read as auto-repeat afterwards** - certain if `keys_down` survives focus
  loss (the engine releases keys at `focus_lost`; the window's own record would still say down). Fixed in the plan
  (`FocusOut` clears it).
- **B17. Dead keys type nothing outside text fields** - by design: the IC is focused only in a text field (Windows'
  rule: no input method for a game's keys); outside, `XLookupString` types plain keys. Stated, so it is not reported
  as a bug.
- **B18. Auto-repeat as release-press pairs** on a server without detectable auto-repeat - rare (XKB is everywhere).
  Fixed in the plan: GLFW's 20 ms peek.
- **B19. Keys misplaced on a server whose keycodes are not evdev's** - rare (XQuartz, the long-gone `kbd` driver).
  Watched: the start-up probe's warning; keysyms as a fallback only if a real report asks.
- **B20. Pointer lock in WSLg** - likely broken: RDP sends absolute positions, and XWayland's warp emulation needs
  relative motion. Watched: checklist item 7 on a Linux desktop decides.
- **B21. A locked pointer jitters or drifts** - possible if the warp's echo is not skipped exactly, or the centre goes
  stale after a resize. Fixed in the plan (`ConfigureNotify` recomputes the centre); watched on a desktop.

**Window and scale**

- **B22. zimr scaled twice on a HiDPI GNOME-on-Wayland desktop** - possible: XWayland upscaling X programs while
  `Xft.dpi` also says 192. Watched (checklist 11); the lever is `ZIMR_SCALE` (R3).
- **B23. A scale change ignored** - certain if read from `XResourceManagerString`, which is the value at connection
  time. Fixed in the plan: on the root's `PropertyNotify`, the property itself is read.
- **B24. Fullscreen reported on a window manager without EWMH fullscreen** - certain without the `_NET_SUPPORTED`
  check (the request would be ignored while zimr reports success). Fixed in the plan.
- **B25. The clipboard empty after zimr exits** - X11's normal behaviour (the owner gone). Fixed in the plan
  (`SAVE_TARGETS` to the manager at `close`).
- **B26. A large paste (`INCR`) dropped** - by design in L5, logged; INCR when a report asks.

**Sound**

- **B27. Silence with no error** - certain without care: `snd_pcm_set_params` sets the start threshold to about the
  whole buffer, and a stream kept partly full never starts. Fixed in the plan (6.8: kept full; `snd_pcm_start` after
  a `PREPARED` write).
- **B28. An exit that hangs** - possible with a blocking write on a stalled device. Fixed in the plan: non-blocking,
  `snd_pcm_wait` with a 100 ms timeout.
- **B29. ALSA's error lines on standard error in WSL** ("ALSA lib pcm.c: Unknown PCM default") - certain without
  the pulse plugin. Fixed in the plan (the no-op handler); the platform's own one line says the sound drains unplayed.
- **B30. The no-op error handler's type** - `snd_lib_error_handler_t` is variadic; a non-variadic function passed
  through a cast, as mach does, is ignored arguments on x86_64 and AArch64 Linux. Watched by the first run.

**Backends and declarations**

- **B31. A hand-declared structure or prototype wrong** - likely at least one, in about 25 structures and 90
  functions. Watched: the LP64 asserts catch a Zig typo here; `linux-abi-check` in WSL catches a misread header -
  first thing in the session, before any window opens.
- **B32. A Debug-only miscompile** - possible: Linux Debug builds use the self-hosted backend, Windows' use LLVM. Watched
  (R4): L9 runs Debug and release; a difference turns `use_llvm` on for Linux.

---

## 9. What is checked where

| Check | Here (Windows) | In WSL / on Linux |
|---|---|---|
| every line compiles for x86_64 Linux | the Linux link, `platforms-check` | - |
| links against glibc 2.31; symbol versions | the Linux link; the ELF reader (P1's) | - |
| Xlib and ALSA layouts | LP64 asserts (from the headers' text) | `linux-abi-check` (translate-c) |
| Xlib and ALSA prototypes | - | `linux-abi-check` |
| the Xlib surface structure | `vk-abi-check`, both targets | - |
| translation, key table, parsers | unit tests (`native_input`, `x11`) | - |
| Windows unchanged | Windows builds; Simon's Windows runs | - |
| everything that needs an X server | - | the checklist (10.2) |

---

## 10. The first WSL session (L9)

### 10.1 The WSL bench, once (Simon's choice, LX-D12)

In an administrator PowerShell: `wsl --install -d Ubuntu-24.04`, then a restart. In Ubuntu:

    sudo apt update
    sudo apt install -y mesa-vulkan-drivers vulkan-validationlayers vulkan-tools libasound2-plugins
    printf 'pcm.!default { type pulse }\nctl.!default { type pulse }\n' > ~/.asoundrc
    vulkaninfo --summary        # llvmpipe listed (dozen too, perhaps)
    vkcube                      # a spinning cube: X11 and Vulkan present through WSLg

For `linux-abi-check`, the headers too: `sudo apt install -y libx11-dev libxcursor-dev libxrandr-dev libxss-dev
libasound2-dev`.

### 10.2 The checklist (WSL first; a Linux desktop for 7, 11, 12 and real GPUs)

1. `zig build linux-abi-check -Dlinux-headers=//wsl.localhost/Ubuntu-24.04/usr/include` - every declaration
   against the headers; findings fixed before anything else.
2. `zig build run-hello-world -Dplatform=linux` (from Windows; it starts in WSL) - the GPU chosen (the log's first
   lines), the window, the background, the squares, the text; resize by the corner; minimize and restore; the close
   button ends it with `validation: 0 errors, 0 warnings`. Then the same with `-Dmode=release` (R4).
3. `zig build run -Dplatform=linux` - the native gallery; start three examples from it.
4. `ZIMR_LOG_INPUT=1`, an input example - letters by position on a non-QWERTY layout, repeat, Ctrl+Z's label, digits,
   F-keys, the keypad with Num Lock on and off.
5. Text in a UI field: a dead key, compose (`<Multi_key> ' e`), an IME if installed.
6. The wheel's four directions; buttons 8 and 9; enter and leave.
7. Pointer lock in `fps_playground` (a Linux desktop).
8. Cursors over the UI; fullscreen and back.
9. The clipboard both ways with a Windows program (WSLg shares it); Ctrl+V and Shift+Insert.
10. `openUrl` from an example with a link.
11. A HiDPI desktop: the UI at the desktop's scale; `ZIMR_SCALE`; two monitors listed.
12. Sound: `audio_keyboard` - notes heard, the readout's ALSA line.
13. A scripted run in the window and the same script headless (both in WSL), their captures compared: the window's
    frames are the engine's own, on another surface.

The report goes into the journal; each finding a fix.

---

## 11. What must not break

- The web build: no shared file changes its output.
- Windows: the program's behaviour, the native gallery, `vk-hello-windows`, `platforms-check`.
- The headless platform and its runs: `native_loop.headless` untouched.
- The template's projects on Windows and the web.
- The acyclic import graph (6.9), lint at zero, the tutorials' folds in step.

---

## 12. Journal

- **Oct 31 - the plan, version 1.** Studied `vulkan_port_plan_v2.md` 7a, `platforms_plan.md` (decisions, Phase D,
  the Oct 7 reviews, B9, C4), `platform_api.md`, the platform layer (`contract`, `windows`, `headless`,
  `unwritten`, `template`), `native_loop.zig`, `native_input.zig`, `native_os.zig`, `wgpu_vulkan.zig`'s window seam,
  `vk.zig`'s tables, `tools/vk_gen.zig`, `tools/vk_abi_check.zig`, the build's platforms, contexts and
  `platforms-check`; mach's `Linux.zig`, `X11.zig`, `alsa.zig`. Found: Zig's default glibc floor for x86_64 Linux is
  2.31; the Vulkan SDK 1.4.363.0 is installed (`vk.xml`, `vulkan_xlib.h`); the toolchain ships
  `linux/input-event-codes.h`; WSL is not installed. Decisions asked one at a time: Xlib (agreed, with "I will
  probably want to use wsl2" - which became LX-D12), evdev keys (agreed), all thirteen (agreed; implementation not
  started).
- **Oct 31 - version 2: precise, reviewed.** Every change named by file, line and shape (section 6); the evdev table
  read from the shipped header, every code matching; probes P1 (glibc 2.31 link: both modes, GLIBC_2.28 at most) and
  P2 (the variadic call compiles in Debug and ReleaseSafe); the review (section 8) - 32 predictions, eight of which
  changed the design: projects in L1 (R1), WSL runs through `wsl.exe` always, with `WSLENV` (R2), `ZIMR_SCALE` (R3),
  the Debug backend watched (R4), `vk_hello.zig` in L2, the asserts gated to LP64 Linux, the window waits to be
  mapped, ALSA non-blocking with its start threshold handled. Audit of `examples/` for OS facts: two, both portable.
- **Nov 1 - L1, L2 and L3 written** (Simon: "Implement carefully"). Nothing compiled here; `zig fmt --check`, `zig
  ast-check` and zimrlint with every rule pass on every file touched. The refinements R1-R4 were implemented as section
  5 recommends them.
  - **L1, the build.** `Platform.linux`; `hostPlatform` answers it on Linux; `windows_pending` became `native_pending`
    (`nativePendingReason`); `appBuildFor` and `appRunFor` take `linux_builds`; `installLinuxProgram`,
    `installLinuxApp`, `addLinuxApp`, `linuxRun` (on Windows `wsl.exe --exec ./<name>` from zig-out/linux/, `WSLENV` =
    the caller's own - Simon's `GALLIUM_DRIVER:MESA_D3D12_DEFAULT_ADAPTER_NAME` stay - then zimr's nine settings).
    `linux_glibc_floor` ("2.31") is the one definition of the floor: the triple `x86_64-linux-gnu.2.31` is built from
    it, and so is the check's argument. `build_opts_windows` became `build_opts_native`; the Linux engine is the Windows
    one's twin with libc linked; `linux_app_ctx` is made before the phase split and published (R1), so `Project` builds
    Linux programs (`AppRunner.linux_program`), and the template's header says so. Examples and gallery under
    `-Dplatform=linux` only; the launcher always; the Linux trainer with the lab's Linux build. `platforms-check` links
    the Linux launcher and runs `tools/elf_needs.zig` on it (Linux left `platform_check_targets`). `elf_needs` goes one
    step past B4: it also fails on a library linked by name that glibc does not ship - principle 2 as a check, so an
    accidental `linkSystemLibrary("X11")` cannot slip in. Its tests (a hand-written ELF) are in `tools-test`.
  - **L2, the surface seam.** As 6.2-6.3, with two findings in `vk_gen.zig`: (a) it still wrote `@enumFromInt(0)` as an
    enumeration's default, which Zig 0.18 no longer has - `vk.zig` says `@fromBackingInt(@intCast(0))`, so a
    regeneration would not have compiled; the generator now writes that. (b) A `c_ulong` member (X11's `Window`) would
    have defaulted to `.{}`; `c_ulong` joined the types that default to 0. `src/vk.zig` was edited by hand to exactly
    what the generator should now write (the surface command types moved after the surface's, `Win32SurfaceDispatch` and
    `XlibSurfaceDispatch` split off, `XlibSurfaceCreateInfoKHR`, `StructureType.xlib_surface_create_info_khr =
    1000004000` - extension 5's block - and the two loaders). `vk-abi-check` compiles for Windows and for Linux, the
    reference header gaining the three X11 typedefs and `vulkan_xlib.h`.
  - **L3.** `src/x11.zig` (about 1600 lines: the event structures with their LP64 asserts, the constants, the Xlib
    table, the pure parts with tests, the window); `native_input`'s evdev table (106 rows, checked against the shipped
    header by a script: every code matches), `translateX11`, `InputQueue.pushUtf8`, six tests; the loop on
    `native_window` (one `sleepUntilInputOrDue`, Windows' due times unchanged: the frame's step is -10 000 units as
    before, the beat's the same `@ceil` of the same product); `platform/linux.zig`; `platform.current` picks it.
  - **Where L3 departs from section 6, and why.** (1) `translateX11` queues the pointer's entering before the move to
    where it entered - Windows' order (`message_pointer_entered`, then `WM_MOUSEMOVE`) and a script's; 6.6 had the move
    first. (2) Four of L4's window requests are written now - fullscreen (EWMH), `bringToFront`, the size hints and
    `applySizeLimits` - because the shared loop calls them and each is a few lines; pointer lock is refused at once by
    the window (`pointer_lock_changed` false) and `requestPaste` does nothing, until L4 and L5. (3) Text comes from
    `XLookupString` alone until XIM (L4); GLFW's duplicate filter belongs to XIM, as in GLFW, so it waits too. (4) The
    root's `PropertyChangeMask` (scale changes) is L5's, not selected yet. (5) `WM_CLASS`'s name is
    `native_os.programName`, now public. (6) A failed X request is logged as a warning, not an error: a `BadWindow` at
    teardown must not make a clean run unclean. (7) The clipboard's seven atoms come with L5; the rest of 6.4.8's list
    is interned now. (8) Monitors: one, the X screen, until XRandR (L5). (9) The tutorial's prose (the platform table,
    the dispatch sketch, the unwritten platform, `platforms-check`'s sketch) is rewritten; its code folds refresh with
    `zig build lint-fix`; chapter 11's "X11 through Xlib" comes with L4. (10) WSL's distro is `Ubuntu` (26.04), not
    `Ubuntu-24.04`: section 10's commands and `-Dlinux-headers` path take that name at L9.
  - **Simon's checks, cheapest first**: `src/vk.zig` copied aside, `zig build vk-gen
    -Dvulkan-registry=C:/VulkanSDK/1.4.363.0/share/vulkan/registry/vk.xml`, then `git diff --no-index` of the copy and
    the regenerated file - empty when the hand edit is what the generator writes; any line there is read before it
    stays. `zig build vk-gen-test native-input-test platform-contract-test tools-test`; `zig build vk-abi-check`
    (VULKAN_SDK set: both targets); `zig build vk-hello-windows`; `zig build platforms-check` (the Linux launcher
    linked, `elf_needs` on it); `zig build hello-world -Dplatform=linux`; then in WSL (WSLg), `zig build run-hello-world
    -Dplatform=linux` - lavapipe, the window, resize, close.
- **Nov 1 - the first WSL run.** `zig build run-hello-world -Dplatform=linux` built (211 of 213 steps) and started the
  program in WSL, which crashed opening its window: "Segmentation fault at address 0x0" in
  `native_os.programEnvironment`, reached from `x11.zig`'s `WM_CLASS` (the program's name, through `servicesIo`). It
  read the C library's `environ` variable, which was null in this Debug-built binary - most likely Zig's own linker
  giving the copy of `environ` no alias for glibc's `__environ`, which is what glibc sets (not verified; R4's risk). The
  fix needs no C global: the environment is the block Zig's start code reads before `main` - from `main`'s `envp` with
  libc, from the stack without - and keeps in `std.Options.debug_threaded_io`, in every 0.18 build here (dev.349,
  dev.753). No other code read `environ`.
