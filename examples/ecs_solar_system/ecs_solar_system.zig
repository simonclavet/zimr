//! ecs_solar_system - port of the GL `ecs_solar_system` onto WebGPU.
//! Same ECS exercise, drawn with the wgpu draw API (drawCircle).
// A 2D solar system that exercises most of the ecs.zig API in one
// place.  What's wired up:
//   - Multiple component types: Position, Orbit, Velocity, Visual,
//     Lifetime, ShipTarget.  Different combinations form distinct
//     archetypes; the iterators below filter by which ones each
//     pass needs.
//   - Node tree (the parent/child API).  Sun is the root.  Planets
//     are children of the sun; moons are children of planets.
//     Each frame we walk the tree pre-order so a parent's world
//     position is set before its children read it for orbit math.
//   - Tag classification.  StarKind / PlanetKind / MoonKind /
//     ShipKind are zero-sized marker types.  We `Tag.init(K)` to
//     build the runtime classifier and use it for filtering.
//   - CmdBuf deferred mutation.  Ships spawn from reserved
//     entities popped off the buffer's reserve.  Expired ships
//     queue themselves for destruction during a forEach pass.
//     Both happen safely while the iterator is in flight; the
//     replay happens at end-of-frame via `Node.Exec.immediate`.
//   - Mixed-shape forEach.  Some passes take `(*Pos, *const
//     Velocity)`, some take `(Entity, *Lifetime)` so they can
//     queue self-destruction, some take `(*Orbit, *Pos)` for the
//     orbital integrator.
// Visually: a sun at center, four planets orbiting at staggered
// radii and speeds, two moons on alternating planets, and bursts
// of ships shooting out from the sun toward random target planets
// every half second.  Ships fade after five seconds of flight.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Color = zm.Color;
const float = zm.float;
const pi = zm.pi;
const ecs = z.ecs;

// ============================================================================
// Components
// ============================================================================

/// World-space position.  Computed every frame from each body's
/// Orbit and its parent's Position; ships integrate it directly
/// from Velocity.
const Pos = Vec2;

/// 2D orbit parameters around the entity's tree-parent.  Sun has
/// none (it's the root and stays put); every other body has one.
const Orbit = struct {
    /// Distance from parent's center, in pixels.
    radius: f32,
    /// Angular velocity, radians per second.
    omega: f32,
    /// Current angle, advanced each frame.
    theta: f32,
};

/// Linear velocity in pixels/sec.  Ships only.
const Velocity = Vec2;

/// What it looks like.  Color + on-screen radius; renderer turns
/// these straight into `drawCircle` calls.
const Visual = struct { color: Color, radius: f32 };

/// Time before this entity self-destructs.  Ships only.
const Lifetime = struct { remaining: f32 };

/// Typed entity reference.  Demonstrates that `Entity` can be a
/// component field - caller looks up the target via
/// `target.get(es, Pos)` etc., generation tag catches dangling.
const ShipTarget = struct { planet: ecs.Entity };

// ============================================================================
// Tag marker types (zero-sized; only their identity matters)
// ============================================================================

const StarKind = struct {};
const PlanetKind = struct {};
const MoonKind = struct {};
const ShipKind = struct {};

// ============================================================================
// State
// ============================================================================

const State = struct {
    /// Stashed allocator for ecs.Node.Exec.immediate (allocates arch buffers).
    gpa: Allocator,
    es: ecs.Registry,
    tree: ecs.Node.Tree,
    cb: ecs.CmdBuf,
    rng: std.Random.DefaultPrng,
    spawn_timer: f32 = 0.0,
};

fn deinit(gpa: Allocator, s: *State) void {
    s.cb.deinit(gpa, &s.es);
    s.es.deinit(gpa);
}

// ============================================================================
// Init: build the static parts of the world
// ============================================================================

fn initState(gpa: Allocator, _: *z.Frame, s: *State) !void {
    var es: ecs.Registry = try .init(.{
        .gpa = gpa,
        .cap = .{
            .entities = 1024,
            .arches = 32,
            .chunks = 64,
            .chunk = 4096,
        },
    });
    errdefer es.deinit(gpa);

    var tree: ecs.Node.Tree = .empty;

    // The sun: root of the tree.  No Orbit; its Position is just
    // the center of the canvas.
    const sun: ecs.Entity = try ecs.Entity.reserveImmediateOrErr(&es);
    _ = try sun.changeArchImmediateOrErr(&es, gpa, struct {
        pos: Pos,
        vis: Visual,
        tag: ecs.Tag,
        node: ecs.Node,
    }, .{
        .add = .{
            .pos = .{ 400, 300 },
            .vis = .{ .color = z.colors.amber_400, .radius = 28 },
            .tag = .init(StarKind),
            .node = .{},
        },
    });
    const sun_node: *ecs.Node = sun.get(&es, ecs.Node).?;
    if (sun_node.uninitialized(&es, &tree)) {
        sun_node.init(&es, &tree);
    }

    // Four planets at different radii and speeds, spaced evenly
    // around the sun's starting circle.
    const planets = [_]struct {
        r: f32,
        omega: f32,
        color: Color,
        radius: f32,
    }{
        .{ .r = 70, .omega = 1.4, .color = z.colors.red_400, .radius = 6 },
        .{ .r = 120, .omega = 0.9, .color = z.colors.green_400, .radius = 9 },
        .{ .r = 190, .omega = 0.55, .color = z.colors.sky_400, .radius = 13 },
        .{ .r = 250, .omega = 0.32, .color = z.colors.pink_500, .radius = 11 },
    };
    for (planets, 0..) |p, i| {
        const planet: ecs.Entity = try ecs.Entity.reserveImmediateOrErr(&es);
        const theta: f32 = float(i) * pi * 0.5;
        _ = try planet.changeArchImmediateOrErr(&es, gpa, struct {
            pos: Pos,
            orbit: Orbit,
            vis: Visual,
            tag: ecs.Tag,
            node: ecs.Node,
        }, .{
            .add = .{
                .pos = .{ 0, 0 }, // overwritten on first frame
                .orbit = .{ .radius = p.r, .omega = p.omega, .theta = theta },
                .vis = .{ .color = p.color, .radius = p.radius },
                .tag = .init(PlanetKind),
                .node = .{},
            },
        });
        const pl_node: *ecs.Node = planet.get(&es, ecs.Node).?;
        if (pl_node.uninitialized(&es, &tree)) {
            pl_node.init(&es, &tree);
        }
        pl_node.setParentImmediate(&es, &tree, sun_node);

        // Every other planet gets a moon.
        if (i % 2 == 0) {
            const moon: ecs.Entity = try ecs.Entity.reserveImmediateOrErr(&es);
            _ = try moon.changeArchImmediateOrErr(&es, gpa, struct {
                pos: Pos,
                orbit: Orbit,
                vis: Visual,
                tag: ecs.Tag,
                node: ecs.Node,
            }, .{
                .add = .{
                    .pos = .{ 0, 0 },
                    .orbit = .{ .radius = p.radius * 2.5 + 4, .omega = 4.5, .theta = 0 },
                    .vis = .{ .color = z.colors.slate_300, .radius = 2.5 },
                    .tag = .init(MoonKind),
                    .node = .{},
                },
            });
            const moon_node: *ecs.Node = moon.get(&es, ecs.Node).?;
            if (moon_node.uninitialized(&es, &tree)) {
                moon_node.init(&es, &tree);
            }
            moon_node.setParentImmediate(&es, &tree, pl_node);
        }
    }

    var cb: ecs.CmdBuf = try .init(.{
        .name = "solar-cb",
        .gpa = gpa,
        .es = &es,
        .cap = .{ .cmds = 1024 },
    });
    errdefer cb.deinit(gpa, &es);

    s.* = .{
        .gpa = gpa,
        .es = es,
        .tree = tree,
        .cb = cb,
        .rng = .init(0xC0FFEE),
    };
}

// ============================================================================
// Per-frame update
// ============================================================================

/// Advance Orbit angles by `dt`.  Visits every entity with an
/// Orbit component - planets and moons in this scene.
fn advanceOrbit(ctx: struct { dt: f32 }, o: *Orbit) void {
    o.theta += o.omega * ctx.dt;
}

/// Set this entity's world Pos from its parent's Pos plus its
/// Orbit offset.  The sun (no Orbit) keeps its initial value;
/// ships (no Node) are skipped because we drive this from the
/// tree iterator, not forEach.
fn recomputePos(es: *ecs.Registry, view: ecs.Node.View) void {
    const orbit: *const Orbit = view.entity.get(es, Orbit) orelse return;
    const pos: *Pos = view.entity.get(es, Pos) orelse return;

    const parent_view: ecs.Node.View = view.getParent(es) orelse return;
    const parent_pos: *const Pos = parent_view.entity.get(es, Pos) orelse return;

    pos[0] = parent_pos[0] + orbit.radius * @cos(orbit.theta);
    pos[1] = parent_pos[1] + orbit.radius * @sin(orbit.theta);
}

/// Move ships, count down their lifetimes.  Filter shape - the
/// View's required components are Velocity AND Lifetime, so we
/// only visit ships.
fn integrateShip(
    ctx: struct { dt: f32 },
    p: *Pos,
    v: *const Velocity,
    l: *Lifetime,
) void {
    p[0] += v[0] * ctx.dt;
    p[1] += v[1] * ctx.dt;
    l.remaining -= ctx.dt;
}

/// Every ~0.5s, snapshot the current planet positions, pick one
/// at random, and queue a ship aimed at it from the sun.  This
/// touches a few corners of the API:
///   - `es.iterator(View)` - manual iteration with a custom view
///     for filtering by Tag value.
///   - `tag.eql(.init(K))` - comparing tag identity by marker type.
///   - `Entity.reserve(cb)` - pop a pre-reserved handle for the
///     new ship; spends one slot from `cb.reserved`.
///   - `entity.add(cb, T, val)` - buffered component add (six in
///     a row, all coalesce into one batch under the same handle).
fn spawnShipsTick(
    es: *ecs.Registry,
    cb: *ecs.CmdBuf,
    rng: *std.Random.DefaultPrng,
    dt: f32,
    timer: *f32,
) void {
    timer.* += dt;
    if (timer.* < 0.5) {
        return;
    }
    timer.* = 0;

    // Snapshot planet handles + their current world positions.
    // Manual iterator (rather than forEach) so we can use the
    // result OUTSIDE the loop body - forEach's update fn doesn't
    // get to outlive the iteration.
    var planet_count: usize = 0;
    var planets_buf: [16]ecs.Entity = undefined;
    var planet_pos_buf: [16]Pos = undefined;
    {
        var iter = es.iterator(struct {
            e: ecs.Entity,
            p: *const Pos,
            t: *const ecs.Tag,
        });
        while (iter.next(es)) |view| {
            if (view.t.eql(ecs.Tag.init(PlanetKind))) {
                if (planet_count < planets_buf.len) {
                    planets_buf[planet_count] = view.e;
                    planet_pos_buf[planet_count] = view.p.*;
                    planet_count += 1;
                }
            }
        }
    }
    if (planet_count == 0) {
        return;
    }

    // Find the sun - one shot through the iterator.
    var sun_pos: ?Pos = null;
    {
        var iter = es.iterator(struct {
            p: *const Pos,
            t: *const ecs.Tag,
        });
        while (iter.next(es)) |view| {
            if (view.t.eql(ecs.Tag.init(StarKind))) {
                sun_pos = view.p.*;
                break;
            }
        }
    }
    const sp: Pos = sun_pos orelse return;

    const idx: u32 = rng.random().uintLessThan(u32, planet_count);
    const target: ecs.Entity = planets_buf[idx];
    const tp: Pos = planet_pos_buf[idx];

    const dx: f32 = tp[0] - sp[0];
    const dy: f32 = tp[1] - sp[1];
    const len: f32 = @sqrt(dx * dx + dy * dy);
    if (len < 0.01) {
        return;
    }
    const speed: f32 = 90.0;
    const vx: f32 = dx / len * speed;
    const vy: f32 = dy / len * speed;

    // Reserve a fresh handle from the command buffer's pool, then
    // queue the component-add commands.  Six adds for one entity
    // - the encoder coalesces them into a single batch keyed off
    // the bound entity.
    const ship: ecs.Entity = ecs.Entity.reserve(cb);
    _ = ship.add(cb, Pos, .{ sp[0], sp[1] });
    _ = ship.add(cb, Velocity, .{ vx, vy });
    _ = ship.add(cb, Visual, .{ .color = z.colors.amber_200, .radius = 1.5 });
    _ = ship.add(cb, Lifetime, .{ .remaining = 5.0 });
    _ = ship.add(cb, ecs.Tag, ecs.Tag.init(ShipKind));
    _ = ship.add(cb, ShipTarget, .{ .planet = target });
}

/// Self-destruct expired ships through the command buffer.  The
/// `Entity` parameter in the View shape is what makes this
/// possible - `forEach` hands us the handle, we pass it to
/// `destroy(cb)` for replay at flush time.
fn destroyExpired(
    cb: *ecs.CmdBuf,
    e: ecs.Entity,
    l: *const Lifetime,
) void {
    if (l.remaining <= 0) {
        e.destroy(cb);
    }
}

/// Render circles at every Visual.  Stars + planets + moons +
/// ships all match (everyone has Pos + Visual).
fn renderEntity(
    ctx: struct { gl: *z.WgpuGl },
    p: *const Pos,
    v: *const Visual,
) void {
    ctx.gl.circle(p.*, v.radius, .{ .color = v.color, .segments = 16 });
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, z.colors.slate_950);

    const dt: f32 = f.time.delta_time;

    // 1. Advance every Orbit's angle.  Visits planets and moons
    //    (everything with an Orbit); skips the sun + ships.
    s.es.forEach(advanceOrbit, .{ .dt = dt });

    // 2. Walk the Node tree pre-order so each body's world Pos is
    //    derived from its parent's Pos before its children read it.
    //    `forEach` doesn't give us parent context - the tree
    //    iterator does.
    var roots: @TypeOf(s.tree.childIterator(.{})) = s.tree.childIterator(.{});
    while (roots.next(&s.es)) |root| {
        var pre: @TypeOf(root.node.preOrderIterator(&s.es, .{ .include_root = true })) = root.node.preOrderIterator(
            &s.es,
            .{ .include_root = true },
        );
        while (pre.next(&s.es)) |view| {
            recomputePos(&s.es, view);
        }
    }

    // 3. Integrate ship motion + decay lifetime.  The view filters
    //    to entities with Velocity AND Lifetime - ships only.
    s.es.forEach(integrateShip, .{ .dt = dt });

    // 4. Spawn new ships every ~0.5s, aimed at a random planet.
    spawnShipsTick(&s.es, &s.cb, &s.rng, dt, &s.spawn_timer);

    // 5. Queue expired ships for destruction.  `destroy` is
    //    buffered, safe to call mid-iteration.
    s.es.forEach(destroyExpired, &s.cb);

    // 6. Flush.  Node.Exec applies arch changes AND the tree
    //    bookkeeping (auto-init of new node components, cleanup
    //    of removed ones).  Since ships have no node, this just
    //    runs the queued spawn/destroy ops for them.
    ecs.Node.Exec.immediate(&s.es, s.gpa, &s.cb, &s.tree);

    // 7. Render every Visual-carrying entity in chunk order.
    s.es.forEach(renderEntity, .{ .gl = f.gl });
}

// ============================================================================
// Systems
// ============================================================================

// ============================================================================
// Ship spawning
// ============================================================================

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - ECS solar system",
            .width = 800,
            .height = 600,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
