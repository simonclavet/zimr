//! examples/zimrnum_fit/sketch.zig - THE DRAWING: a curve you reshape with the pointer, kept as one target y for each
//! of `sample_count` x values evenly over [-1, 1] (`src/notes/zimrnum_fit_plan.md`, D5). Every sample always has a
//! target, so the network trains on the whole grid every step (D6), and its outputs over the grid ARE the curve drawn.
//!
//! Pure - no engine, no allocator: the page draws it and the job builds its inputs from the same grid (`sampleX`), so
//! the two can never disagree on where a sample sits.

const zm = @import("zm");

const clamp = zm.clamp;
const float = zm.float;
const lerp = zm.lerp;
const roundi = zm.roundi;
const sinTurns = zm.sinTurns;
const Vec2 = zm.Vec2;

/// Samples of the curve - and so rows of the training batch, every step.
pub const sample_count: u32 = 512;
/// How far a target may go from zero: the plot's top and bottom.
pub const largest_target: f32 = 1.5;

/// Where sample `sample_index` sits: evenly over [-1, 1], both ends included.
pub fn sampleX(sample_index: usize) f32 {
    const last_index: f32 = float(sample_count - 1);
    return -1.0 + 2.0 * float(sample_index) / last_index;
}

/// The sample nearest `x`, clamped to the grid.
fn nearestSample(x: f32) usize {
    const last_index: f32 = float(sample_count - 1);
    const position: f32 = clamp((x + 1.0) * 0.5 * last_index, 0.0, last_index);
    return roundi(usize, position);
}

pub const Sketch = struct {
    /// The target y of each sample.
    targets: [sample_count]f32,
    /// Moves on with every change, so that whoever shipped the targets can tell they are no longer what it shipped.
    version: u32,

    /// The curve the page starts with: two periods of a sine.
    pub fn sine() Sketch {
        var sketch: Sketch = .{ .targets = undefined, .version = 0 };
        sketch.drawSine();
        return sketch;
    }

    pub fn drawSine(sketch: *Sketch) void {
        for (&sketch.targets, 0..) |*target, sample_index| {
            target.* = 0.8 * sinTurns(sampleX(sample_index));
        }
        sketch.version +%= 1;
    }

    pub fn clear(sketch: *Sketch) void {
        @memset(&sketch.targets, 0.0);
        sketch.version +%= 1;
    }

    /// PAINT one segment of a stroke, from where the pointer was to where it is, in the plot's units: every sample
    /// between the two x takes the straight line's y there - so a fast stroke, its frames far apart, leaves no gap.
    pub fn paintSegment(sketch: *Sketch, from: Vec2, to: Vec2) void {
        const first_index: usize = nearestSample(@min(from[0], to[0]));
        const last_index: usize = nearestSample(@max(from[0], to[0]));
        const span: f32 = to[0] - from[0];
        const is_vertical: bool = @abs(span) < 1.0e-6;
        for (first_index..last_index + 1) |sample_index| {
            const along: f32 = if (is_vertical) 1.0 else clamp((sampleX(sample_index) - from[0]) / span, 0.0, 1.0);
            const height: f32 = lerp(from[1], to[1], along);
            sketch.targets[sample_index] = clamp(height, -largest_target, largest_target);
        }
        sketch.version +%= 1;
    }
};
