//! src/platform.zig - the platforms, and the contract they keep.
//!
//! `contract.zig` defines what every platform provides - the events it reports to the engine, the requests and
//! queries it carries out for it - and checks a platform against it at compile time (`requirePlatform`).
//! `template.zig` is where a new platform starts: every request, each declaring itself not yet written. `web.zig` and
//! `windows.zig` are the platforms with a screen so far, `headless.zig` the one without; `current` is the one a build
//! runs on.

const builtin = @import("builtin");
const host = @import("host.zig");

pub const contract = @import("platform/contract.zig");
pub const template = @import("platform/template.zig");
/// The browser's platform, built only for WebAssembly.
pub const web = @import("platform/web.zig");
/// The Windows platform.
pub const windows = @import("platform/windows.zig");
/// The platform of a build with no window: a headless run, and the host's tests and tools.
pub const headless = @import("platform/headless.zig");

/// The platform a build runs on, chosen by its host (`host.kind`): the browser's for a page, Windows' for a native
/// program on Windows, and the headless one for everything without a window - a headless run, whose frame driver and
/// script talk to that platform (its size, clipboard, gamepads, sound), and the host's tests and tools, which must not
/// open the user's browser or take their clipboard. A native program elsewhere is headless until that system has a
/// platform of its own.
pub const current = switch (host.kind) {
    .web => web,
    .native => if (builtin.target.os.tag == .windows) windows else headless,
    .headless, .none => headless,
};

test {
    _ = contract;
    _ = template;
    _ = headless;
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
