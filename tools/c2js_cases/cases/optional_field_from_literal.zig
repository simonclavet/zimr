// An optional struct field assigned a struct literal: the C backend writes the payload, then the null flag through the
// field's address - `(&x)->is_null = false` - which c2js once dropped, leaving the optional empty after being set (a
// page's report, set and then read back as null). Through a global, through a pointer, and in a local struct.
const Report = struct { blocks: u32, peak: f32 };
const Holder = struct { report: ?Report = null, count: u32 = 0 };
var global_holder: Holder = .{};

fn setThroughPointer(holder: *Holder, blocks: u32) void {
    holder.report = .{ .blocks = blocks, .peak = 0.5 };
}

export fn run_test() i32 {
    // A global's optional field, set from a literal.
    global_holder.report = .{ .blocks = 7, .peak = 0.25 };
    if (global_holder.report == null) return 1;
    if (global_holder.report.?.blocks != 7) return 2;
    // Through a pointer.
    var local_holder: Holder = .{};
    setThroughPointer(&local_holder, 11);
    if (local_holder.report == null) return 3;
    if (local_holder.report.?.blocks != 11) return 4;
    // A local struct's field, set, cleared and set again.
    local_holder.report = null;
    if (local_holder.report != null) return 5;
    local_holder.report = .{ .blocks = 13, .peak = 1 };
    if (local_holder.report) |report| {
        if (report.blocks != 13) return 6;
    } else return 7;
    return 0;
}
