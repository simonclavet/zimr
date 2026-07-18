// src/tests/ext_storage_test.zig
//
// Cross-cutting integration test for Q2 typed-generic state
// storage.  The unit tests in `src/ui.zig` cover the
// implementation paths (round trip, type isolation, persist
// recording).  This file tests the SHAPE that an extension
// author actually writes — get-or-put, mutate in place,
// repeat next frame.
//
// Plus: the lint-zimr lint-rule audit catches the public-API
// names reachable through `z.ui.X`, since example-author code
// imports `zimr` not `ui.zig`.

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
// GL-retirement P5a: retargeted at the LIVE umbrella — the namespace
// shape these tests guard is now zimr's.
const z = @import("../zimr.zig");

test "Q2 extension pattern: get-or-put + mutate + read next frame" {
    var ctx: z.ui.UiContext = z.ui.UiContext.init(std.testing.allocator);
    defer ctx.deinit();
    const u: z.ui.Ui = .{ .ctx = &ctx };

    // Hypothetical extension widget state.
    const KnobState = struct {
        angle: f32 = 0,
        drag_origin: ?@Vector(2, f32) = null,
    };

    // Frame 1: first call to the hypothetical knob() — no prior
    // state, so init a fresh one.
    const id: z.ui.Id = 0xCAFE;
    const r1 = u.getOrPutState(KnobState, id, .{});
    if (!r1.found_existing) {
        r1.value_ptr.* = .{};
    }
    try expectEqual(@as(f32, 0), r1.value_ptr.angle);
    r1.value_ptr.angle = 1.5; // user dragged

    // Frame 2: same id, slot already exists; sees the mutation.
    const r2 = u.getOrPutState(KnobState, id, .{});
    try expect(r2.found_existing);
    try expectEqual(@as(f32, 1.5), r2.value_ptr.angle);
}

test "extension pattern: StateOpts reachable through z.ui namespace" {
    var ctx: z.ui.UiContext = z.ui.UiContext.init(std.testing.allocator);
    defer ctx.deinit();
    const u: z.ui.Ui = .{ .ctx = &ctx };

    const TestState = struct { val: i32 = 0 };
    // The `.{ .persist = true }` should resolve through z.ui.StateOpts
    // — proves the type is reachable via the public namespace and
    // not just internal to ui.zig.
    const opts: z.ui.StateOpts = .{ .persist = true };
    _ = u.getOrPutState(TestState, 0, opts);
}
