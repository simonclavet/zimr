//! wgsl_reflect.zig - pull the resource bindings out of WGSL source.
//!
//! Every `@group(N) @binding(M) var ...` global, classified by address space /
//! type. Two users: the "shader inspection" surface (`material.reflectWgslBindings`,
//! re-exported through `shader_introspect`), and the BUILD-TIME check in
//! tools/gen_shader_externs.zig that holds every translated shader to the
//! (group, binding) slots its schema promised.
//!
//! std-only on purpose, and host-only: it allocates, so it cannot live in the
//! SHADER-SAFE `shader_interface`, and it must not pull in `wgpu.zig`, because the
//! per-shader build-time checker links it and is compiled once per shader.

const std = @import("std");

// Strings in a `WgslBinding` are owned (duped into the caller's allocator);
// free the whole result with `freeWgslBindings`.

pub const WgslBinding = struct {
    group: u32,
    binding: u32,
    name: []const u8,
    kind: Kind,
    detail: []const u8,

    pub const Kind = enum { uniform, storage, sampler, texture, storage_texture, unknown };

    pub fn kindLabel(self: WgslBinding) []const u8 {
        return switch (self.kind) {
            .uniform => "uniform",
            .storage => "storage",
            .sampler => "sampler",
            .texture => "texture",
            .storage_texture => "storage_texture",
            .unknown => "unknown",
        };
    }
};

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

/// Read the unsigned integer inside the first `attr(...)` occurrence, e.g.
/// `parenU32(chunk, "@group")` on `@group(2)` returns 2.
fn parenU32(chunk: []const u8, attr: []const u8) ?u32 {
    const at: usize = std.mem.indexOf(u8, chunk, attr) orelse return null;
    var i: usize = at + attr.len;
    while (i < chunk.len and (chunk[i] == ' ' or chunk[i] == '\t' or chunk[i] == '(')) : (i += 1) {}
    const start: usize = i;
    while (i < chunk.len and chunk[i] >= '0' and chunk[i] <= '9') : (i += 1) {}
    if (i == start) {
        return null;
    }
    return std.fmt.parseInt(u32, chunk[start..i], 10) catch null;
}

/// Find `word` as a standalone token (identifier boundaries on both sides).
fn indexOfWord(haystack: []const u8, word: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, from, word)) |at| {
        const before_ok: bool = at == 0 or !isIdentChar(haystack[at - 1]);
        const after: usize = at + word.len;
        const after_ok: bool = after >= haystack.len or !isIdentChar(haystack[after]);
        if (before_ok and after_ok) {
            return at;
        }
        from = at + 1;
    }
    return null;
}

/// Copy `wgsl` into `dst` with `//` line comments and `/* */` block comments
/// replaced by spaces (lengths preserved isn't required; we just drop them).
/// Returns the cleaned length written.
fn stripComments(dst: []u8, wgsl: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < wgsl.len) {
        if (i + 1 < wgsl.len and wgsl[i] == '/' and wgsl[i + 1] == '/') {
            while (i < wgsl.len and wgsl[i] != '\n') : (i += 1) {}
        } else if (i + 1 < wgsl.len and wgsl[i] == '/' and wgsl[i + 1] == '*') {
            i += 2;
            while (i + 1 < wgsl.len and !(wgsl[i] == '*' and wgsl[i + 1] == '/')) : (i += 1) {}
            i += 2;
        } else {
            dst[w] = wgsl[i];
            w += 1;
            i += 1;
        }
    }
    return w;
}

/// Reflect every `@group(N) @binding(M) var ...` declaration out of WGSL.
/// Caller owns the result; free with `freeWgslBindings`.
pub fn reflectWgslBindings(gpa: std.mem.Allocator, wgsl: []const u8) ![]WgslBinding {
    const clean: []u8 = try gpa.alloc(u8, wgsl.len);
    defer gpa.free(clean);
    const clean_len: usize = stripComments(clean, wgsl);
    const src: []const u8 = clean[0..clean_len];

    var out: std.ArrayList(WgslBinding) = .empty;
    errdefer {
        for (out.items) |b| {
            gpa.free(b.name);
            gpa.free(b.detail);
        }
        out.deinit(gpa);
    }

    var stmts = std.mem.splitScalar(u8, src, ';');
    while (stmts.next()) |chunk| {
        if (std.mem.indexOf(u8, chunk, "@group") == null) {
            continue;
        }
        const var_at: usize = indexOfWord(chunk, "var") orelse continue;
        const group: u32 = parenU32(chunk, "@group") orelse continue;
        const binding: u32 = parenU32(chunk, "@binding") orelse continue;

        var p: usize = var_at + 3;
        var addr: []const u8 = "";
        while (p < chunk.len and (chunk[p] == ' ' or chunk[p] == '\t')) : (p += 1) {}
        if (p < chunk.len and chunk[p] == '<') {
            const close: usize = std.mem.indexOfScalarPos(u8, chunk, p, '>') orelse continue;
            addr = std.mem.trim(u8, chunk[p + 1 .. close], " \t\r\n");
            p = close + 1;
        }
        const colon: usize = std.mem.indexOfScalarPos(u8, chunk, p, ':') orelse continue;
        const name: []const u8 = std.mem.trim(u8, chunk[p..colon], " \t\r\n");
        const type_str: []const u8 = std.mem.trim(u8, chunk[colon + 1 ..], " \t\r\n");

        var kind: WgslBinding.Kind = .unknown;
        var detail: []const u8 = type_str;
        if (std.mem.startsWith(u8, addr, "uniform")) {
            kind = .uniform;
            detail = type_str;
        } else if (std.mem.startsWith(u8, addr, "storage")) {
            kind = .storage;
            detail = addr;
        } else if (std.mem.startsWith(u8, type_str, "sampler")) {
            kind = .sampler;
        } else if (std.mem.startsWith(u8, type_str, "texture_storage")) {
            kind = .storage_texture;
        } else if (std.mem.startsWith(u8, type_str, "texture")) {
            kind = .texture;
        }

        try out.append(gpa, .{
            .group = group,
            .binding = binding,
            .name = try gpa.dupe(u8, name),
            .kind = kind,
            .detail = try gpa.dupe(u8, detail),
        });
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeWgslBindings(gpa: std.mem.Allocator, bindings: []const WgslBinding) void {
    for (bindings) |b| {
        gpa.free(b.name);
        gpa.free(b.detail);
    }
    gpa.free(bindings);
}
