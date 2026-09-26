// src/spv2wgsl_wasm.zig - wasm wrapper exposing the SPIR-V -> WGSL
// transpiler to JavaScript.  Loaded by `webtests/transpiler_corpus.ts`
// to run the transpiler across every SPIR-V file in `.zig-cache/` and
// report per-shader statistics.
//
// Memory model: the wasm exports a memory and grows it on demand.
// JS writes input SPIR-V bytes to wasm memory, then calls `transpile`
// which returns a packed (ptr<<32 | len) pointer-and-length value
// pointing at the WGSL output (also in wasm memory).
//
// Wasi-reactor mode like the demo: `_initialize` runs once at boot
// (sets up the allocator), then `transpile` is callable indefinitely.

const std = @import("std");
const spv2wgsl = @import("spv2wgsl.zig");

// Static buffer for the SPIR-V input (1 MB max - comfortable margin
// over the 52KB ceiling we've seen in the corpus).
// lint:off module-var: wasm-export input buffer, persists across JS calls
var spv_buf: [1024 * 1024]u8 align(@alignOf(u32)) = undefined;

// Arena owns the WGSL output between calls.  Reset on each transpile.
// lint:off module-var: wasm-export output arena, persists across JS calls
var arena_storage: std.heap.ArenaAllocator = undefined;
// lint:off module-var: wasm-export one-time-init guard
var initialized: bool = false;

pub fn main() void {
    // wasi-reactor init.  Allocator backing for the arena.
    arena_storage = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    initialized = true;
}

/// Return a pointer to the input buffer.  JS writes SPIR-V bytes
/// here, then calls `transpile(len)`.
export fn input_buffer_ptr() u32 {
    return @intFromPtr(&spv_buf[0]);
}

/// Return the capacity of the input buffer (so JS can refuse oversized
/// inputs without trying).
export fn input_buffer_capacity() u32 {
    return spv_buf.len;
}

/// Transpile the first `len` bytes of `spv_buf`.  Returns a packed
/// pointer (low 32 bits) + length (high 32 bits) for the WGSL output.
/// Returns 0 on any error (NotSpirv, MalformedSpirv, OOM).  Use
/// `last_error_code()` for the specific reason.
// lint:off module-var: wasm-export last-error code, read via last_error_code()
var last_error: u32 = 0;

export fn transpile(len: u32) u64 {
    if (!initialized) {
        last_error = 1; // not initialized
        return 0;
    }
    if (len % 4 != 0) {
        last_error = 2; // misaligned
        return 0;
    }
    if (len > spv_buf.len) {
        last_error = 3; // too large
        return 0;
    }

    // Reset the arena - each call gets a fresh slate.  Previous call's
    // WGSL is freed here.
    _ = arena_storage.reset(.retain_capacity);

    const words_ptr: [*]const u32 = @ptrCast(&spv_buf[0]);
    const words: []const u32 = words_ptr[0 .. len / 4];

    const wgsl: []const u8 = spv2wgsl.convertSpirvToWgsl(arena_storage.allocator(), words) catch |err| {
        last_error = switch (err) {
            error.NotSpirv => 10,
            error.MalformedSpirv => 11,
            error.OutOfMemory => 13,
            // The recursive walker widened convertSpirvToWgsl's error
            // set to anyerror; any other translation failure maps to a
            // generic code so the switch stays exhaustive.
            else => 12,
        };
        return 0;
    };

    last_error = 0;
    const ptr: u64 = @intFromPtr(wgsl.ptr);
    const length: u64 = wgsl.len;
    return ptr | (length << 32);
}

export fn last_error_code() u32 {
    return last_error;
}
