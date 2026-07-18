# project2 — 3D Cube Viewer

A 3D demo that exercises the camera, the matrix stack, and the
ImGui panel layout.

## What it does

- A textured cube spinning above a 1-meter-spacing reference grid.
- Optional XYZ axis lines (red / green / blue) and wireframe overlay.
- Adjustable spin speeds on yaw and pitch axes; the cube can be
  paused mid-spin.
- All 3D drawing happens between `z.camera.beginMode3D(cam)` and
  `z.camera.endMode3D()`.  The 2D HUD (status line, ImGui) draws
  after `endMode3D()` so coordinates flip back to screen space.

## ImGui controls

| Widget | Range | Notes |
|---|---|---|
| `spin yaw  (°/s)` | -360 – 360 | Rotation around Y axis |
| `spin pitch (°/s)` | -360 – 360 | Rotation around X axis |
| `paused` checkbox | — | Freezes both spins |
| `size` | 0.2 – 4.0 | Cube edge length in meters |
| `color` color picker | — | Live update |
| `wireframe overlay` checkbox | — | Draws white edge lines on top |
| `camera distance` | 2.0 – 15.0 | Pulls camera back; same angle |
| `ground grid` checkbox | — | 20×20 grid at `y = 0` |
| `axes` checkbox | — | RGB reference axes from origin |
| `reset` button | — | All spins, sizes, colors back to defaults |

## Code map

- `State` — angles + tunables, no entity collections (it's one cube).
- `update()` — integrate spins (with `shared.wrap` to keep angles
  in `[0, 360)`), set up the camera, draw scene, then HUD + panel.
- The cube's transform is built by hand on the rlgl matrix stack:
  `rlPushMatrix → rlTranslatef → rlRotatef × 2 → drawCubeV →
  rlPopMatrix`.  `drawCubeV` itself emits at the local origin; the
  matrix on the stack places it.

## Things to try

- Set `spin yaw = 0` and `spin pitch = 90` — clean tumble.
- Pause and pull `camera distance` to 15 — feels astronomical.
- `wireframe overlay` + `size = 4` + `cube color` near-black —
  ghost cube look.
