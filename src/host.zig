//! THE HOST - which platform the engine runs on, stated as three comptime facts.
//!
//! zimr runs on four kinds of host:
//!
//!     web       the browser: WebGPU through `bridge.zig`, the page's DOM, WebAudio - every wasm build
//!     native    a desktop program: Vulkan through `wgpu_vulkan.zig`, a window from the operating system
//!     headless  a program without a window: Vulkan drawing into a screen of its own (the Vulkan host's), a clock
//!               the program sets, frames counted out - how examples run with their frames read back
//!     none      no platform at all: host tests and tools, where every GPU call returns its invalid default
//!
//! Engine code asks for the FACT it depends on, never for the kind or the CPU architecture - "is this a wasm build"
//! once stood for all three facts at once, and a native program is exactly where they come apart:
//!
//!     is_browser   the page and the browser's own APIs exist (DOM overlays, localStorage, WebAudio)
//!     has_gpu      GPU calls reach a real device (web or native)
//!     has_window   there is a surface to draw into and input arriving (web, native or headless: a headless run's
//!                  surface is its screen, its input a script)
//!     drives_own_frames  the program calls its own frames (native, headless); the browser calls a page's
//!
//! The build chooses the kind: the native (`-windows`) steps set `host = "native"` in `build_options`. Without the
//! option, a wasm build is `web` and anything else is `none` - the rule every existing build already followed, so
//! they all keep their behaviour.

const build_options = @import("build_options");
const builtin = @import("builtin");
const std = @import("std");

const stringToEnum = std.meta.stringToEnum;
const Allocator = std.mem.Allocator;

pub const Kind = enum { web, native, headless, none };

/// The build's choice when it makes one; otherwise web for wasm and none for everything else.
fn chosenKind() Kind {
    if (@hasDecl(build_options, "host")) {
        return stringToEnum(Kind, build_options.host) orelse
            @compileError("build_options.host must be \"web\", \"native\", \"headless\" or \"none\"");
    }
    // lint:off arch-check: a wasm build runs in the browser unless told otherwise
    return if (builtin.cpu.arch.isWasm()) .web else .none;
}

pub const kind: Kind = chosenKind();

pub const is_browser: bool = kind == .web;
pub const has_gpu: bool = kind != .none;
pub const has_window: bool = kind != .none;
pub const drives_own_frames: bool = kind == .native or kind == .headless;

/// The process heap the engine's allocators sit on: the wasm allocator in the browser (wasm's linear memory), the
/// thread-safe general allocator everywhere else. A memory-model fact rather than a platform service, so it follows
/// the architecture.
// lint:off arch-check: wasm's own allocator grows its linear memory
pub const heap: Allocator = if (builtin.cpu.arch.isWasm()) std.heap.wasm_allocator else std.heap.smp_allocator;
