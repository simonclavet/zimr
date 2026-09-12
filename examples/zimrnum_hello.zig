const std = @import("std");
const zn = @import("zn");

// A complete program: fit a line to noisy data, then report the error before and after.
pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa: std.mem.Allocator = arena.allocator();

    // 1. Some data. y = 3x + 2, with noise.
    const rng: zn.Rng = .init(20260913);
    const x: zn.Tensor(f64) = try zn.linspace(f64, gpa, 0, 1, 32, .include);
    const y: zn.Tensor(f64) = try zn.Tensor(f64).alloc(gpa, &.{ 32, 1 });
    const noise: zn.Tensor(f64) = try zn.Tensor(f64).alloc(gpa, &.{32});
    rng.fillNormal(f64, noise.data);
    for (0..32) |i| {
        y.data[i] = 3.0 * x.data[i] + 2.0 + 0.1 * noise.data[i];
    }
    const inputs: zn.Tensor(f64) = try x.reshape(&.{ 32, 1 });

    // 2. A layer to fit with.
    const line = try zn.Dense(f64).init(gpa, rng.split(1), 1, 1, .xavier);

    // 3. Train.
    var first: f64 = 0;
    var last: f64 = 0;
    for (0..400) |step| {
        var graph: zn.Graph(f64) = .init(gpa);
        const guess: zn.Dense(f64).Attached = try line.attach(
            &graph,
            try graph.constant(inputs),
        );
        const loss: zn.Var = try graph.mseLoss(guess.out, try graph.constant(y));
        const value: f64 = graph.valueOf(loss).data[0];
        if (step == 0) {
            first = value;
        }
        last = value;
        try graph.backward(loss);
        const dw: zn.Tensor(f64) = try graph.gradOf(guess.weight);
        const db: zn.Tensor(f64) = try graph.gradOf(guess.bias);
        for (line.weight.data, dw.data) |*w, g| {
            w.* -= 0.1 * g;
        }
        for (line.bias.data, db.data) |*b, g| {
            b.* -= 0.1 * g;
        }
    }

    std.debug.print("\n  loss {d:.4} -> {d:.4}\n", .{ first, last });
    std.debug.print(
        "  slope {d:.3} (true 3.0), intercept {d:.3} (true 2.0)\n",
        .{ line.weight.data[0], line.bias.data[0] },
    );
}
