# The platform API

Decided Oct 7, 2026, for the web and Windows. Every later platform implements the same API; this document is what
"adding a platform" means. It follows three references read in full: SDL3 (its main callbacks, its video backend
contract in `SDL_sysvideo.h`, its text input, high-DPI and gamepad designs, its Windows backend), sokol
(`sokol_app.h`'s event set and Android threading, `sokol_audio.h`) and raylib (`rcore_template.c`).

## 1. Three boundaries

| Boundary | What crosses it | Where it is defined |
|---|---|---|
| App and engine | zimr's public API | unchanged: no example changes, ever |
| Engine and platform | events into the engine; requests and queries out of it | this document; `src/platform/contract.zig` |
| Engine and GPU host | the WebGPU-shaped host calls | `gpu_abi.zig`'s host interface, plus surfaces (section 7) |

## 2. Principles

1. **The platform owns the loop.** It calls the engine's `frame` and `event`; the engine never waits for, polls or
   blocks on the operating system. SDL3's main callbacks (`SDL_AppIterate`, `SDL_AppEvent`) and sokol's `sapp_desc`
   reach the same design for the same reason: iOS, Android and the browser all require it.
2. **One contract, checked.** Every function the engine needs from a system is declared once (`contract.zig`) and
   checked at compile time against each platform module. What a platform cannot do it declares, with the reason:
   `@compileError("the browser sizes the page; there is no window to resize")` inside the function, as the GPU host's
   stubs do.
3. **Events for what happens, queries for what is.** Input, lifecycle changes and the results of asynchronous
   requests are events, delivered in order before the frame that sees them. State the engine reads each frame - the
   size, the scale, the time, the gamepads - is queried.
4. **The browser's units everywhere.** Logical (CSS) pixels and one scale (physical pixels per logical pixel,
   `devicePixelRatio`); keys by DOM `KeyboardEvent.code`; mouse buttons in the DOM's numbering; the wheel in
   notches. Each platform converts at its edge. SDL3's high-DPI table is the list of conversions: Windows, X11 and
   Android speak physical pixels (divide by the scale), macOS, iOS and Wayland speak logical points (already ours).
5. **What a platform may grant later is asynchronous everywhere.** Pointer lock, fullscreen and reading the
   clipboard need a user gesture or a permission in the browser, so the request returns nothing and an event reports
   the outcome - on Windows too, where the event simply arrives before the next frame. One shape for every platform.
6. **Text input is a mode, with properties and a place.** A text field turns it on when it gains focus and tells
   the platform where its caret is (SDL3's `SDL_StartTextInputWithProperties`, `SDL_SetTextInputArea`). That is what
   puts an input method's candidate window beside the caret and a phone's keyboard on screen - a stream of
   characters can do neither.
7. **Positions, not labels.** Keys by physical position; gamepad face buttons by position - south, east, west,
   north - because the same position is A on an Xbox pad, cross on a PlayStation pad and B on a Nintendo one
   (SDL3's `SDL_GamepadButton`). The W3C standard gamepad numbers its buttons in the same order.
8. **One thread talks to the engine.** The platform calls `frame` and `event` from one thread; its own threads (audio,
   jobs) reach the engine only through the handoffs declared here (the audio queue, the job results).

## 3. Events: platform to engine

```zig
pub const Event = union(enum) {
    key_down: KeyDown,
    key_up: KeyUp,
    text: Text,
    composition: Composition,
    mouse_move: MouseMove,
    mouse_button_down: MouseButton,
    mouse_button_up: MouseButton,
    mouse_wheel: Wheel,
    mouse_enter,
    mouse_leave,
    touch_begin: Touch,
    touch_move: Touch,
    touch_end: Touch,
    touch_cancel: Touch,
    motion: Motion,
    resized: Size,
    focus_gained,
    focus_lost,
    hidden,
    shown,
    quit_requested,
    pointer_lock_changed: bool,
    fullscreen_changed: bool,
    paste: Text,
    gamepad_connected: GamepadSlot,
    gamepad_disconnected: GamepadSlot,
};

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _unused: u2 = 0,
};

pub const KeyDown = struct { key: KeyboardKey, repeat: bool, modifiers: Modifiers };
pub const KeyUp = struct { key: KeyboardKey, modifiers: Modifiers };
/// Committed text, while text input is on: UTF-8, short (one message's worth).
pub const Text = struct { bytes: []const u8 };
/// The input method's unfinished text and its cursor, while text input is on; empty when composition ends.
pub const Composition = struct { bytes: []const u8, cursor: u32 };
/// The position, and the movement since the last move in logical pixels - the movement alone counts while the
/// pointer is locked.
pub const MouseMove = struct { x: f32, y: f32, dx: f32, dy: f32, modifiers: Modifiers };
/// A button in the DOM's numbering (0 left, 1 middle, 2 right, 3 back, 4 forward), where it happened.
pub const MouseButton = struct { button: u8, x: f32, y: f32, modifiers: Modifiers };
/// Notches: one per wheel step, positive away from the user and to the right; fractions from fine wheels.
pub const Wheel = struct { dx: f32, dy: f32, modifiers: Modifiers };
pub const Touch = struct { id: u32, x: f32, y: f32 };
pub const Motion = struct { ax: f32, ay: f32, az: f32, screen_angle: f32 };
pub const Size = struct { width: f32, height: f32, scale: f32 };
pub const GamepadSlot = u8;
```

What each event is on the two first platforms:

| Event | Web (DOM) | Windows |
|---|---|---|
| `key_down`, `key_up` | `keydown`, `keyup` (`code`, `repeat`, `getModifierState`) | `WM_KEYDOWN`/`UP`, `WM_SYSKEYDOWN`/`UP` (`native_input.zig`'s rules) |
| `text` | the text agent's `input` (section 5) | `WM_CHAR` (UTF-16 joined), or the IME's result string (`GCS_RESULTSTR`) |
| `composition` | the text agent's `compositionstart`/`update`/`end` | `WM_IME_COMPOSITION` (`GCS_COMPSTR`, `GCS_CURSORPOS`) |
| `mouse_move` | `pointermove` (`offsetX`/`Y`, `movementX`/`Y`) | `WM_MOUSEMOVE`; while locked, raw input (`WM_INPUT`) for the movement |
| `mouse_button_*` | `pointerdown`/`up` (`button`) | `WM_xBUTTONDOWN`/`UP` |
| `mouse_wheel` | `wheel` (`deltaMode` converted to notches) | `WM_MOUSEWHEEL`, `WM_MOUSEHWHEEL` (120 per notch) |
| `mouse_enter`, `mouse_leave` | `pointerenter`, `pointerleave` | the first `WM_MOUSEMOVE` after leaving; `WM_MOUSELEAVE` (`TrackMouseEvent`) |
| `touch_*` | `pointer*` with `pointerType == "touch"`, `pointercancel` | `WM_POINTER*` (later; not needed for the flagships on Windows) |
| `motion` | `devicemotion` | unsupported: no sensor on a desktop |
| `resized` | `ResizeObserver` on the canvas, `devicePixelRatio` changes | `WM_SIZE`, `WM_DPICHANGED` |
| `focus_gained`, `focus_lost` | window `focus`, `blur` | `WM_SETFOCUS`, `WM_KILLFOCUS` |
| `hidden`, `shown` | `visibilitychange` | `WM_SIZE` with `SIZE_MINIMIZED`, then restored |
| `quit_requested` | unsupported: a page closes without asking | `WM_CLOSE` |
| `pointer_lock_changed` | `pointerlockchange` | immediately after the request |
| `fullscreen_changed` | `fullscreenchange` | immediately after the request |
| `paste` | the document's `paste` (Ctrl+V), or `navigator.clipboard.readText` after `requestPaste` | `GetClipboardData(CF_UNICODETEXT)` after `requestPaste` |
| `gamepad_*` | `gamepadconnected`, `gamepaddisconnected` | XInput slot appearing or disappearing (polled once a second) |

**The engine's rules on events** (one place, `receiveEvent`, for every platform):

- `focus_lost` releases every held key and mouse button - closing the browser build's gap, where a key held while the
  page loses focus stays down.
- A pointer lock ends when focus leaves, on every platform, as the browser ends it: `pointer_lock_changed(false)`
  reports it, and the app requests the lock again (in the browser, at the next click). One rule everywhere, rather
  than SDL's desktop behaviour of re-applying the lock when focus returns.
- The byte slices an event carries (`text`, `composition`, `paste`) are valid only while `receiveEvent` handles the
  event; the engine copies what it keeps.
- AltGr is Right Alt alone. Windows reports it as a synthesized Left Ctrl followed by Right Alt; SDL's rule drops the
  Ctrl (a non-extended Ctrl down whose next message is an extended Alt down with the same message time). On the web
  the Ctrl that `getModifierState("AltGraph")` explains is dropped. Typing `@` with AltGr+Q is then never Ctrl+Q.
- `quit_requested` quits unless the app has said otherwise.

## 4. Requests and queries: engine to platform

Each is a function in `contract.zig`; each platform module provides it or declares it unsupported.

| Function | Web | Windows |
|---|---|---|
| `now() u64` - monotonic nanoseconds | `performance.now()` | `QueryPerformanceCounter` |
| `size() Size` | the canvas's CSS size, `devicePixelRatio` | the client rectangle divided by the window's scale |
| `setTitle(text)` | `document.title` | `SetWindowTextW` |
| `requestFullscreen(on)` | `requestFullscreen`, from the next user gesture | borderless over the window's monitor; the previous placement restored |
| `setCursor(Cursor)` | the canvas's CSS `cursor` | `SetCursor` with `IDC_*`, kept by `WM_SETCURSOR` |
| `requestPointerLock()`, `releasePointerLock()` | `requestPointerLock`, from the next user gesture | the cursor hidden and confined (`ClipCursor`), movement from raw input |
| `keepAwake(on)` | `navigator.wakeLock` | `SetThreadExecutionState(ES_DISPLAY_REQUIRED \| ES_CONTINUOUS)` |
| `startTextInput(TextInputOptions)` | the text agent focused, its attributes from the options | the IME enabled for the window (`ImmAssociateContextEx`); off for passwords |
| `setTextInputArea(x, y, width, height, cursor)` | the text agent moved there | `ImmSetCompositionWindow`, `ImmSetCandidateWindow` |
| `stopTextInput()` | the text agent blurred | the IME disabled |
| `setClipboardText(text)` | `navigator.clipboard.writeText` | `SetClipboardData(CF_UNICODETEXT)` |
| `requestPaste()` | `navigator.clipboard.readText` (a permission prompt) | `GetClipboardData`, as a `paste` event |
| `openUrl(url)` | `window.open` | `ShellExecuteW` |
| `loadValue(key, buffer) ?[]u8`, `saveValue(key, bytes)`, `removeValue(key)` | `localStorage` | files in `%APPDATA%\zimr\<app>\`, written to a temporary file and renamed (`MoveFileExW`) |
| `startAudio(AudioFormat) AudioFormat`, `queueAudio(samples)`, `queuedAudioFrames() u32`, `stopAudio()` | an AudioWorklet fed by `postMessage` | WASAPI, shared mode, event driven, on its own thread |
| `gamepad(slot) ?Gamepad` | `navigator.getGamepads()` (the standard mapping) | XInput (`XInputGetState`) |
| `setGamepadRumble(slot, low, high, milliseconds)` | `vibrationActuator.playEffect` | `XInputSetState` |
| `log(level, text)` | `console` | standard error, and `OutputDebugStringW` |

```zig
pub const Cursor = enum {
    default,
    text,
    pointer,
    crosshair,
    move,
    resize_horizontal,
    resize_vertical,
    resize_diagonal_down,
    resize_diagonal_up,
    not_allowed,
    wait,
    hidden,
};

pub const TextInputOptions = struct {
    kind: Kind = .text,
    capitalization: Capitalization = .sentences,
    autocorrect: bool = true,
    multiline: bool = false,

    pub const Kind = enum { text, name, email, username, password, number, numeric_password, url };
    pub const Capitalization = enum { none, sentences, words, letters };
};

pub const AudioFormat = struct { sample_rate: u32, channels: u8 };

/// The W3C standard gamepad: buttons in its order (0 south ... 16 guide), positions not labels.
pub const Gamepad = struct {
    buttons: std.EnumArray(GamepadButton, f32),
    axes: std.EnumArray(GamepadAxis, f32),
};
pub const GamepadButton = enum(u5) {
    south, east, west, north,
    left_shoulder, right_shoulder, left_trigger, right_trigger,
    back, start, left_stick, right_stick,
    dpad_up, dpad_down, dpad_left, dpad_right,
    guide,
};
pub const GamepadAxis = enum(u2) { left_x, left_y, right_x, right_y };
```

The text input options are hints: a platform uses those it can (the web all of them, as the agent's `type`,
`inputmode`, `autocapitalize` and `autocorrect`; Windows only `password`, which keeps the IME off) and ignores the
rest, and the contract's documentation says which.

**Audio is pushed** (sokol's push model): `queueAudio` takes interleaved `f32` samples, one per channel per frame, at
the format `startAudio` returned. The engine mixes in its frame and queues samples ahead of the device -
about 80 ms - and the platform's audio thread or worklet plays from the queue. Pushing works on the web without
shared memory (so standalone pages need no cross-origin isolation), keeps the mixer single-threaded, and a frame
that stalls for less than the lead does not break the sound. The engine resamples to the rate the platform reports.

## 5. The web's text agent

The browser's input methods and on-screen keyboards act on focused text elements, not on a canvas. The proven
pattern (egui's "text agent", Flutter's web engine): a hidden `<input>` - or `<textarea>` when `multiline` - kept
by the bridge, focused by `startTextInput`, placed by `setTextInputArea` under the caret (so the candidate window
and the keyboard appear in the right place), its `type`, `inputmode`, `autocapitalize` and `autocorrect` from the
options. Its `input` events become `text`; its `compositionstart`, `compositionupdate` and `compositionend` become
`composition`; its value is cleared after each committed text. Key events keep coming from `keydown` and `keyup`
(the agent does not swallow navigation keys). SDL's own web backend reads `keypress` instead, and so composes
nothing - the reason for following egui here.

## 6. Windows details, decided from SDL and sokol

- **The drag and menu loops** (`WM_ENTERSIZEMOVE`, `WM_ENTERMENULOOP`): Windows runs its own loop until the drag or
  the menu ends; a timer (`USER_TIMER_MINIMUM`) calls `frame` from inside it, so the window keeps drawing while
  dragged; a count handles nesting; entering releases every held key, since no key-up arrives during the loop (SDL).
  Messages that arrive while `CreateWindowExW` runs are ignored until the window is ready (sokol).
- **Focus gained** (SDL's `WIN_UpdateFocus`): held mouse buttons re-read (`GetAsyncKeyState`), the lock keys' states
  re-read (`GetKeyState`).
- **AltGr's synthesized Left Ctrl** dropped (section 3).
- **Pointer lock**: the cursor hidden and confined to the client area; movement from raw input (`WM_INPUT`,
  `RAWINPUTDEVICE` for the mouse), which is not slowed or stopped by the screen's edge; ended when focus leaves
  (section 3's rule), the confinement released.
- **The IME** on only while text input is on; composition from `WM_IME_COMPOSITION`; the composition and candidate
  windows placed at the text input area.
- **Fullscreen**: borderless over the monitor (`MonitorFromWindow`, `GetMonitorInfoW`), the previous placement
  saved and restored (`GetWindowPlacement`, `SetWindowPlacement`).

## 7. The GPU host's surfaces

Decided now so that no platform needs the host changed later: `attachSurface(native)` (a window handle on Windows,
a canvas on the web, later an X11 window, a `CAMetalLayer`, an `ANativeWindow`), `detachSurface()`, and the
swapchain's three states - absent, valid, invalid (rebuilt each frame until it succeeds; the frame skipped
meanwhile). Rebuilt when the size changes, on `OUT_OF_DATE` and `SUBOPTIMAL`. On the web the canvas is attached
once; on Windows the window once; Android and iOS will detach and reattach as their windows come and go.

## 8. Migration, for the web and Windows

In this order, each step leaving both platforms working:

1. `src/platform/contract.zig`: the event types, the function list, the comptime check, the template platform
   (every function unsupported).
2. `src/platform/web/` and `src/platform/windows/`: today's code moved behind the contract, behaviour unchanged;
   `receiveEvent` in the engine, the one place events land (today's `receiveNativeInput` generalized; the web's
   exported input calls build events and call it).
3. The events the engine lacks, on both: modifiers, movement (`dx`, `dy` - pointer lock's first working version on
   the web), focus (releasing held input), hidden and shown, resized, mouse enter and leave, touch cancel, and the
   asynchronous results.
4. The requests the engine lacks, on both: cursor shapes, fullscreen, pointer lock on Windows, keep awake, open URL on
   Windows, the clipboard on Windows, saved state on Windows.
5. Text input as a mode: the web's text agent; the Windows IME; the UI's text fields calling `startTextInput`,
   `setTextInputArea` and `stopTextInput`.
6. Windows' loops and focus details (section 6).
7. Audio: the engine's mixer and the Vorbis decoder; the push queue; the AudioWorklet on the web, WASAPI on Windows.
8. Gamepads: the standard layout on both (`getGamepads`, XInput).
9. The GPU host's surfaces (section 7).
