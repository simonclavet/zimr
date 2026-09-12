#!/usr/bin/env python3
"""Generate robot.zig reference fixtures from REAL MuJoCo.

    pip install mujoco --break-system-packages
    python3 scripts/robot_oracle.py            # writes src/tests/fixtures/robot/reference.zig

Run this ONCE per new model or state, never as part of a build: the emitted Zig is
checked in, so `zig build test` needs no Python, no network and no MuJoCo.
Same shape as the spv2wgsl corpus.

WHY THIS EXISTS
    A mass matrix cannot be eyeballed. The failure mode this guards is a port that runs,
    looks like a simulation, and is quietly wrong -- above all the `cdof` sign/frame trap
    (see P2 in src/notes/robot_port_plan.md), which produces plausible motion from wrong
    dynamics. Differential testing against the reference implementation is the only cheap
    way to catch that class.

Y-UP (see plan section 1.2)
    zimr is Y-up; MuJoCo is Z-up by default. Every model here sets gravity to
    `0 -9.81 0` and is authored in zimr's frame, so the emitted numbers need no mental
    rotation to read. The conversion lives here, once, not in every test.

PRECISION (see plan section 1.1)
    MuJoCo is f64, robot.zig is f32. Tolerances on the Zig side are ~1e-5 relative, not
    1e-12. A gap that GROWS as models get stiffer is the P1 conditioning signal -- treat
    that as information, not as a reason to loosen the tolerance.
"""

import os
import sys

try:
    import mujoco
    import numpy as np
except ImportError:
    sys.exit("need: pip install mujoco --break-system-packages")

OUT = "src/tests/fixtures/robot/reference.zig"

# Every model is authored Y-UP: gravity along -Y, links hanging along -Y.
MODELS = {
    # One hinge about Z, arm hanging down -Y. The simplest case with a nonzero M and c.
    "single_pendulum": """
<mujoco>
  <option gravity="0 -9.81 0"/>
  <worldbody>
    <body name="link" pos="0 0 0">
      <joint name="j1" type="hinge" axis="0 0 1"/>
      <geom type="capsule" fromto="0 0 0 0 -0.5 0" size="0.05" density="1000"/>
    </body>
  </worldbody>
</mujoco>""",

    # The phase-3 demo. Chaotic, and unforgiving of a wrong M or c.
    "double_pendulum": """
<mujoco>
  <option gravity="0 -9.81 0"/>
  <worldbody>
    <body name="upper" pos="0 0 0">
      <joint name="j1" type="hinge" axis="0 0 1"/>
      <geom type="capsule" fromto="0 0 0 0 -0.5 0" size="0.05" density="1000"/>
      <body name="lower" pos="0 -0.5 0">
        <joint name="j2" type="hinge" axis="0 0 1"/>
        <geom type="capsule" fromto="0 0 0 0 -0.4 0" size="0.04" density="1000"/>
      </body>
    </body>
  </worldbody>
</mujoco>""",

    # Mixed axes: catches a cdof built in the wrong frame, which a planar chain cannot.
    "arm3": """
<mujoco>
  <option gravity="0 -9.81 0"/>
  <worldbody>
    <body name="a" pos="0 0 0">
      <joint name="j1" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 0.3 0 0" size="0.04" density="800"/>
      <body name="b" pos="0.3 0 0">
        <joint name="j2" type="hinge" axis="0 0 1"/>
        <geom type="capsule" fromto="0 0 0 0.25 0 0" size="0.035" density="800"/>
        <body name="c" pos="0.25 0 0">
          <joint name="j3" type="hinge" axis="1 0 0"/>
          <geom type="capsule" fromto="0 0 0 0.2 0 0" size="0.03" density="800"/>
        </body>
      </body>
    </body>
  </worldbody>
</mujoco>""",

    # nq != nv: a free joint is 7 position coords and 6 velocity coords.
    "free_body": """
<mujoco>
  <option gravity="0 -9.81 0"/>
  <worldbody>
    <body name="box" pos="0 1 0">
      <freejoint/>
      <geom type="box" size="0.1 0.2 0.3" density="500"/>
    </body>
  </worldbody>
</mujoco>""",

    # nq != nv again, and the ball-joint cdof path (three axes from the child frame).
    "ball_chain": """
<mujoco>
  <option gravity="0 -9.81 0"/>
  <worldbody>
    <body name="upper" pos="0 0 0">
      <joint name="b1" type="ball"/>
      <geom type="capsule" fromto="0 0 0 0 -0.4 0" size="0.05" density="1000"/>
      <body name="lower" pos="0 -0.4 0">
        <joint name="h1" type="hinge" axis="1 0 0"/>
        <geom type="capsule" fromto="0 0 0 0 -0.3 0" size="0.04" density="1000"/>
      </body>
    </body>
  </worldbody>
</mujoco>""",

    # PHASE 6a: a hinge driven past its limit, so a limit constraint is ACTIVE. Both
    # limits and a deliberately soft solref, to exercise the impedance sigmoid rather
    # than only its saturated ends.
    "limit_soft": """
<mujoco>
  <option gravity="0 -9.81 0"/>
  <worldbody>
    <body name="link" pos="0 0 0">
      <joint name="j" type="hinge" axis="0 0 1" range="-30 30" limited="true"
             solreflimit="0.05 1" solimplimit="0.9 0.95 0.03 0.5 2"/>
      <geom type="capsule" fromto="0 0 0 0 -0.5 0" size="0.05" density="1000"/>
    </body>
  </worldbody>
</mujoco>""",

    # The same joint with MuJoCo's DEFAULT solref/solimp, so the fixtures cover both the
    # authored-softness path and the default one. (Its `rest` state also has nefc = 0, which
    # is the inactive path -- a suite that only ever sees active constraints cannot catch a
    # broken activation test.)
    "limit_default": """
<mujoco>
  <option gravity="0 -9.81 0"/>
  <worldbody>
    <body name="link" pos="0 0 0">
      <joint name="j" type="hinge" axis="0 0 1" range="-90 90" limited="true"/>
      <geom type="capsule" fromto="0 0 0 0 -0.5 0" size="0.05" density="1000"/>
    </body>
  </worldbody>
</mujoco>""",

    # Two limited joints, so the row ORDER and the per-row parameters both matter.
    "limit_chain": """
<mujoco>
  <option gravity="0 -9.81 0"/>
  <worldbody>
    <body name="upper" pos="0 0 0">
      <joint name="j1" type="hinge" axis="0 0 1" range="-20 20" limited="true"/>
      <geom type="capsule" fromto="0 0 0 0 -0.5 0" size="0.05" density="1000"/>
      <body name="lower" pos="0 -0.5 0">
        <joint name="j2" type="hinge" axis="0 0 1" range="-45 10" limited="true"/>
        <geom type="capsule" fromto="0 0 0 0 -0.4 0" size="0.04" density="1000"/>
      </body>
    </body>
  </worldbody>
</mujoco>""",

    # PHASE 6a, the TWO-SIDED case: a narrow range with a generous margin, so BOTH ends
    # are within margin at once and MuJoCo emits two rows for one joint. Without this model
    # the two-sided path is unreachable and a min()-of-both-distances shortcut looks correct.
    "limit_both_sides": """
<mujoco>
  <option gravity="0 -9.81 0"/>
  <worldbody>
    <body name="link" pos="0 0 0">
      <joint name="j" type="hinge" axis="0 0 1" range="-5 5" limited="true" margin="0.4"/>
      <geom type="capsule" fromto="0 0 0 0 -0.5 0" size="0.05" density="1000"/>
    </body>
  </worldbody>
</mujoco>""",

    # PHASE 6d: a link resting on the ground, so real CONTACT rows exist. The contact
    # itself (position, frame, penetration, friction) is emitted alongside the rows, so
    # robot.zig can be fed MuJoCo's exact contact and the ROW MATH tested with collision
    # detection entirely out of the picture -- the same separation that made 6a debuggable.
    "contact_ground": """
<mujoco>
  <option gravity="0 -9.81 0" cone="pyramidal"/>
  <worldbody>
    <geom name="floor" type="plane" pos="0 -0.575 0" quat="0.7071068 -0.7071068 0 0"
          size="5 5 0.1" friction="0.7 0.005 0.0001"/>
    <body name="link" pos="0 0 0">
      <joint name="j" type="hinge" axis="0 0 1"/>
      <geom name="tip" type="sphere" pos="0 -0.55 0" size="0.06" density="1000"
            friction="0.7 0.005 0.0001"/>
    </body>
  </worldbody>
</mujoco>""",

    # P1 probe: ~1000:1 mass ratio. The f32 gap should be VISIBLY larger here than
    # elsewhere; when it stops being acceptable, that is the signal to widen factorM.
    "mass_ratio": """
<mujoco>
  <option gravity="0 -9.81 0"/>
  <worldbody>
    <body name="torso" pos="0 0 0">
      <joint name="j1" type="hinge" axis="0 0 1"/>
      <geom type="box" size="0.3 0.3 0.3" density="2000"/>
      <body name="tip" pos="0.3 0 0">
        <joint name="j2" type="hinge" axis="0 0 1"/>
        <geom type="capsule" fromto="0 0 0 0.05 0 0" size="0.004" density="300"/>
      </body>
    </body>
  </worldbody>
</mujoco>""",
}

# States are per-model because nq/nv differ. Each is (name, qpos, qvel).
def states_for(m):
    """A rest state plus two arbitrary-but-fixed poses. Deliberately not symmetric:
    a symmetric state can hide a transposed or sign-flipped term."""
    nq, nv = m.nq, m.nv
    # "rest" must be qpos0, NOT zeros: a free or ball joint's zeros are a DEGENERATE
    # quaternion, which is not a state either simulator is defined at.
    out = [("rest", np.array(m.qpos0), np.zeros(nv))]
    qp = np.zeros(nq)
    qv = np.zeros(nv)
    # Fill generalized coordinates with distinct, non-round values. Quaternion blocks
    # (free/ball joints) must stay unit-norm, so set them to a fixed tilted rotation.
    j = 0
    for jnt in range(m.njnt):
        jt = m.jnt_type[jnt]
        adr = m.jnt_qposadr[jnt]
        if jt == mujoco.mjtJoint.mjJNT_FREE:
            qp[adr:adr + 3] = [0.11, 1.23, -0.37]
            # MuJoCo order (w, x, y, z) here -- this is fed to MuJoCo. The emitter converts.
            qp[adr + 3:adr + 7] = [0.9238795, 0.3826834, 0.0, 0.0]  # 45deg about X
        elif jt == mujoco.mjtJoint.mjJNT_BALL:
            qp[adr:adr + 4] = [0.9659258, 0.0, 0.2588190, 0.0]      # 30deg about Y
        else:
            # For a limited joint, drive PAST the limit so the constraint is active and
            # the fixture exercises the row assembly rather than an empty list.
            if m.jnt_limited[jnt]:
                lo, hi = m.jnt_range[jnt]
                qp[adr] = hi + 0.12 if j % 2 == 0 else lo - 0.12
            else:
                qp[adr] = [0.3, -0.7, 0.45, -0.2][j % 4]
            j += 1
    for i in range(nv):
        qv[i] = [1.1, -0.4, 0.7, -0.9, 0.25, -0.6][i % 6]
    out.append(("posed", qp.copy(), np.zeros(nv)))
    out.append(("moving", qp.copy(), qv.copy()))
    return out


def to_zimr_qpos(m, qpos):
    """MuJoCo stores quaternions (w, x, y, z); zm stores them (x, y, z, w).

    Every other quantity we emit is order-agnostic, but qpos carries raw quaternions for
    free and ball joints, so it must be reordered or the fixtures describe a different
    rotation. This is the same class of thing as the Y-up conversion: do it ONCE here, so
    the emitted numbers are already in zimr's convention and need no mental translation.
    """
    out = np.array(qpos, dtype=float)
    for j in range(m.njnt):
        jt = m.jnt_type[j]
        adr = m.jnt_qposadr[j]
        if jt == mujoco.mjtJoint.mjJNT_FREE:
            base = adr + 3
        elif jt == mujoco.mjtJoint.mjJNT_BALL:
            base = adr
        else:
            continue
        w, x, y, z = out[base:base + 4]
        out[base:base + 4] = [x, y, z, w]
    return out


def zig_u32_array(xs):
    return "&.{ " + ", ".join(str(int(x)) for x in xs) + " }"


def zig_f32_array(xs):
    # Zig rejects a bare '-0' as an ambiguous literal: it wants '0' for an integer zero or
    # '-0.0' for a signed floating one. MuJoCo emits negative zeros freely (a cross product
    # of aligned vectors, say), so normalise them rather than emitting invalid Zig.
    def lit(x):
        v = float(x)
        if v == 0.0:
            return "0.0"
        return f"{v:.9g}"
    return "&.{ " + ", ".join(lit(x) for x in np.asarray(xs).ravel()) + " }"


def emit():
    parts = [
        "// GENERATED by scripts/robot_oracle.py from REAL MuJoCo. Do not hand-edit.\n"
        "//\n"
        "// Reference values for robot.zig, in ZIMR's Y-UP FRAME (gravity 0,-9.81,0) --\n"
        "// the generator authors the models that way so these numbers need no mental\n"
        "// rotation. See src/notes/robot_port_plan.md sections 1.2 and 7.\n"
        "//\n"
        "// MuJoCo computes in f64 and robot.zig is f32, so compare with a RELATIVE\n"
        "// tolerance around 1e-5. A gap that grows with model stiffness is the P1\n"
        "// conditioning signal, not a reason to loosen the tolerance.\n"
        f"// mujoco {mujoco.__version__}\n",
        "\npub const Case = struct {\n"
        "    model: []const u8,\n"
        "    state: []const u8,\n"
        "    nq: usize,\n"
        "    nv: usize,\n"
        "    qpos: []const f32,\n"
        "    qvel: []const f32,\n"
        "    /// Dense row-major nv*nv joint-space inertia (mj_fullM).\n"
        "    mass_matrix: []const f32,\n"
        "    /// Coriolis + centrifugal + gravity (qfrc_bias), nv.\n"
        "    bias: []const f32,\n"
        "    /// Forward-dynamics acceleration with zero control (qacc), nv.\n"
        "    acc: []const f32,\n"
        "    /// Per-body world position (xpos), nbody*3, body 0 = world.\n"
        "    body_pos: []const f32,\n"
        "    /// Per-body world centre-of-mass position (xipos), nbody*3.\n"
        "    body_ipos: []const f32,\n"
        "    /// Centre of mass of each body's subtree, world space, nbody*3.\n"
        "    subtree_com: []const f32,\n"
        "    /// Body inertia in the subtree-com frame (cinert), nbody*10. MuJoCo's packing\n"
        "    /// is [Ixx Iyy Izz, Ixy Ixz Iyz, hx hy hz, m] -- the same ten numbers as\n"
        "    /// robot.Inertia, in the same order.\n"
        "    cinert: []const f32,\n"
        "    /// Each dof's motion axis in that frame (cdof), nv*6, ANGULAR FIRST.\n"
        "    cdof: []const f32,\n"
        "    /// Translational Jacobian of every body's centre of mass, nbody*3*nv,\n"
        "    /// row-major per body (mj_jacBodyCom's jacp).\n"
        "    jac_com_p: []const f32,\n"
        "    /// Rotational Jacobian of every body, nbody*3*nv (mj_jacBodyCom's jacr).\n"
        "    jac_com_r: []const f32,\n"
        "    /// Number of ACTIVE constraint rows at this state (nefc).\n"
        "    nefc: usize,\n"
        "    /// Constraint Jacobian, nefc*nv row-major (efc_J).\n"
        "    efc_j: []const f32,\n"
        "    /// Constraint residual per row (efc_pos - efc_margin).\n"
        "    efc_pos: []const f32,\n"
        "    /// Reference acceleration per row (efc_aref).\n"
        "    efc_aref: []const f32,\n"
        "    /// Number of contacts MuJoCo found (ncon).\n"
        "    ncon: usize,\n"
        "    /// Per contact: world position (3), penetration `dist` (1, negative when\n"
        "    /// touching), sliding friction (1), and the contact frame as 9 row-major\n"
        "    /// floats whose FIRST ROW is the normal. 14 floats per contact.\n"
        "    contacts: []const f32,\n"
        "    /// Body index of each contact's two geoms, 2 per contact. Body 0 is the world.\n"
        "    contact_bodies: []const u32,\n"
        "    /// Diagonal regularizer per row (efc_R).\n"
        "    efc_r: []const f32,\n"
        "    /// EXACT constraint-space inertia diag(J M^-1 J^T), computed from MuJoCo's\n"
        "    /// own efc_J and mass matrix rather than read from efc_diagA -- which is\n"
        "    /// degenerate for contact rows on MuJoCo 3.11. See this script's comment.\n"
        "    efc_diag: []const f32,\n"
        "    /// (1 - impedance)/impedance per row: R divided by whichever diagonal MuJoCo\n"
        "    /// used. Checks the impedance sigmoid independently of that diagonal.\n"
        "    efc_r_ratio: []const f32,\n"
        "};\n",
    ]
    cases = []
    for name, xml in MODELS.items():
        m = mujoco.MjModel.from_xml_string(xml)
        # NOTE: we do NOT rely on mjENBL_DIAGEXACT. On MuJoCo 3.11 it makes efc_diagA
        # degenerate for CONTACT rows (1.86e-14 for every row of a contact whose true
        # J M^-1 J^T diagonal is 0.6255), while working correctly for limit rows. Rather
        # than trust a derived field, the exact diagonal below is computed from MuJoCo's
        # OWN efc_J and mass matrix -- the mathematical definition, from the oracle's
        # primitives. That is a stronger oracle regardless: it cannot be wrong in a way
        # that a flag or an internal approximation makes wrong.
        d = mujoco.MjData(m)
        for sname, qp, qv in states_for(m):
            d.qpos[:] = qp
            d.qvel[:] = qv
            d.ctrl[:] = 0
            mujoco.mj_forward(m, d)
            M = np.zeros((m.nv, m.nv))
            mujoco.mj_fullM(m, d, M)
            # Body-COM Jacobians for every body, so the phase-4 test has a target for each.
            # Constraint rows. MuJoCo stores efc_J sparse or dense depending on the
            # solver setting; mj_constraintUpdate has already run inside mj_forward, so
            # the arrays are populated. Dense-ify defensively.
            n = int(d.nefc)
            efc_j = np.array(d.efc_J, dtype=float).reshape(n, m.nv) if n else np.zeros((0, m.nv))
            efc_pos = (np.array(d.efc_pos[:n]) - np.array(d.efc_margin[:n])) if n else np.zeros(0)
            efc_aref = np.array(d.efc_aref[:n]) if n else np.zeros(0)
            efc_r = np.array(d.efc_R[:n]) if n else np.zeros(0)
            efc_diag_mujoco = np.array(d.efc_diagA[:n]) if n else np.zeros(0)
            # Ground truth: diag(J M^-1 J^T), from MuJoCo's own J and M.
            if n:
                Mfull = np.zeros((m.nv, m.nv))
                mujoco.mj_fullM(m, d, Mfull)
                efc_diag = np.diag(efc_j @ np.linalg.inv(Mfull) @ efc_j.T)
                # (1 - impedance)/impedance, which is R/diagA and so is independent of
                # whichever diagonal MuJoCo used. This is how the impedance sigmoid is
                # checked without depending on efc_diagA being trustworthy.
                with np.errstate(divide="ignore", invalid="ignore"):
                    efc_r_ratio = np.where(efc_diag_mujoco > 0,
                                           efc_r / np.maximum(efc_diag_mujoco, 1e-300), 0.0)
            else:
                efc_diag = np.zeros(0)
                efc_r_ratio = np.zeros(0)

            # Contacts, so the row math can be tested without a collision detector.
            contact_data = []
            contact_bodies = []
            for ci in range(d.ncon):
                con = d.contact[ci]
                contact_data.extend(list(con.pos))
                contact_data.append(float(con.dist))
                contact_data.append(float(con.friction[0]))
                contact_data.extend(list(np.array(con.frame).ravel()))
                for g in (con.geom1, con.geom2):
                    contact_bodies.append(int(m.geom_bodyid[g]))

            jacp_all = np.zeros((m.nbody, 3, m.nv))
            jacr_all = np.zeros((m.nbody, 3, m.nv))
            for b in range(m.nbody):
                jp = np.zeros((3, m.nv))
                jr = np.zeros((3, m.nv))
                mujoco.mj_jacBodyCom(m, d, jp, jr, b)
                jacp_all[b] = jp
                jacr_all[b] = jr
            cases.append(
                "    .{\n"
                f'        .model = "{name}",\n'
                f'        .state = "{sname}",\n'
                f"        .nq = {m.nq},\n"
                f"        .nv = {m.nv},\n"
                f"        .qpos = {zig_f32_array(to_zimr_qpos(m, d.qpos))},\n"
                f"        .qvel = {zig_f32_array(d.qvel)},\n"
                f"        .mass_matrix = {zig_f32_array(M)},\n"
                f"        .bias = {zig_f32_array(d.qfrc_bias)},\n"
                f"        .acc = {zig_f32_array(d.qacc)},\n"
                f"        .body_pos = {zig_f32_array(d.xpos)},\n"
                f"        .body_ipos = {zig_f32_array(d.xipos)},\n"
                f"        .subtree_com = {zig_f32_array(d.subtree_com)},\n"
                f"        .cinert = {zig_f32_array(d.cinert)},\n"
                f"        .cdof = {zig_f32_array(d.cdof)},\n"
                f"        .jac_com_p = {zig_f32_array(jacp_all)},\n"
                f"        .jac_com_r = {zig_f32_array(jacr_all)},\n"
                f"        .nefc = {d.nefc},\n"
                f"        .efc_j = {zig_f32_array(efc_j)},\n"
                f"        .efc_pos = {zig_f32_array(efc_pos)},\n"
                f"        .efc_aref = {zig_f32_array(efc_aref)},\n"
                f"        .ncon = {d.ncon},\n"
                f"        .contacts = {zig_f32_array(contact_data)},\n"
                f"        .contact_bodies = {zig_u32_array(contact_bodies)},\n"
                f"        .efc_r = {zig_f32_array(efc_r)},\n"
                f"        .efc_r_ratio = {zig_f32_array(efc_r_ratio)},\n"
                f"        .efc_diag = {zig_f32_array(efc_diag)},\n"
                "    },"
            )
    parts.append("\npub const cases = [_]Case{\n" + "\n".join(cases) + "\n};\n")
    return "".join(parts)


def zig_fmt(path):
    """The build gates on `zig fmt --check src ...`, and this file lands under src/.
    Generating unformatted Zig would break the build for whoever regenerates next, so
    format here rather than leaving a trap in a comment."""
    import glob
    import subprocess
    hits = sorted(glob.glob("tools/zig-x86_64-linux-*/zig"))
    if not hits:
        print("  ! zig not found -- run `zig fmt " + path + "` before committing")
        return
    subprocess.run([hits[-1], "fmt", path], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    text = emit()
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    zig_fmt(OUT)
    n = text.count(".model = ")
    print(f"wrote {OUT}: {n} cases, {len(text.splitlines())} lines")
