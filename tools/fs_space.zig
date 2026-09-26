//! fs_space - free disk space, on whatever platform this is.
//!
//! Extracted from `build.zig`, which had the only correct copy. `tools/measure.zig` grew a
//! SECOND one that was Linux-only and returned 0 on failure - a number that reads as "no space
//! left" rather than "did not ask". Two copies of a hand-declared kernel ABI is one too many,
//! and the wrong one was the newer one.
//!
//! Nothing in this Zig's std exposes filesystem statistics: no `statfs` wrapper, no
//! `GetDiskFreeSpaceEx` binding. Every platform is declared here by hand, so every platform is
//! a place to be wrong - which is the argument for having exactly one of them.
//!
//! -- WHAT IS VERIFIED, AND WHAT IS NOT --
//!
//! The Linux path is checked against `df -m /` and agrees to the megabyte. The Windows path is
//! the documented `GetDiskFreeSpaceExA` contract and has NOT been run - there is no Windows
//! machine here. macOS returns null rather than a guess: its `statfs` needs libc linkage and a
//! different struct (`f_bsize` is 32-bit there, and the mount-name arrays change the layout),
//! and a wrong struct does not fail loudly - it returns plausible garbage.
//!
//! **Returning `null` is the honest answer for a platform this has not been tested on.** Every
//! caller must render it as "n/a" rather than substituting a zero.

const std = @import("std");
const builtin = @import("builtin");

pub const DiskSpace = struct {
    free_bytes: u64,
    used_pct: f64,
};

/// x86_64 Linux `struct statfs`. Zig's std exposes the syscall NUMBER but no struct, so the
/// layout is spelled out. It is correct for 64-bit Linux; a 32-bit target would need the
/// `statfs64` variant, which is why the switch below tests pointer width.
const LinuxStatfs = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
};

const Kernel32 = struct {
    extern "kernel32" fn GetDiskFreeSpaceExA(
        directory_name: ?[*:0]const u8,
        free_bytes_available_to_caller: ?*u64,
        total_number_of_bytes: ?*u64,
        total_number_of_free_bytes: ?*u64,
    ) callconv(.winapi) c_int;
};

fn f64of(v: u64) f64 {
    return @floatFromInt(v);
}

/// Free space and percent-used for the filesystem holding the current directory.
///
/// `null` means "this platform is not implemented here", never "the disk is full".
pub fn query() ?DiskSpace {
    switch (builtin.os.tag) {
        .linux => {
            // 32-bit Linux lays `struct statfs` out differently and needs the `statfs64`
            // syscall. Rather than declare a second struct that cannot be tested from here,
            // say so.
            if (@sizeOf(usize) != 8) {
                return null;
            }
            var st: LinuxStatfs = undefined;
            const rc: usize = std.os.linux.syscall2(
                .statfs,
                @intFromPtr("."),
                @intFromPtr(&st),
            );
            if (@as(isize, @bitCast(rc)) < 0 or st.f_bsize <= 0) {
                return null;
            }
            const bsize: u64 = @intCast(st.f_bsize);
            const used_blocks: u64 = st.f_blocks -| st.f_bfree;
            // Percent-used is computed against USED + AVAILABLE, not against total blocks.
            // A filesystem reserves some fraction for root, and counting that reserve as
            // space-you-have makes a disk look healthier than `df` says it is.
            const denom: u64 = used_blocks + st.f_bavail;
            if (denom == 0) {
                return null;
            }
            return .{
                .free_bytes = st.f_bavail * bsize,
                .used_pct = 100.0 * f64of(used_blocks) / f64of(denom),
            };
        },
        .windows => {
            var avail: u64 = 0;
            var total: u64 = 0;
            if (Kernel32.GetDiskFreeSpaceExA(".", &avail, &total, null) == 0 or total == 0) {
                return null;
            }
            const used: u64 = total -| avail;
            return .{
                .free_bytes = avail,
                .used_pct = 100.0 * f64of(used) / f64of(total),
            };
        },
        // macOS, the BSDs, WASI: not implemented rather than guessed. See the header.
        else => return null,
    }
}

/// Free megabytes, or null where `query` is null.
pub fn freeMegabytes() ?usize {
    const space: DiskSpace = query() orelse return null;
    return @intCast(space.free_bytes / (1024 * 1024));
}
