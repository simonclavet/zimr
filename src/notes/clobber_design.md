# The queue-timeline UBO clobber — root cause, the whole class, and the fix

## What the bug actually is (from the launcher call-log dump)

WebGPU runs **every** `queue.writeBuffer` before **any** pass in the frame
executes. So if one `(buffer, offset)` is written twice in a frame, *only the
last value exists* by the time any pass runs — including passes recorded before
the second write. Every earlier pass silently reads the late value.

The launcher `-Dfocus=launcher` failure is a REAL instance, not a dead write.
The dumped frame-0 sequence shows:

```
SEQ 7..11   write buffers 97,98,99,100,101   (values for model draw #1)
SEQ 17      draw_indexed(pass 87)            ← records, expecting the SEQ7 values
SEQ 18      end pass 87
SEQ 27..31  write buffers 97,98,99,100,101   (values for model draw #2) ← CLOBBER
SEQ 34      draw_indexed(pass 151)
```

Pass 87 was recorded between the two write-groups, so at submit time it reads
draw #2's matrices, not draw #1's. Two models, one wrong.

## Whose buffers are 97–101?

`src/draw3d.zig` → `pbr3d.Renderer`. It owns **five fixed 64-byte VS mat4 UBOs**
(`vs_uniform_buffers[5]` = model, view, projection, normal, light-space) plus one
FS UBO, and `draw()` **rewrites all six every call**. Its own comment admits the
limitation:

> `// Both are shared and rewritten per draw (single-model-per-frame v1).`

Any frame that draws ≥2 models through this renderer clobbers. The launcher hits
it because `helmet_sw` (its active[0] child) draws the Damaged Helmet twice
(CPU-shaded vs GPU-PBR side by side). Every multi-model scene has the same latent
bug; it just isn't in the standard `check` gate because that gate doesn't smoke
the launcher.

## This is a CLASS, not one bug

The same hazard has been hit and patched three separate times, each ad-hoc:

| Site | Symptom | Fix that was applied |
|---|---|---|
| 2D shapes ortho UBO | "duplicated grid" (zimr516) | 32-slot **ortho ring** in renderer_2d |
| immediate 3D batch UBO | launcher/voxel clobber (zimr534) | removed a dead init **seed** |
| pbr3d model UBOs (this) | launcher clobber (zimr539) | **none yet** |

The pattern is clear: *every subsystem that writes a UBO per draw/segment must
independently remember to make that write clobber-safe*, and forgetting it is a
silent device-only corruption that only smoke catches, and only if smoke happens
to exercise the multi-write path. That is the thing worth fixing structurally.

## Options

**A. Give pbr3d a ring (status quo, extended).**
Mirror the ortho ring: N pre-built (buffer, bind-group) slots, `draw()` advances
the cursor and writes fresh slots. Low risk, ~localized to draw3d.zig, proven
pattern. But it's the third copy of the same idea and the next UBO writer will
forget again. Doesn't fix the class.

**B. One frame-wide uniform ARENA (the principled fix).**
Replace fixed per-subsystem UBO buffers with a single large per-frame uniform
buffer + a bump allocator. "Write a UBO" = bump a fresh offset, write once there,
bind at that offset. Because every logical write lands at a *new* offset, the
same region is never written twice — the clobber becomes **structurally
impossible**, engine-wide, for anyone who routes through the arena. `BindGroupEntry`
already supports `{handle, offset, size}`, so one buffer + many bind groups (or
dynamic offsets) is feasible today. Cost: a real refactor — ~26 `queueWriteBuffer`
UBO sites and their bind-group creation across draw3d / renderer_2d /
shader_runtime_wgpu would migrate to the arena. Higher risk, but retires the
whole bug class and deletes the ad-hoc ring code.

**C. Make `Resources.writeUbo` ring-internally.**
Centralizes safety for everyone who uses `shader.Resources`. But pbr3d hand-rolls
its buffers and does NOT use `Resources`, so this alone wouldn't fix the reported
bug without also migrating pbr3d onto Resources.

## Recommendation

Do **A now** to make the launcher correct and unblock the gate (small, safe,
matches the proven ring), AND schedule **B** as the real cure — a single
`FrameUniforms` arena that the ortho ring, pbr3d, and `Resources.writeUbo` all
route through, after which the per-subsystem rings and seeds delete. B is the
"back to the drawing board" answer; A is the honest interim so nothing ships
broken while B lands.

Open question for B: dynamic-offset bind groups (one bind group, offset varies
per draw) vs. a pool of pre-built bind groups at fixed offsets. Dynamic offsets
are fewer objects but need the bind-group layout flagged `has_dynamic_offset` and
the mock/bridge to honor the offset arg on `setBindGroup`. Pre-built pool matches
today's ortho ring exactly and needs no bridge change. Leaning pre-built pool for
B to keep the bridge untouched.

---

## RESOLVED (zimr540) — what we actually did

The investigation was unblocked by Simon's suggestion: **give resource creation a
name in non-ship builds**. Implemented as label→log plumbing in the smoke harness:

- `wgpu.createBuffer`/`createBindGroup` already forwarded `desc.label` (ptr,len)
  to the JS mock. The mock (`webtests/runner.mjs`) now DECODES that label from
  SUT memory at create time and appends a `LABEL_MAP(handle, name)` line to the
  call log.
- `printClobberFail` (`webtests/wgpu_smoke.zig`) scans the log for the marker and
  names the offending buffer: `buffer 107 (label='pbr3d_vs_ubo_ring') ...`.
- Added labels to the previously-unlabeled clobber-prone buffers (pbr3d ring,
  ortho ring). An empty `label=''` in the failure is now itself the signal:
  "add a `.label` at that createBuffer site."

With the buffer NAMED, the root cause was immediate: buffer 107 = `pbr3d_vs_ubo_ring`.

**Root cause (two bugs, same class):**
1. `pbr3d.Renderer` wrote 5 fixed VS UBOs + 1 FS UBO per `draw()` — "single-model
   -per-frame v1". Two model draws in a frame (helmet_sw draws the helmet; any
   multi-model scene) clobbered. → Fixed with an **8-slot UBO ring** (mirrors the
   ortho ring): `draw()` advances a cursor and writes a fresh slot; `beginFrame`/
   `drawInApp` reset the cursor; a wrap asserts.
2. The ring's init SEEDED every slot to identity. But the launcher inits children
   LAZILY inside update frame 0, so the seed writes landed in the SAME frame as
   the first draw's writes → self-clobber (the zimr534 hazard, exactly). → Fixed
   by dropping the seed entirely: `draw()` fully writes a slot before binding it,
   so the seed was dead anyway.

**Decision on the big options:** we did NOT do the full frame-wide arena (option B)
— the ring (option A) plus killing the dead seed made the launcher correct, and
the NAMING infrastructure means the next instance of this class self-identifies
instead of needing a fresh investigation. Option B (a single `FrameUniforms` bump
arena that ortho ring + pbr3d + `Resources.writeUbo` all route through) remains
the eventual "delete the rings entirely" cleanup, but is no longer urgent now that
(a) the known clobbers are fixed and (b) the gate catches new ones with a NAME.

**Gate coverage:** added `launcher` to the tier-a smoke set, so multi-model
compose + lazy-child-init-in-frame-0 (neither visible in a single-app smoke) is
now gated on every `zig build check`.
