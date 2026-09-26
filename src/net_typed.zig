//! lint:alias net_typed
//! net_typed.zig - a small typed-message layer over a net Session.
//!
//! A message on the wire is [1-byte tag][z.serialize(payload)]: the tag says
//! which kind of message it is, and z.serialize turns the payload struct into
//! bytes and back. Games define their own tag values and payload structs; this
//! just does the framing + dispatch, so you send `Cursor{ .x=.., .y=.. }`
//! instead of hand-packing bytes, and you can carry several message kinds on one
//! connection without abusing the reliable/unreliable channels to tell them
//! apart.
//!
//! Both this and z.serialize are std-only, so the whole thing is testable
//! against the mock transport with no browser.
//!
//! Usage sketch:
//!   const Chat = struct { from: u32 = 0, text: []const u8 = "" };
//!   net.typed.broadcast(&session, reliable_channel, msg_chat, Chat{ ... });
//!   // on receive, for a `message` event `m`:
//!   if (net.typed.tag(m.bytes)) |t| switch (t) {
//!       msg_chat => { const c = try net.typed.decode(Chat, m.bytes, gpa); ... },
//!       else => {},
//!   };
//!
//! Note: payload structs must give every field a default value - z.serialize
//! fills omitted fields from the defaults on decode, which is what lets you add
//! fields later without breaking peers still on the older message format.

const std = @import("std");
const serialize = @import("serialize.zig");

/// Largest typed message this layer will build on the stack. Structured game
/// messages should sit well under this; for anything bigger, call `encode` into
/// your own buffer and hand it to `session.broadcast` directly.
pub const max_typed = 1024;

/// Frame a typed message into `buf` as [tag][serialize(value)]. Returns the
/// slice, or null if it doesn't fit or fails to serialize.
pub fn encode(tag_byte: u8, value: anytype, buf: []u8) ?[]const u8 {
    if (buf.len < 1) {
        return null;
    }
    buf[0] = tag_byte;
    const n: usize = serialize.encode(value, buf[1..]) catch return null;
    return buf[0 .. 1 + n];
}

/// Broadcast a typed message to every peer on `channel`.
pub fn broadcast(
    session: anytype,
    channel: u8,
    tag_byte: u8,
    value: anytype,
) void {
    var buf: [max_typed]u8 = undefined;
    if (encode(tag_byte, value, &buf)) |msg| {
        session.broadcast(channel, msg);
    }
}

/// Send a typed message to a single peer on `channel`.
pub fn sendTo(
    session: anytype,
    peer_id: u32,
    channel: u8,
    tag_byte: u8,
    value: anytype,
) void {
    var buf: [max_typed]u8 = undefined;
    if (encode(tag_byte, value, &buf)) |msg| {
        session.sendTo(peer_id, channel, msg);
    }
}

/// The tag byte of a received message (null if it's empty).
pub fn tag(bytes: []const u8) ?u8 {
    if (bytes.len < 1) {
        return null;
    }
    return bytes[0];
}

/// The payload bytes of a received message - everything after the tag.
pub fn payload(bytes: []const u8) []const u8 {
    if (bytes.len < 1) {
        return bytes[0..0];
    }
    return bytes[1..];
}

/// Decode a received message's payload as `T`. `gpa` is used only if `T` has
/// slice/string fields (scalar-only structs don't allocate); free the result
/// with the matching serialize teardown if so.
pub fn decode(comptime T: type, bytes: []const u8, gpa: std.mem.Allocator) !T {
    return serialize.decode(T, payload(bytes), gpa);
}
