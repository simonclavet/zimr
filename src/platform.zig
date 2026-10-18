//! src/platform.zig - the platforms, and the contract they keep.
//!
//! `contract.zig` defines what every platform provides - the events it reports to the engine, the requests and
//! queries it carries out for it - and checks a platform against it at compile time (`requirePlatform`).
//! `template.zig` is where a new platform starts: every request, each declaring itself not yet written. `web.zig` and
//! `windows.zig` are the platforms with a screen so far, `headless.zig` the one without; `unwritten.zig` stands for
//! Linux, macOS and Android until each has its own, every request refused at run time, so that the engine compiles for
//! them; `current` is the one a build runs on.

const builtin = @import("builtin");
const host = @import("host.zig");

pub const contract = @import("platform/contract.zig");
pub const template = @import("platform/template.zig");
/// The browser's platform, built only for WebAssembly.
pub const web = @import("platform/web.zig");
/// The Windows platform.
pub const windows = @import("platform/windows.zig");
/// Linux, macOS and Android, until each has a platform of its own: every request refused by name at run time.
pub const unwritten = @import("platform/unwritten.zig");
/// The platform of a build with no window: a headless run, and the host's tests and tools.
pub const headless = @import("platform/headless.zig");

/// The platform a build runs on, chosen by its host (`host.kind`): the browser's for a page, Windows' for a native
/// program on Windows, and the headless one for everything without a window - a headless run, whose frame driver and
/// script talk to that platform (its size, clipboard, gamepads, sound), and the host's tests and tools, which must not
/// open the user's browser or take their clipboard. A native program for another system - Linux, macOS, Android - is
/// built on the unwritten platform, which compiles and refuses, until that system has a platform of its own.
pub const current = switch (host.kind) {
    .web => web,
    .native => if (builtin.target.os.tag == .windows) windows else unwritten,
    .headless, .none => headless,
};

test {
    _ = contract;
    _ = template;
    _ = headless;
    _ = unwritten;
}

test "the headless platform keeps the contract" {
    comptime contract.requirePlatform(headless);
}

test "the Windows platform keeps the contract, on a Windows host" {
    if (comptime builtin.target.os.tag == .windows) {
        comptime contract.requirePlatform(windows);
    } else {
        return error.SkipZigTest;
    }
}
