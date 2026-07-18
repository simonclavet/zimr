# project1 — Bouncing Balls

A 2D demo that exercises shape drawing, mouse input, and ImGui
controls.

## What it does

- N circles bouncing inside the window with simple gravity + wall
  reflections.  All physics is in `update()` — no library calls
  beyond zimr's `f.clock.frameTime()`.
- Click anywhere to spawn a new ball.  Clicks that land on the
  ImGui panel are ignored (`f.ui.wantCaptureMouse()` guard).
- Status line at the bottom shows current ball count and pause state.

## ImGui controls

| Widget | Range | Notes |
|---|---|---|
| `gravity (px/s²)` | 0 – 2500 | 980 = Earth gravity at this scale |
| `damping` | 0 – 1.0 | Wall-bounce coefficient.  1.0 = perfectly elastic; 0 = sticks |
| `spawn radius` | 4 – 48 px | Size of newly-spawned balls |
| `paused` checkbox | — | Stops the integrator without clearing |
| `show velocity` checkbox | — | Draws a 2-pixel tracer line |
| `background` color picker | — | Live update |
| `clear` button | — | Drops every ball |
| `add 10` button | — | Spawns 10 balls along the top edge |

## Code map

- `State` — every per-ball field plus all tunables, kept in one
  struct.  Uses a fixed-size array (`[MAX_BALLS]Ball`) instead of an
  `ArrayList` to avoid allocator churn during physics updates.
- `spawnBall()` — simple init logic; cycles through a 6-color
  palette so every ball is visually distinct.
- `update()` — integrates physics, draws balls, draws the HUD line,
  draws the ImGui panel.  Order matters: the ImGui panel goes last
  so it draws on top.

## Things to try

- Crank `gravity` up to 2500 — balls become a downpour.
- Drop `damping` to 0.5 — balls die out fast.
- Drop `spawn radius` to 4 + click rapidly — confetti.
- Set `damping = 1.0` + `gravity = 0` — billiards forever.
