//! lightmap_fs.zig - the whole point: base(uv) x lightmap(uv2). The base is
//! sampled with the (possibly tiled) primary uv; the lightmap with the second
//! uv set, so precomputed lighting modulates the surface independently of how
//! the base texture repeats.
const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;

const shader_externs = @import("lightmap_fs_externs");

pub const Io = shader_externs.IoT(void);
pub const Out = shader_externs.Out;

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    const uv: Vec2 = .{ io_in.frag_uv[0], io_in.frag_uv[1] };
    const uv2: Vec2 = .{ io_in.frag_uv2[0], io_in.frag_uv2[1] };
    const base: Vec = io_in.base(uv);
    const light: Vec = io_in.lightmap(uv2);
    out.final_color = .{
        base[0] * light[0],
        base[1] * light[1],
        base[2] * light[2],
        1.0,
    };
    return out;
}
