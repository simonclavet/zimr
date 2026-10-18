//! A kernel that writes storage-buffer elements reached by constant indices, at one level and at two: element 2 of a
//! `[16]f32`, and element (1, 2) of a `[4][3]f32`. A constant index is lowered from the pointer's value rather than
//! from a run-time instruction, by a different path in the compiler's SPIR-V backend; this kernel is the native host
//! test's check that the path's access chains are well typed (the validation layer judges the pipeline) and reach the
//! elements named (the values are read back). The grid's rows are three wide, not two or four: kompute views rows of
//! two or four floats as vectors, and this checks arrays.

const k = @import("kompute");

pub const config = k.Config{ .max = 16, .workgroup = 64 };

pub const Buffers = extern struct {
    values: [16]f32,
    grid: [4][3]f32,
};

pub const Params = extern struct {
    count: u32,
    _pad0: u32 = 0,
    _pad1: u32 = 0,
    _pad2: u32 = 0,
};

pub const g = k.Globals(@This());

const b_values = g.bind(.values);
const b_grid = g.bind(.grid);

/// What the kernel writes, for the check to compare: the value at `values[2]`, and the value at `grid[1][2]`.
pub const value_written: f32 = 1.5;
pub const grid_value_written: f32 = 7.0;

/// The one entry: the first thread writes both elements; the others do nothing.
pub fn writeConstantElements(c: k.Ctx(@This())) void {
    if (c.id != 0) {
        return;
    }
    b_values[2] = value_written;
    b_grid[1][2] = grid_value_written;
}

pub const kernels = [_][:0]const u8{"writeConstantElements"};

comptime {
    k.installKernel(@This(), "writeConstantElements");
}
