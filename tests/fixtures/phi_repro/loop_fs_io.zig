const zm = @import("zm");
pub const Inputs = struct {
    frag_tex_coord: zm.Vec2,
};
pub const Outputs = struct {
    out_color: zm.Vec,
};
pub const Ubo = extern struct {
    threshold: f32,
    _pad0: f32 = 0,
    _pad1: f32 = 0,
    _pad2: f32 = 0,
};
