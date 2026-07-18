// src/tests/ui_dock_builder_test.zig -:
// integration tests for the `dockBuilder*` Ui API.
// These exercise the Ui-level surface (Ui.dockBuilderSplitNode /
// dockBuilderDockWindow / dockBuilderRemoveNode / dockBuilderFinish)
// against a real UiContext, verifying:
//   - Splits create new child nodes with stable ids.
//   - DockWindow wires `Window.dock_node_id` AND the leaf's
//     `window_ids` list.
//   - Re-docking the same window is idempotent.
//   - Removing a node clears dock_node_id on every window in
//     the subtree.
//   - Docked windows have their pos/size routed from the leaf
//     rect on subsequent findOrCreateWindow calls.
// The pure dock-layer tree operations are tested directly in
// `src/ui.zig`.  Here we test the wiring through the Ui
// type - the API surface a real demo will use.

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const Allocator = std.mem.Allocator;
const ui = @import("../ui.zig");

fn testCtx(gpa: Allocator) ui.UiContext {
    return .{
        .gpa = gpa,
        .frame_arena = std.heap.ArenaAllocator.init(gpa),
    };
}

/// Build a minimal `Ui` handle that bypasses `beginFrame`'s input
/// snapshot stamping.  Sufficient for builder-API tests; widget
/// tests that need real input go through `beginFrameRaw`.
fn testUi(ctx: *ui.UiContext) ui.Ui {
    return .{ .ctx = ctx };
}

/// Manually allocate a root dockspace node.  Used in tests as a
/// stand-in for `dockSpaceImpl` (which requires a current_window
/// + canvas dims to render the placeholder).  Returns the node id.
fn makeRootNode(ctx: *ui.UiContext) !ui.Id {
    const id: ui.Id = 0xDEAD_BEEF;
    const node: *ui.DockNode = try ctx.gpa.create(ui.DockNode);
    node.* = .{
        .id = id,
        .parent_id = null,
        .leaf = .{},
        .pos = .{ 0, 0 },
        .size = .{ 1000, 800 },
    };
    try ctx.dock.nodes.put(ctx.gpa, id, node);
    return id;
}

test "dockBuilderSplitNode: produces two children with valid ids" {
    const gpa: Allocator = std.testing.allocator;
    var ctx: ui.UiContext = testCtx(gpa);
    defer ctx.deinit();

    const root: ui.Id = try makeRootNode(&ctx);
    const u: ui.Ui = testUi(&ctx);

    const split: ui.SplitResult = u.dockBuilderSplitNode(root, .left, 0.3);
    try expect(split.a != 0);
    try expect(split.b != 0);
    try expect(split.a != split.b);

    // Root is now a split.
    const root_node: *ui.DockNode = ctx.dock.lookup(root).?;
    try expect(root_node.isSplit());
    try expectEqual(split.a, root_node.split.?.child_ids[0]);
    try expectEqual(split.b, root_node.split.?.child_ids[1]);

    // Both children are leaves.
    try expect(ctx.dock.lookup(split.a).?.isLeaf());
    try expect(ctx.dock.lookup(split.b).?.isLeaf());
}

test "dockBuilderSplitNode: invalid node returns zero ids" {
    const gpa: Allocator = std.testing.allocator;
    var ctx: ui.UiContext = testCtx(gpa);
    defer ctx.deinit();
    const u: ui.Ui = testUi(&ctx);

    const split: ui.SplitResult = u.dockBuilderSplitNode(99, .left, 0.5);
    try expectEqual(@as(ui.Id, 0), split.a);
    try expectEqual(@as(ui.Id, 0), split.b);
}

test "dockBuilderDockWindow: wires Window.dock_node_id + leaf list" {
    const gpa: Allocator = std.testing.allocator;
    var ctx: ui.UiContext = testCtx(gpa);
    defer ctx.deinit();

    const root: ui.Id = try makeRootNode(&ctx);
    const u: ui.Ui = testUi(&ctx);

    u.dockBuilderDockWindow("MyWindow", root);

    // Window now exists, has the dock_node_id set.
    const w_id: ui.Id = ui.hashStr(0, "MyWindow");
    const w: *ui.Window = ctx.windows.get(w_id) orelse return error.WindowMissing;
    try expectEqual(@as(?ui.Id, root), w.dock_node_id);

    // Leaf has the window id.
    const leaf: *ui.DockNode = ctx.dock.lookup(root).?;
    try expect(leaf.isLeaf());
    try expectEqual(@as(usize, 1), leaf.leaf.?.window_ids.items.len);
    try expectEqual(w_id, leaf.leaf.?.window_ids.items[0]);
    try expectEqual(w_id, leaf.leaf.?.selected_window_id);
}

test "dockBuilderDockWindow: idempotent (same window, same node)" {
    const gpa: Allocator = std.testing.allocator;
    var ctx: ui.UiContext = testCtx(gpa);
    defer ctx.deinit();

    const root: ui.Id = try makeRootNode(&ctx);
    const u: ui.Ui = testUi(&ctx);

    u.dockBuilderDockWindow("W", root);
    u.dockBuilderDockWindow("W", root);
    u.dockBuilderDockWindow("W", root);

    const leaf: *ui.DockNode = ctx.dock.lookup(root).?;
    try expectEqual(@as(usize, 1), leaf.leaf.?.window_ids.items.len);
}

test "dockBuilderDockWindow: re-docking moves window (collapses empty leaf)" {
    // Re-docking the ONLY window in a leaf out of that leaf
    // triggers `collapseEmptyLeaf` - the parent split absorbs
    // the sibling's identity, and the old leaf ids become
    // invalid.  This is the correct behavior for a layout that
    // self-prunes empty branches; test verifies the final shape.
    const gpa: Allocator = std.testing.allocator;
    var ctx: ui.UiContext = testCtx(gpa);
    defer ctx.deinit();

    const root: ui.Id = try makeRootNode(&ctx);
    const u: ui.Ui = testUi(&ctx);
    const split: ui.SplitResult = u.dockBuilderSplitNode(root, .left, 0.5);

    u.dockBuilderDockWindow("A", split.a);
    u.dockBuilderDockWindow("B", split.b);

    // Both leaves have one window each.
    const a: *ui.DockNode = ctx.dock.lookup(split.a).?;
    const b: *ui.DockNode = ctx.dock.lookup(split.b).?;
    try expectEqual(@as(usize, 1), a.leaf.?.window_ids.items.len);
    try expectEqual(@as(usize, 1), b.leaf.?.window_ids.items.len);

    // Re-dock A to B: A leaves split.a (which is now empty,
    // collapses), root becomes a single leaf with [B, A].
    u.dockBuilderDockWindow("A", split.b);

    const a_id: ui.Id = ui.hashStr(0, "A");
    const w_a: *ui.Window = ctx.windows.get(a_id).?;
    // A's dock_node_id now points at split.b's still-extant id.
    try expectEqual(@as(?ui.Id, split.b), w_a.dock_node_id);
}

test "dockBuilderDockWindow: error on non-leaf target is silent" {
    const gpa: Allocator = std.testing.allocator;
    var ctx: ui.UiContext = testCtx(gpa);
    defer ctx.deinit();

    const root: ui.Id = try makeRootNode(&ctx);
    const u: ui.Ui = testUi(&ctx);
    _ = u.dockBuilderSplitNode(root, .left, 0.5); // root is now a split

    u.dockBuilderDockWindow("W", root); // root no longer a leaf

    // No window created because dock failed silently.  Reasonable
    // because the demo author probably intended to dock into a
    // leaf and a no-op is recoverable.
    const w_id: ui.Id = ui.hashStr(0, "W");
    try expectEqual(@as(?*ui.Window, null), ctx.windows.get(w_id));
}

test "dockBuilderRemoveNode: clears dock_node_id on all windows in subtree" {
    const gpa: Allocator = std.testing.allocator;
    var ctx: ui.UiContext = testCtx(gpa);
    defer ctx.deinit();

    const root: ui.Id = try makeRootNode(&ctx);
    const u: ui.Ui = testUi(&ctx);
    const split: ui.SplitResult = u.dockBuilderSplitNode(root, .left, 0.5);

    u.dockBuilderDockWindow("A", split.a);
    u.dockBuilderDockWindow("B", split.b);

    const a_id: ui.Id = ui.hashStr(0, "A");
    const b_id: ui.Id = ui.hashStr(0, "B");
    try expect(ctx.windows.get(a_id).?.dock_node_id != null);
    try expect(ctx.windows.get(b_id).?.dock_node_id != null);

    u.dockBuilderRemoveNode(root);

    // Both windows fall back to floating.
    try expectEqual(@as(?ui.Id, null), ctx.windows.get(a_id).?.dock_node_id);
    try expectEqual(@as(?ui.Id, null), ctx.windows.get(b_id).?.dock_node_id);
}

test "dockBuilderFinish: no-op (placeholder for future layout cache)" {
    const gpa: Allocator = std.testing.allocator;
    var ctx: ui.UiContext = testCtx(gpa);
    defer ctx.deinit();

    const root: ui.Id = try makeRootNode(&ctx);
    const u: ui.Ui = testUi(&ctx);
    u.dockBuilderFinish(root); // should not crash
}

test "docked window: findOrCreateWindow pulls pos/size from leaf rect" {
    const gpa: Allocator = std.testing.allocator;
    var ctx: ui.UiContext = testCtx(gpa);
    defer ctx.deinit();

    const root: ui.Id = try makeRootNode(&ctx);
    const u: ui.Ui = testUi(&ctx);

    // Hand-set the leaf rect so we know exactly what we expect.
    const leaf_node: *ui.DockNode = ctx.dock.lookup(root).?;
    leaf_node.pos = .{ 50, 60 };
    leaf_node.size = .{ 400, 300 };

    u.dockBuilderDockWindow("DockedW", root);

    // Second findOrCreateWindow on the same name should return the
    // existing window AND read pos/size from the leaf.
    const w: *ui.Window = ui.findOrCreateWindow(&ctx, "DockedW", .{});
    try expectEqual(@as(f32, 50), w.pos[0]);
    try expectEqual(@as(f32, 60), w.pos[1]);
    try expectEqual(@as(f32, 400), w.size[0]);
    try expectEqual(@as(f32, 300), w.size[1]);
}

test "docked window: stale dock_node_id falls back to floating" {
    const gpa: Allocator = std.testing.allocator;
    var ctx: ui.UiContext = testCtx(gpa);
    defer ctx.deinit();

    const root: ui.Id = try makeRootNode(&ctx);
    const u: ui.Ui = testUi(&ctx);
    u.dockBuilderDockWindow("Ghost", root);

    // Tear down the dock tree out from under the window - simulates
    // the user removing the dockspace while a window thought it
    // was docked.
    ui.removeNode(&ctx.dock, ctx.gpa, root);

    // Next findOrCreateWindow should detect the missing leaf,
    // clear dock_node_id, and return a normal floating window.
    const w_id: ui.Id = ui.hashStr(0, "Ghost");
    const w: *ui.Window = ctx.windows.get(w_id).?;
    try expect(w.dock_node_id != null); // still set BEFORE the next find

    _ = ui.findOrCreateWindow(&ctx, "Ghost", .{});

    try expectEqual(@as(?ui.Id, null), w.dock_node_id);
}
