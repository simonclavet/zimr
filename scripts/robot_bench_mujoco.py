#!/usr/bin/env python3
"""robot_bench_mujoco.py — the other half of the §4g benchmark.

Runs the same three cases through MuJoCo on this machine so the zimr numbers mean something.
A benchmark against a remembered figure from someone else's laptop is not a benchmark.

Kept honest in three ways:

  * the SAME models — the two-link arm transcribed from `src/robot_bench.zig`, and the KUKA
    from the very URDF the importer reads, so neither side gets a friendlier mechanism;
  * the same step count, single-threaded, from the same initial state;
  * MuJoCo's own defaults left alone. Matching its solver iteration cap to ours would be
    tuning the opponent, and its defaults are what a user of MuJoCo actually gets.

The comparison is not apples-to-apples in one respect that must be stated: MuJoCo is f64 and
zimr is f32. That is a deliberate design difference (§1.1), not a benchmarking trick — but a
2x memory-bandwidth advantage is part of why zimr might win, and pretending otherwise would
be dishonest.
"""

import re
import time

import mujoco
import numpy as np

STEPS = 200_000
TIMESTEP = 1.0 / 240.0

TWO_LINK = f"""
<mujoco>
  <option timestep="{TIMESTEP}" gravity="0 -9.81 0"/>
  <worldbody>
    <body name="upper">
      <joint name="shoulder" type="hinge" axis="0 0 1" armature="0.002"/>
      <geom type="capsule" fromto="0 0 0 0 -0.52 0" size="0.045" density="1000"/>
      <body name="lower" pos="0 -0.52 0">
        <joint name="elbow" type="hinge" axis="0 0 1" armature="0.002"/>
        <geom type="capsule" fromto="0 0 0 0 -0.44 0" size="0.035" density="1000"/>
      </body>
    </body>
  </worldbody>
</mujoco>"""


def kuka_without_meshes():
    """The KUKA URDF with its mesh geometry removed.

    MuJoCo cannot open the file otherwise — the mesh files are not in the repository, which
    is the same reason zimr's importer skips them. Stripping them makes the two engines
    simulate the SAME thing: eight inertials connected by seven hinges, no collision
    geometry on either side. Leaving them in for MuJoCo and out for zimr would be comparing
    different models.
    """
    text = open("src/tests/fixtures/robot/kuka_iiwa.urdf").read()
    # Remove every <collision>...</collision> and <visual>...</visual> block.
    for tag in ("collision", "visual"):
        text = re.sub(rf"<{tag}>.*?</{tag}>", "", text, flags=re.S)
    return text


def bench(label, model, data, steps=STEPS):
    # *** nstep=N LOOPS INSIDE C. ***
    #
    # This is not an optimisation, it is the difference between a benchmark and a
    # measurement of pybind11. Calling mj_step() once per iteration from Python costs
    # roughly a microsecond of binding overhead per call — which for a two-link model whose
    # physics takes a few hundred nanoseconds would mean timing the language boundary and
    # reporting it as MuJoCo being slow. Measured: 3340 ns/step per-call versus the real
    # figure below.
    #
    # The Zig side loops natively for the same reason, so both are now timing physics.
    mujoco.mj_step(model, data, nstep=1000)

    started = time.perf_counter_ns()
    mujoco.mj_step(model, data, nstep=steps)
    elapsed = time.perf_counter_ns() - started

    per_step = elapsed / steps
    realtime = model.opt.timestep / (per_step * 1e-9)
    print(
        f"{label:<28} nv {model.nv:>2}  {per_step:>8.0f} ns/step  "
        f"{realtime:>8.0f}x realtime  nefc {data.nefc}"
    )
    return per_step


def main():
    print(f"\n=== MuJoCo {mujoco.__version__}, {STEPS} steps each, single-threaded ===")

    # ---- 1. two links ----
    m = mujoco.MjModel.from_xml_string(TWO_LINK)
    d = mujoco.MjData(m)
    d.qpos[:] = [1.1, -0.6]
    bench("1. two-link arm", m, d)

    # ---- 2. the KUKA, from the same URDF the importer reads ----
    m = mujoco.MjModel.from_xml_string(kuka_without_meshes())
    m.opt.timestep = TIMESTEP
    d = mujoco.MjData(m)
    d.qpos[1] = 0.6
    d.qpos[3] = -0.9
    bench("2. KUKA iiwa, free", m, d)

    # ---- 3. the same, every limit active ----
    m = mujoco.MjModel.from_xml_string(kuka_without_meshes())
    m.opt.timestep = TIMESTEP
    m.jnt_limited[:] = 1
    m.jnt_range[:] = np.array([-0.05, 0.05])
    d = mujoco.MjData(m)
    d.qpos[:] = 0.3  # outside every limit
    mujoco.mj_forward(m, d)
    bench("3. KUKA, all limits active", m, d)
    print()


if __name__ == "__main__":
    main()
