//! Code two apps share, as its own module (`project.addModule`): it gets the
//! imports an app gets.

const z = @import("zimr");
const zm = @import("zm");

pub const background: zm.Color = z.colors.slate_950;

pub fn answer() u32 {
    return 42;
}
