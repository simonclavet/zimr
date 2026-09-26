"""geno_fit.py - fit collision geoms to Geno's skinned mesh, bone by bone.

A PROTOTYPE, kept because it is the measurement that settled the method (plan, Phase R4): each mesh
vertex belongs to the bone that weights it most (fingers fold into their hand, Neck1 into Neck), and
each bone gets a geom fitted to ITS vertices along their principal axis - a capsule for the round
parts, an oriented box for the flat ones. That covered 98.6% of vertices within 1 cm at 108 litres,
against 254 litres for capsules drawn along the bones themselves.

The geoms are written in WORLD BIND coordinates - where they sit on the mesh - not in bone frames. A
page turns them into bone-local placements at startup, with the same forward kinematics it animates
with, so the two cannot disagree about joint frames. The Zig generator that replaces this script
should keep that rule.

    python3 tools/geno_fit.py geno.bin geno_bind.bvh out.zig [capture.bvh ...]

WITH CAPTURES, THE FIT IS CHECKED AGAINST MOTION. A shape fitted to cover a bone's vertices is fatter
than the limb wherever the limb narrows, and a shape that bulges out of the mesh is a shape that goes
through the floor when the character lies on that side. So the mesh is skinned through every capture
given (linear blend skinning with its own bone weights; exact to the micrometre at the bind pose),
and each shape is shrunk by exactly how far it ever reaches below the posed mesh's lowest point -
the worst over both sides of a pair, so the pair stays symmetric.
"""
import sys, struct, numpy as np

# Only the feet are boxes (Simon: everything else a pill) - the foot and its toe together, since the
# sole should be flat from heel to toe tip. Everything else is a capsule along its vertices' own axis.
FEET = {'LeftFoot','RightFoot','LeftToeBase','RightToeBase'}

def mirror_name(name):
    # Left and right of the same bone, or None for a bone on the centre line.
    if name.startswith('Left'):
        return 'Right' + name[4:]
    if name.startswith('Right'):
        return 'Left' + name[5:]
    return None

# The body's centre plane is x = 0 in Geno's bind pose (the hips sit at x = 0.000, and every
# left/right joint pair mirrors across it), so mirroring is flipping x.
FLIP = np.array([-1.0, 1.0, 1.0])

# The torso's pills run ACROSS the body. Measured against the other choices (plan, Phase R4): one pill
# per segment tops out near 93.5% of the torso's vertices whichever way it runs, and across does it in
# 66 litres against 72 upright; it is also the familiar stacked look, and lets neighbouring segments
# roll against each other as the spine bends. Forced rather than left to the principal axis, so the
# stack is consistent - the hips' principal axis ran otherwise, at lower coverage.
TORSO = {'Hips','Spine','Spine1','Spine2','Spine3'}

# LIMBS REACH THEIR JOINTS. A limb capsule keeps its flesh's own principal axis - the bones sit
# off-centre in the flesh (the shin bone is at the FRONT of the shin), so a capsule on the bone line
# pokes out wherever the flesh is thin - but its end centres are where the two joints project onto
# that axis, so it spans joint to joint and meets its neighbours there. The neck is the exception: too
# short and round for a stable principal axis, it runs along its bone, neck joint to head joint.
# (Left side only; the right is the mirror.)
CHAIN = {'LeftArm': 'LeftForeArm', 'LeftForeArm': 'LeftHand', 'LeftUpLeg': 'LeftLeg', 'LeftLeg': 'LeftFoot',
         'Neck': 'Head'}
# The hand has no joint at its far end the captures move (the fingers ride the hand), so its capsule
# starts AT the wrist and runs toward the middle of its own vertices.
WRIST = {'LeftHand'}

# ATHLETIC, ON PURPOSE (Simon: "smaller belly, a bit bigger torso", fit may be poorer). Applied LAST,
# after the motion fit, so the fit cannot undo it. (depth, width) scale per torso pill; the BACK stays
# where it is, so a smaller belly pulls its front in and a bigger chest pushes its front out - and
# lying on the back meets the floor exactly where it did.
# NO SHAPE ON THE SHOULDERS (Simon: their round pills made a hump over the upper back). The chest
# pill and the upper arm meet directly instead - 2.6 cm of overlap without the shoulder in between.
NO_SHAPE = {'LeftShoulder', 'RightShoulder'}
# A SLIMMER NECK (Simon: "reduce neck"). Its radius is the neck column's own - the MEDIAN flesh radius
# over the middle of the neck, 5.8 cm, not the 90th percentile, which catches the trapezius skirt at
# its base - and then three quarters of that.
NECK_SLIM = 0.75

# Which shapes must keep meeting, parent first - and the order the motion search visits them in.
NEIGHBOURS = [('Hips', 'LeftUpLeg'), ('LeftUpLeg', 'LeftLeg'), ('Spine3', 'LeftArm'),
              ('LeftArm', 'LeftForeArm'), ('LeftForeArm', 'LeftHand'), ('Spine3', 'Neck'), ('Neck', 'Head')]
ORDER = ['Hips', 'Spine', 'Spine1', 'Spine2', 'Spine3', 'Neck', 'Head', 'LeftArm', 'LeftForeArm',
         'LeftHand', 'LeftUpLeg', 'LeftLeg', 'LeftFoot', 'LeftToeBase']

def segment_gap(p1, q1, p2, q2):
    # The closest distance between two segments (Ericson, Real-Time Collision Detection 5.1.9).
    d1 = q1 - p1; d2 = q2 - p2; r = p1 - p2
    a = d1 @ d1; e = d2 @ d2; f = d2 @ r
    if a <= 1e-12 and e <= 1e-12:
        return np.linalg.norm(r)
    if a <= 1e-12:
        s = 0.0; t = np.clip(f / e, 0.0, 1.0)
    else:
        c = d1 @ r
        if e <= 1e-12:
            t = 0.0; s = np.clip(-c / a, 0.0, 1.0)
        else:
            b = d1 @ d2; denom = a * e - b * b
            s = np.clip((b * f - c * e) / denom, 0.0, 1.0) if denom > 1e-12 else 0.0
            t = (b * s + f) / e
            if t < 0.0:
                t = 0.0; s = np.clip(-c / a, 0.0, 1.0)
            elif t > 1.0:
                t = 1.0; s = np.clip((b - c) / a, 0.0, 1.0)
    return np.linalg.norm((p1 + d1 * s) - (p2 + d2 * t))

ATHLETIC = {'Spine': (0.85, 0.90), 'Spine1': (0.88, 0.92), 'Spine2': (1.08, 1.08), 'Spine3': (1.08, 1.08)}

def owner(name):
    if 'Hand' in name and name not in ('LeftHand','RightHand'):
        return 'LeftHand' if name.startswith('Left') else 'RightHand'
    return {'Neck1':'Neck','HeadEnd':'Head'}.get(name, name)

def quat_from_matrix(m):
    t = m[0,0]+m[1,1]+m[2,2]
    if t > 0:
        s = 0.5/np.sqrt(t+1.0); return np.array([(m[2,1]-m[1,2])*s,(m[0,2]-m[2,0])*s,(m[1,0]-m[0,1])*s,0.25/s])
    i = int(np.argmax([m[0,0],m[1,1],m[2,2]])); j,k = (i+1)%3,(i+2)%3
    s = 2.0*np.sqrt(max(1.0+m[i,i]-m[j,j]-m[k,k],1e-12)); q=np.zeros(4)
    q[i]=0.25*s; q[j]=(m[j,i]+m[i,j])/s; q[k]=(m[k,i]+m[i,k])/s; q[3]=(m[k,j]-m[j,k])/s
    return q

def parse_bvh(path):
    text = open(path, 'r', errors='replace').read().replace('\r', '')
    head, motion = text.split('MOTION\n', 1)
    names = []; parents = []; offsets = []; channels = []; stack = []; pending = None
    for line in head.splitlines():
        t = line.strip()
        if t.startswith(('ROOT', 'JOINT')):
            pending = ('j', t.split()[1])
        elif t.startswith('End'):
            pending = ('e', None)
        elif t == '{':
            if pending and pending[0] == 'j':
                names.append(pending[1]); parents.append(stack[-1] if stack else -1)
                offsets.append(None); channels.append([]); stack.append(len(names) - 1)
            else:
                stack.append(-2)
            pending = None
        elif t == '}':
            stack.pop()
        elif t.startswith('OFFSET') and stack and stack[-1] >= 0 and offsets[stack[-1]] is None:
            offsets[stack[-1]] = np.array([float(x) for x in t.split()[1:]])
        elif t.startswith('CHANNELS') and stack and stack[-1] >= 0:
            channels[stack[-1]] = t.split()[2:]
    rows = [l for l in motion.split('\n') if l.strip() and not l.startswith(('Frames', 'Frame Time'))]
    return names, parents, offsets, channels, np.array([[float(x) for x in r.split()] for r in rows])

def axis_turn(axis, degrees):
    r = np.radians(degrees); c, s = np.cos(r), np.sin(r)
    return {'X': np.array([[1,0,0],[0,c,-s],[0,s,c]]), 'Y': np.array([[c,0,s],[0,1,0],[-s,0,c]]),
            'Z': np.array([[c,-s,0],[s,c,0],[0,0,1]])}[axis]

def forward(skeleton, values):
    """Every joint's world place (metres) and turn, for one frame. Rotations apply in the order the
    file lists its channels - files disagree, so the order is read, never assumed."""
    names, parents, offsets, channels = skeleton[:4]
    n = len(names); P = np.zeros((n, 3)); R = np.zeros((n, 3, 3)); k = 0
    for i in range(n):
        t = offsets[i].copy(); turn = np.eye(3)
        for ch in channels[i]:
            v = values[k]; k += 1
            if ch.endswith('position'):
                t['XYZ'.index(ch[0])] = v
            else:
                turn = turn @ axis_turn(ch[0], v)
        if parents[i] < 0:
            P[i] = t; R[i] = turn
        else:
            P[i] = P[parents[i]] + R[parents[i]] @ t; R[i] = R[parents[i]] @ turn
    return P * 0.01, R

def box_matrix(q):
    x, y, z, w = q
    return np.array([[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)], [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],
                     [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]])

def lowest(shape, carry):
    """The lowest world y a shape reaches once carried by `carry` (bind world -> this frame's world)."""
    if shape[0] == 'capsule':
        return min(carry(shape[1])[1], carry(shape[2])[1]) - shape[3]
    M = box_matrix(shape[2]); c, h = shape[1], shape[3]
    return min(carry(c + M @ (np.array([sx, sy, sz]) * h))[1] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1))

def shrunk(shape, by):
    """The same shape, `by` metres smaller all round - a box keeps its SOLE where it was, since the sole
    is the mesh's own lowest point and is what stands on the floor."""
    if by <= 0:
        return shape
    if shape[0] == 'capsule':
        return ('capsule', shape[1], shape[2], max(shape[3] - by, 0.01))
    c, q, h = shape[1], shape[2], shape[3]
    h2 = np.maximum(h - by, 0.005)
    up = box_matrix(q)[:, 1]
    # The sole sat at c - up * h[1]; keeping it there with the new half height puts the centre at
    # (c - up * h[1]) + up * h2[1].
    return ('box', c - up * h[1] + up * h2[1], q, h2)

def fit(bone, P, joints, torso_pts):
    c = P.mean(0)
    if bone in FEET:
        # A foot's box is aligned with the FLOOR: in the bind pose the sole is horizontal, and a
        # principal axis tilted by a degree or two would put back the very tilt this is removing.
        flat = P[:, [0, 2]] - c[[0, 2]]
        _, _, vt = np.linalg.svd(flat, full_matrices=False)
        along = np.array([vt[0,0], 0.0, vt[0,1]]); up = np.array([0.0,1.0,0.0]); side = np.cross(along, up)
        axes = np.stack([along, up, side])
        Q = (P - c) @ axes.T
        lo = np.percentile(Q, 3, 0); hi = np.percentile(Q, 97, 0)
        lo[1] = Q[:,1].min()    # the sole is the mesh's own lowest point, not a percentile of it
        centre = c + axes.T @ ((lo + hi) / 2)
        return ('box', centre, quat_from_matrix(axes.T), (hi - lo) / 2)
    if bone == 'Neck':
        j0 = joints[bone]; j1 = joints[CHAIN[bone]]
        L = np.linalg.norm(j1 - j0); u = (j1 - j0) / L
        t = (P - j0) @ u
        radial = np.linalg.norm((P - j0) - np.outer(t, u), axis=1)
        column = (t >= 0.3 * L) & (t <= 0.7 * L)
        return ('capsule', j0.copy(), j1.copy(), np.median(radial[column]) * NECK_SLIM)
    if bone in CHAIN:
        _, _, axes = np.linalg.svd(P - c, full_matrices=False)
        u = axes[0]
        t = (P - c) @ u
        r = np.percentile(np.linalg.norm((P - c) - np.outer(t, u), axis=1), 90)
        # Ends where the joints fall on the flesh axis, whichever way the axis happens to point.
        ta = (joints[bone] - c) @ u; tb = (joints[CHAIN[bone]] - c) @ u
        return ('capsule', c + ta * u, c + tb * u, r)
    if bone in WRIST:
        j0 = joints[bone]; u = (c - j0) / np.linalg.norm(c - j0)
        t = (P - j0) @ u
        radial = np.linalg.norm((P - j0) - np.outer(t, u), axis=1)
        r = np.percentile(radial[t >= 0.0], 90)
        return ('capsule', j0.copy(), j0 + u * max(np.percentile(t, 98) - r, 0.0), r)
    if bone in TORSO:
        # FROM THE CROSS-SECTION, not from the bone's own vertices. Geno's skin weights give the sides
        # of the waist to the belly bones and leave the lower chest a thin band at the back, so pills
        # fitted per bone made a pot belly with love handles over a hollow chest. Instead, at this pill's
        # height, the whole torso's own front and back (along the middle) set its depth, and the torso's
        # own width sets its reach: a pill that fills the body's section there, and no more.
        y = c[1]
        band = torso_pts[np.abs(torso_pts[:, 1] - y) < 0.02]
        middle = band[np.abs(band[:, 0]) < 0.06]
        front, back = middle[:, 2].max(), middle[:, 2].min()
        r = (front - back) / 2.0
        reach = max(np.abs(band[:, 0]).max() - r, 0.0)
        centre = np.array([0.0, y, (front + back) / 2.0])
        return ('capsule', centre - [reach, 0, 0], centre + [reach, 0, 0], r)
    else:
        _, _, axes = np.linalg.svd(P - c, full_matrices=False)
        u = axes[0]
    t = (P - c) @ u
    radial = np.linalg.norm((P - c) - np.outer(t, u), axis=1)
    r = np.percentile(radial, 90)
    lo_t, hi_t = np.percentile(t, 2) + r * 0.5, np.percentile(t, 98) - r * 0.5
    if hi_t < lo_t:
        lo_t = hi_t = (lo_t + hi_t) / 2
    return ('capsule', c + lo_t * u, c + hi_t * u, r)

def mirrored(shape):
    # The same shape reflected across the centre plane. A capsule's ends flip their x; a box's centre
    # does, and its orientation R becomes M R M with M = diag(-1, 1, 1) - which, for a quaternion
    # (x, y, z, w), is (x, -y, -z, w).
    if shape[0] == 'capsule':
        return ('capsule', shape[1] * FLIP, shape[2] * FLIP, shape[3])
    q = shape[2]
    return ('box', shape[1] * FLIP, np.array([q[0], -q[1], -q[2], q[3]]), shape[3])

def main(src, bind_path, dst, captures):
    b = open(src,'rb').read()
    nv, nt, nj = struct.unpack_from('III', b, 0); off = 12
    pos = np.frombuffer(b, np.float32, nv*3, off).reshape(nv,3); off += nv*12 + nv*8 + nv*12
    inds = np.frombuffer(b, np.uint8, nv*4, off).reshape(nv,4); off += nv*4
    weis = np.frombuffer(b, np.float32, nv*4, off).reshape(nv,4); off += nv*16 + nt*3*2
    names = []
    for _ in range(nj):
        n, _p = struct.unpack_from('32si', b, off); off += 36
        names.append(n.split(b'\0')[0].decode())
    pos = pos.astype(np.float64); inds = inds.astype(int); weis = weis.astype(np.float64)
    bind = parse_bvh(bind_path); Pb, _ = forward(bind, bind[4][0])
    joints = {n: Pb[i] for i, n in enumerate(bind[0])}
    strongest = inds[np.arange(nv), weis.argmax(1)]
    in_torso = np.array([owner(names[j]) in TORSO for j in strongest])
    torso_pts = np.concatenate([pos[in_torso], pos[in_torso] * FLIP])
    bodies = {}
    for v, j in enumerate(strongest):
        bodies.setdefault(owner(names[j]), []).append(v)
    out = []
    done = set()
    for bone in sorted(bodies):
        if bone in done or len(bodies[bone]) < 20 or bone in NO_SHAPE:
            continue
        twin = mirror_name(bone)
        if twin is not None and twin not in bodies:
            twin = None
        # SYMMETRY BY CONSTRUCTION. A left/right pair is fitted ONCE, on the left bone's vertices
        # together with the right bone's mirrored onto the left - twice the data, one shape - and the
        # right side gets that shape mirrored back. A centre bone is fitted on its vertices plus their
        # own mirror image, so it comes out symmetric about the middle whatever the mesh's small
        # asymmetries. Both sides of the body therefore match exactly, not merely nearly.
        if twin is not None:
            left = bone if bone.startswith('Left') else twin
            right = twin if left == bone else bone
            P = np.concatenate([pos[bodies[left]], pos[bodies[right]] * FLIP]).astype(np.float64)
            shape = fit(left, P, joints, torso_pts)
            out.append((left,) + shape)
            out.append((right,) + mirrored(shape))
            done.update((left, right))
        else:
            P = pos[bodies[bone]].astype(np.float64)
            P = np.concatenate([P, P * FLIP])
            out.append((bone,) + fit(bone, P, joints, torso_pts))
            done.add(bone)
    out.sort(key=lambda g: g[0])
    if captures:
        out = fit_to_motion(out, pos, inds, weis, names, bind_path, captures)
    f3 = lambda v: '.{ %.5f, %.5f, %.5f }' % tuple(v)
    lines = ['//! GENERATED by tools/geno_fit.py from Geno\'s skinned mesh - do not edit by hand.',
             '//! Geoms in WORLD BIND coordinates (metres, y-up): the page places them on bones itself.', '',
             'pub const Shape = enum { capsule, box };', '',
             'pub const Geom = struct {',
             '    bone: []const u8,', '    shape: Shape,',
             '    /// Capsule: its two end centres and radius. Box: its centre, orientation and half extents.',
             '    a: [3]f32 = .{ 0, 0, 0 },', '    b: [3]f32 = .{ 0, 0, 0 },', '    radius: f32 = 0,',
             '    rotation: [4]f32 = .{ 0, 0, 0, 1 },', '    half: [3]f32 = .{ 0, 0, 0 },', '};', '',
             'pub const geoms = [_]Geom{']
    # One field a line, so the table stays within the engine's line length and reads as a table.
    for g in out:
        lines.append('    .{')
        lines.append('        .bone = "%s",' % g[0])
        if g[1] == 'capsule':
            lines += ['        .shape = .capsule,', '        .a = %s,' % f3(g[2]), '        .b = %s,' % f3(g[3]),
                      '        .radius = %.5f,' % g[4]]
        else:
            lines += ['        .shape = .box,', '        .a = %s,' % f3(g[2]),
                      '        .rotation = .{ %.5f, %.5f, %.5f, %.5f },' % tuple(g[3]), '        .half = %s,' % f3(g[4])]
        lines.append('    },')
    lines.append('};')
    open(dst, 'w').write('\n'.join(lines) + '\n')
    print('geno_fit: %d geoms -> %s' % (len(out), dst))

def fit_to_motion(out, pos, inds, weis, names, bind_path, captures):
    """Make every shape stay inside the posed mesh, losing as little of it as possible.

    A capsule cannot taper, but a limb does: sized for the top of the thigh it is too fat at the knee,
    and pokes through the floor there the moment the character kneels. Shrinking it all round to fix
    that would leave a stick. So each capsule is fixed by the change that REMOVES THE LEAST VOLUME
    while keeping it within 3 mm of the posed mesh on every frame of every capture: pulling either end
    in along the bone, thinning it, or a mix. Retracting an end usually wins, and a limb keeps its girth.

    What makes the search cheap: the posed mesh's lowest point on a frame does not depend on the shapes,
    so it is computed once per frame; a candidate shape then costs two points carried per frame.
    """
    bind = parse_bvh(bind_path); Pb, Rb = forward(bind, bind[4][0]); bind_at = {n: i for i, n in enumerate(bind[0])}
    shapes = {g[0]: g[1:] for g in out}
    # The athletic torso is DESIGNED, not fitted: shaped first, then left exactly as designed by the
    # search below - a fuller chest pokes out of the mesh on purpose - so that everything joined to it
    # (the arms, the neck) is chosen against the torso it will really meet.
    result = shapes
    for bone, (depth, width) in ATHLETIC.items():
        _, a, b, r = result[bone]
        centre = (a + b) / 2.0; tip = np.linalg.norm(b - a) / 2.0 + r
        r2 = r * depth
        centre = centre + np.array([0.0, 0.0, r2 - r])      # the back (centre - r) stays put
        span = max(tip * width - r2, 0.0)
        result[bone] = ('capsule', centre - [span, 0, 0], centre + [span, 0, 0], r2)
    # Per bone, per sampled frame: the carry (bind world -> frame world) and the mesh's lowest point.
    frames = {bone: [] for bone in shapes}
    for path in captures:
        cap = parse_bvh(path); at = {n: i for i, n in enumerate(cap[0])}
        def carried(name):
            # A mesh joint the capture does not carry (a finger, an end site) rides its nearest carried
            # ancestor, left where it sat on that ancestor in the bind pose.
            while name not in at:
                name = bind[0][bind[1][bind_at[name]]]
            return name
        drivers = [carried(n) for n in names]
        ia = np.array([[at[drivers[j]] for j in row] for row in inds])
        ib = np.array([[bind_at[drivers[j]] for j in row] for row in inds])
        for frame in range(0, len(cap[4]), 3):
            Pa, Ra = forward(cap, cap[4][frame])
            V = np.zeros_like(pos)
            for k in range(4):
                local = np.einsum('nji,nj->ni', Rb[ib[:, k]], pos - Pb[ib[:, k]])
                V += weis[:, k][:, None] * (np.einsum('nij,nj->ni', Ra[ia[:, k]], local) + Pa[ia[:, k]])
            floor_of_mesh = V[:, 1].min()
            for bone in shapes:
                i, j = at[bone], bind_at[bone]
                # carry(x) = A x + t, with A = Ra Rb^T and t = Pa - A Pb
                A = Ra[i] @ Rb[j].T
                frames[bone].append((A[1], Pa[i][1] - A[1] @ Pb[j], floor_of_mesh))

    def reach(shape, bone):
        # How far below the posed mesh this shape ever gets, over every sampled frame.
        rows = frames[bone]
        A1 = np.array([r[0] for r in rows]); t1 = np.array([r[1] for r in rows]); low = np.array([r[2] for r in rows])
        if shape[0] == 'capsule':
            ya = A1 @ shape[1] + t1; yb = A1 @ shape[2] + t1
            return float(np.max(low - (np.minimum(ya, yb) - shape[3])))
        M = box_matrix(shape[2]); c, h = shape[1], shape[3]
        corners = [c + M @ (np.array([sx, sy, sz]) * h) for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
        return float(np.max(low - np.min(np.stack([A1 @ p + t1 for p in corners]), axis=0)))

    def volume(shape):
        if shape[0] == 'capsule':
            L = np.linalg.norm(shape[2] - shape[1]); r = shape[3]
            return np.pi * r * r * L + 4.0 / 3.0 * np.pi * r ** 3
        return float(np.prod(2 * shape[3]))

    def best_capsule(shape, bones):
        a, b, r = shape[1], shape[2], shape[3]
        axis = b - a; L = np.linalg.norm(axis); u = axis / max(L, 1e-9)
        best = None
        for pull_a in np.arange(0.0, 0.45 * L + 1e-9, 0.01):
            for pull_b in np.arange(0.0, 0.45 * L - pull_a + 1e-9, 0.01):
                for thin in np.arange(0.0, r - 0.015 + 1e-9, 0.005):
                    cand = ('capsule', a + u * pull_a, b - u * pull_b, r - thin)
                    if max(reach(cand, bone) for bone in bones) <= 0.003:
                        lost = volume(shape) - volume(cand)
                        if best is None or lost < best[0]:
                            best = (lost, cand, pull_a, pull_b, thin)
                        break   # thinner still only loses more
        return best

    # NEIGHBOURS MUST OVERLAP. The search may pull an end in or thin a shape, but never so far that it
    # stops meeting a neighbour: at least MEET of interpenetration, so a joint reads as connected. Shapes
    # are searched parent before child, so each is checked against its parent's FINAL shape and its
    # child's initial one; the child's own search then re-checks against this one's final shape.
    MEET = 0.015
    def overlap(x, y):
        return x[3] + y[3] - segment_gap(x[1], x[2], y[1], y[2])
    parent_of = {child: parent for parent, child in NEIGHBOURS}
    children_of = {}
    for parent, child in NEIGHBOURS:
        children_of.setdefault(parent, []).append(child)
    def meets(cand, bone, final):
        others = ([final[parent_of[bone]]] if bone in parent_of and parent_of[bone] in final else []) + \
                 [shapes[c] for c in children_of.get(bone, []) if c not in final]
        return all(overlap(cand, o) >= MEET for o in others if o[0] == 'capsule')

    # CHOSEN TOGETHER, NOT ONE AT A TIME. Searching parent before child let the upper arm pull its elbow
    # end in 7 cm and spend the whole elbow's overlap, so the forearm - which pokes through at the same
    # elbow - had no room left and stayed poking through. Every connected chain (chest-arm-forearm-hand,
    # pelvis-thigh-shin, chest-neck-head) is a tree, so the best JOINT choice is exact by dynamic
    # programming: list each shape's ways of staying inside the mesh, then pick the combination losing
    # the least volume in total while every connected pair still overlaps by MEET.
    def representative(bone):
        twin = mirror_name(bone)
        if twin in shapes and not bone.startswith('Left'):
            return None
        return [bone] + ([twin] if twin in shapes else [])

    def ways(shape, pair):
        if pair[0] in ATHLETIC:
            return [(0.0, shape, 0.0, 0.0, 0.0)], 0.0
        # Every pair of end pulls, each with the LEAST thinning that keeps the shape inside the mesh.
        # More thinning never helps an overlap and always loses volume, so the rest are dominated.
        a, bb, r = shape[1], shape[2], shape[3]
        L = np.linalg.norm(bb - a); u = (bb - a) / max(L, 1e-9)
        reach_of = lambda cand: max(reach(cand if b == pair[0] else mirrored(cand), b) for b in pair)
        found = []
        for pull_a in np.arange(0.0, 0.45 * L + 1e-9, 0.01):
            for pull_b in np.arange(0.0, 0.45 * L - pull_a + 1e-9, 0.01):
                for thin in np.arange(0.0, r - 0.015 + 1e-9, 0.005):
                    cand = ('capsule', a + u * pull_a, bb - u * pull_b, r - thin)
                    if reach_of(cand) <= 0.003:
                        found.append((volume(shape) - volume(cand), cand, pull_a, pull_b, thin))
                        break
        if not found:
            print('  %-14s WARNING: no way to keep it inside the mesh - kept as fitted' % pair[0])
            found = [(0.0, shape, 0.0, 0.0, 0.0)]
        return found, reach_of(shape)

    options = {}; poked = {}
    for bone in sorted(shapes):
        pair = representative(bone)
        if pair is None:
            continue
        if shapes[bone][0] == 'capsule':
            options[bone], poked[bone] = ways(shapes[bone], pair)
    # Bottom-up over each tree: the best total for every way of this shape, given its children.
    best = {}
    def solve(bone):
        for child in children_of.get(bone, []):
            solve(child)
        table = []
        for way in options[bone]:
            total = way[0]; picks = {}
            for child in children_of.get(bone, []):
                pick = None
                for j, (child_total, _) in enumerate(best[child]):
                    if child_total < np.inf and overlap(way[1], options[child][j][1]) >= MEET:
                        if pick is None or child_total < best[child][pick][0]:
                            pick = j
                if pick is None:
                    total = np.inf; break
                total += best[child][pick][0]; picks[child] = pick
            table.append((total, picks))
        best[bone] = table
    chosen = {}
    def settle(bone, j):
        chosen[bone] = options[bone][j]
        for child in children_of.get(bone, []):
            # A pick is missing only when the chain above had no connected choice (already warned):
            # the child then takes its own best.
            pick = best[bone][j][1].get(child)
            if pick is None:
                pick = int(np.argmin([t for t, _ in best[child]]))
            settle(child, pick)
    roots = [bone for bone in options if bone not in parent_of]
    for root in roots:
        solve(root)
        j = int(np.argmin([t for t, _ in best[root]]))
        if best[root][j][0] == np.inf:
            print('  %-14s WARNING: no joint choice keeps its chain inside the mesh and connected' % root)
        settle(root, j)

    result = {}
    for bone in sorted(shapes):
        pair = representative(bone)
        if pair is None:
            continue
        shape = shapes[bone]
        if bone in ATHLETIC:
            depth, width = ATHLETIC[bone]
            out_by = max(reach(shape, b) for b in pair)
            print('  %-14s athletic by design (depth x%.2f, width x%.2f, back held)%s' % (bone, depth, width,
                  ', reaches %.1f cm past the mesh' % (out_by * 100) if out_by > 0.003 else ''))
        elif shape[0] == 'capsule':
            lost, cand, pull_a, pull_b, thin = chosen[bone]
            if poked[bone] > 0.003:
                print('  %-14s poked %.1f cm through: ends in %.0f/%.0f cm, %.1f cm thinner, %.0f%% of its volume kept'
                      % (bone, poked[bone] * 100, pull_a * 100, pull_b * 100, thin * 100, 100 * volume(cand) / volume(shape)))
            shape = cand
        else:
            worst = max(reach(shape if b == bone else mirrored(shape), b) for b in pair)
            if worst > 0.003:
                shape = shrunk(shape, worst - 0.003)
                print('  %-14s poked %.1f cm through: a box, %.1f cm smaller all round, sole kept' % (bone, worst * 100, (worst - 0.003) * 100))
        result[bone] = shape
        if len(pair) > 1:
            result[pair[1]] = mirrored(shape)
    for parent, child in NEIGHBOURS:
        x, y = result[parent], result[child]
        if x[0] == 'capsule' and y[0] == 'capsule':
            print('  %-14s meets %-12s by %.1f cm' % (parent, child, overlap(x, y) * 100))
    # Toes as big as a forefoot (Simon, Sep 25): few vertices are weighted to the toe bone, so the fitted
    # toe box came out a sliver - 1 cm tall, 2.6 cm wide. The toes are the FRONT of the support polygon,
    # where a standing body's centre of pressure goes when it leans forward; a sliver takes that away.
    for side in ('Left', 'Right'):
        foot, toe = side + 'Foot', side + 'ToeBase'
        if foot in result and toe in result:
            was = result[toe][3] * 2
            result[toe] = forefoot(result[foot], result[toe])
            now = result[toe][3] * 2
            print('  %-14s a forefoot: %.1f x %.1f x %.1f cm (the fitted box was %.1f x %.1f x %.1f)' %
                  (toe, now[0] * 100, now[1] * 100, now[2] * 100, was[0] * 100, was[1] * 100, was[2] * 100))
    return [(bone,) + result[bone] for bone in sorted(result)]

TOE_MIN_LENGTH = 0.05       # metres, heel-to-toe direction
TOE_HEIGHT_OF_FOOT = 0.5    # the toe box's height, as a share of the foot box's

def forefoot(foot, toe):
    """The toe box rebuilt in the FOOT's frame: the foot's orientation and width, half its height with the
    sole flush with the foot's (flat from heel to toe tip), and from the fitted toe's back edge forward at
    least TOE_MIN_LENGTH. Forward is signed by where the toe sits: a principal axis has no sign of its own."""
    _, fc, fq, fh = foot
    _, tc, tq, th = toe
    R = box_matrix(fq)
    along = R[:, 0]
    sign = 1.0 if np.dot(tc - fc, along) >= 0 else -1.0
    Rt = box_matrix(tq)
    reach = [sign * np.dot(tc + Rt @ (np.array([sx, sy, sz]) * th) - fc, along)
             for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
    back = min(reach)
    front = max(max(reach), back + TOE_MIN_LENGTH)
    height = fh[1] * TOE_HEIGHT_OF_FOOT
    centre = fc + R @ np.array([sign * (back + front) / 2, -fh[1] + height, 0.0])
    return ('box', centre, fq, np.array([(front - back) / 2, height, fh[2]]))

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:])
