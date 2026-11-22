//! tools/build_note - prints a note the build wrote, the one file it is given, to the standard output as it is: the
//! text of `zig build help-checks` (build.zig's `StepRegistry`). A step cannot print and succeed without a program to
//! run - this Zig's step types are Run, Fail, WriteFile and the like - so this is that program.
const std = @import("std");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io: Io = init.io;
    const arguments: []const [:0]const u8 = try init.minimal.args.toSlice(init.arena.allocator());
    const has_one_note: bool = arguments.len == 2;
    if (!has_one_note) {
        return error.WantsOneNoteFile;
    }
    const cwd: Io.Dir = .cwd();
    const note: []const u8 = try cwd.readFileAlloc(io, arguments[1], init.arena.allocator(), .unlimited);
    var out_buffer: [4096]u8 = undefined;
    var out_writer: Io.File.Writer = Io.File.stdout().writer(io, &out_buffer);
    const out: *Io.Writer = &out_writer.interface;
    try out.writeAll(note);
    try out.flush();
}
