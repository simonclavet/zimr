//! Which of the display's frames an app draws, to hold it to a highest rate (`Config.max_frames_per_second`): a
//! browser asks for a frame at the display's own rate - 120 a second on many phones - and a native window's frames
//! come at its display's, 144 a second on some laptops. Frames are due on a beat, one period apart: a frame runs when
//! the display's frame comes at most `early_allowance_ms` before the next beat, and the beat moves on by one period
//! from where it was, not from when the frame came - so a 120 Hz display draws every other frame, and a 90 Hz one two
//! frames in three, both 60 a second on average. A frame later than a whole period past its beat - a stall, a hidden
//! tab, the first frame - starts the beat again from itself, so that the frames missed are not run in a burst to catch
//! up.
//!
//! The browser's frame driver lets a display frame that is not due pass undrawn (`wgpu_app.update`); a native window's
//! sleeps until one is (`native_loop.waitForBeat`).

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

const FramePacer = @This();

/// When the next frame is due, in milliseconds on the frame driver's clock; 0 before the first frame.
next_due_ms: f64 = 0,

/// How early a display frame may come and still be taken for the beat: 2 ms. Display frames come with some jitter, and
/// one a hair before the beat would otherwise wait a whole display frame more.
pub const early_allowance_ms: f64 = 2;

/// How long from `now_ms` until a frame would be taken for the beat, in milliseconds: zero or less when one would be
/// taken now.
pub fn millisecondsUntilDue(pacer: *const FramePacer, now_ms: f64) f64 {
    return pacer.next_due_ms - early_allowance_ms - now_ms;
}

/// Whether the display's frame at `now_ms` is drawn, at `frames_per_second` at most; when it is, the beat moves on.
pub fn shouldRun(pacer: *FramePacer, now_ms: f64, frames_per_second: f32) bool {
    const is_too_early: bool = pacer.millisecondsUntilDue(now_ms) > 0;
    if (is_too_early) {
        return false;
    }
    const period_ms: f64 = 1000.0 / @as(f64, frames_per_second);
    const next_on_beat_ms: f64 = pacer.next_due_ms + period_ms;
    const has_fallen_behind: bool = next_on_beat_ms < now_ms;
    pacer.next_due_ms = if (has_fallen_behind) now_ms + period_ms else next_on_beat_ms;
    return true;
}

test "FramePacer: 60 frames a second from a display at 60, 120 or 144 Hz" {
    const display_rates = [_]f64{ 60, 120, 144 };
    for (display_rates) |display_frames_per_second| {
        var pacer: FramePacer = .{};
        const display_period_ms: f64 = 1000 / display_frames_per_second;
        const display_frame_count: u32 = @round(10 * display_frames_per_second);
        var now_ms: f64 = 1000;
        var frames_drawn: u32 = 0;
        for (0..display_frame_count) |_| {
            if (pacer.shouldRun(now_ms, 60)) {
                frames_drawn += 1;
            }
            now_ms += display_period_ms;
        }
        try expectEqual(@as(u32, 600), frames_drawn);
    }
}

test "FramePacer: a frame a period late starts the beat again from itself, and is due a period later" {
    const period_ms: f64 = 1000.0 / 60.0;
    var pacer: FramePacer = .{};
    try expectEqual(true, pacer.shouldRun(1000, 60));
    // A second's stall: the frame after it runs, and one a millisecond later does not - no burst to catch up.
    try expectEqual(true, pacer.shouldRun(2000, 60));
    try expectEqual(false, pacer.shouldRun(2001, 60));
    // What a native window sleeps for until the next: the rest of the period, less the early allowance.
    const expected_wait_ms: f64 = 2000 + period_ms - early_allowance_ms - 2001;
    try expectApproxEqAbs(expected_wait_ms, pacer.millisecondsUntilDue(2001), 1e-9);
    try expectEqual(true, pacer.shouldRun(2000 + period_ms, 60));
}
