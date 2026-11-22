# zimrnum_fit - draw a function, watch an MLP learn it, on the CPU or the GPU - the plan (v2, Nov 22 2026)

STATUS: FINAL (Nov 22) - every decision in section 5 agreed by Simon ("agree. Start"), D1-D4 his, D5-D13 Claude's after
his "I let you decide. I feel we should keep this as simple as possible". EVERY STAGE WRITTEN (S0-S4, Nov 22), and the
page in the launcher; BEING VERIFIED - what remains is the list below. Written under claude.md's "MAKE A PLAN"
procedure (claude.md:146). Every build and test is Simon's to run (his rule); every claim about the code was read and
is cited `file:line`. v1 and its revisions are summarised in the journal (section 7), which says how each item came
about.

WHAT REMAINS (Nov 22, after S4 - kept current here). No code is left to write unless a run asks for it: Simon's runs
first, then what they decide. Nothing is committed - Simon commits.

  1. THE PLAN's FULL GATE - Simon's runs, none of them made yet:
     a. `zbuild --complete test`: every quick test - `test-zimrnum-fit` (S2's job checks: the job against KitMlp bit
        for bit, K steps in one job against K jobs of one), ui.zig's `isItemActivated` test, plot's and plot_ui's
        log-axis tests, S1's kit tests, S0's jobs test.
     b. `zbuild --complete vk-host-test`: the device against the twin - S3b's hand-over check ("zimrnum_fit's network
        handed between the device and the twin, both ways, ...") and the kit's existing checks, `sgd`'s pipeline among
        them.
     c. Each new check SEEN TO FAIL ONCE (3.9), by the mutations the journal names: drop `beginFrameRaw`'s new line;
        swap relu and tanh in `networkSpec`; `.step_count = 0` in `trainSteps`' `putState`; `.step_count = 0` in
        vk_host_test's `fitStepsHandedOver`.
     d. The launcher, for the web (`zbuild --complete launcher -Dplatform=web -Dmode=release`) and natively, and
        `flagships-check`, which runs zimrnum_fit now (one of 36). On the phone: does the launcher still start
        comfortably, its main wasm and every worker now reserving the kit twin's ~21 MB?
     e. If tripwires notes `sgd`'s new WGSL in the corpus: `zbuild corpus-refresh`.
  2. THE GOALS NOT YET SEEN (section 0) - Simon's eyes, the speed log's numbers:
     G1  the starting sine fit under a loss of 1e-3 within ten seconds on the GPU at the default size. So far about
         3e-3 at eleven seconds natively, with flips in between: a clean run decides, and may ask for the default rate.
     G2  no jump at a flip: 1b's check, and the loss chart by eye.
     G4  60 fps on the GPU natively since the steering's fix: a new native speed log, its worst-frame column (now each
         second's worst) under 21 ms on the GPU, its steps a second still at least 10x the CPU's. In a browser the
         frame time cannot see the device: the orbiting dot, by eye, on the GPU.
     G6  a breakpoint in `dense_fwd_tiled`, `adam` or `sgd` under LLDB, natively, toggled to the CPU: it stops on the
         job's thread.
     G7  the S23 FE: draw, every control under a finger, the flip, the panel scrolling. Open since the first
         screenshot: were the sliders' labels cut at the window's right edge, or was that the crop?
  3. WHAT THE RUNS MAY ASK OF CLAUDE (S4b's rest): a fix to the phone's layout; the steering retuned from the next
     log; the default rate (G1); a wider default (3 x 128) only if the browser's 10x should have a margin. The default
     stays 3 x 64: G3 measured 25x natively and 10x in a browser.
  4. FOUND ALONG THE WAY, NOT THIS PLAN's: examples_catalog.md lacks five examples' rows and its counts are stale;
     `wgpu.nowMs`'s doc says "0 on native", which only the `none` host is.
  5. LATER, each on Simon's go: section 6's options.

THE ASK (Simon, Nov 22): a new zimrnum example that trains a simple MLP, visually, to predict a 1-D function. The user
draws the graph of y = f(x) with the mouse and watches an MLP approximate it, live. A toggle switches the learning from
the CPU to the GPU and back, and on the GPU it should visibly learn faster. A nice UI to tweak the algorithm, the
learning rate, the number of layers and of neurons, and so on. "Find the best way to do that."

ADDED DURING THE REVIEW (Simon, Nov 22):
  - "this should serve as a worker tutorial. On native is serves as a tutorial on how to use worker threads in zimr.
    We should keep it at 60fps, and train gradually and see the network learn as we are drawing with the mouse"
  - "Toggle only. It is expected that people will just see that cpu is slow, and then enable gpu instead and never look
    back. But then when inspecting the code, and following breakpoints, it will be fun to toggle back to cpu, to be
    able to go deep with the breakpoint and really understand what the kernels are doing"
  - "I let you decide. I feel we should keep this as simple as possible"

THE PAGE IN ONE PARAGRAPH. A curve on a plot - a sine to start - that you reshape by dragging. A small MLP trains on it
all the time, its own curve drawn over yours, following the pen. A switch puts the training on the CPU or on the GPU.
On the CPU the GPU's very kernels run, through their CPU twin, in a job - on a Web Worker in a browser, on a thread
natively - so the frame stays at 60 fps, and a breakpoint in a kernel stops right there; it is slow, and the readout
says how slow. On the GPU the same kernels run as WGSL or SPIR-V, many steps a frame. One checkbox runs the CPU's job on
the frame's own thread instead, to see the hitch the worker removes. The panel: SGD or Adam, the learning rate (and
SGD's momentum), the hidden layers, their width, relu or tanh, Reset.

WHAT WAS READ: `src/kit_mlp.zig` (its head, `KitLayerKind`, `KitNetwork`'s constructors, `forwardRows`, `backward` and
its dense path, `Spec`, `KitMlp` whole), `src/gpu/zn_mlp.zig` (its head, `Act`, `Params`, `activate`, `derivative`,
`dense_fwd`, `act_bwd`, `dense_bwd_x`, `dense_bwd_w`, `blockedProduct`, `mse_bwd`, `mse_value`, `adamStep`, `adam`),
`src/gpu/zn_mlp_kernels.zig`, `src/gpu/zn_mlp_sizes.zig` and `zn_mlp_sizes_trainer.zig`, `src/compute_host.zig`
(`Backend`, the worker adapter, timings, `MachineShare`, the `initGpu` family, `upload`/`uploadAt`, recording, `run`'s
kernel lookup and its backend arms, `readGeneration`, `requestRange`, `readLatest`), `src/jobs.zig` (its head, native
jobs, `runningLimit`, `Job`, `pollInto`, `parallel`, `Options`, `Registry`, `Group`), `build.zig` (`buildJobKernels`,
the web build's options, the compute apps' entries, the fast roots), `src/host.zig` (its kind), `src/kit_mlp_tests.zig`
(its reference and first tests), `src/robot_world.zig` (KitMlp's one caller), `src/zimrnum.zig` (`matmul` and
`matmulColumns`, `Mlp`, `Optimizer`, the optimiser steps, the Graph's `matmul` and activations), `examples/zimrnum_train`
(all), `examples/cartpole_duel` (its budgets), `examples/compute_particles` (its flip), `examples/four_ways`,
`examples/worker_png` and `examples/rt_workers` (their heads and kernels), `examples/ui_plot` (all), the pointer in
`examples/textures_mouse_painting`, `src/plot_ui.zig` (`PlotState`, `show`), `src/ui.zig` (`slider` and `SliderOpts`,
`plotCurves`, `combo`, `checkbox`, `scaleToViewport`, `isNarrow`, `wantCaptureMouse`), `src/notes/zn_mlp_web_twin_plan.md`
(its goal and section 1), and the claude.md rules cited below.


## 0. The goals, stated so they can fail

  G1 DRAW, AND SEE IT LEARN. A stroke changes the targets on the frame it is drawn. At the default size on the GPU the
     network's curve visibly moves toward a new stroke within a second, and the starting sine is fit to a mean
     squared error under 1e-3 (bar set on the first runs) in under ten seconds on Simon's desktop.
  G2 THE TOGGLE IS SEAMLESS. Flipping CPU <-> GPU mid-run carries the weights, the optimiser's state and its step count
     across - one layout on both machines, the kit's - and the loss curve shows no jump at a flip: both machines run the
     same kernels, the same sums in the same order, so they agree to rounding.
  G3 THE SPEED IS MEASURED, NOT CLAIMED. Steps per second for the machine training, counted only once its steps have
     landed (the GPU's by its readback, the CPU's by its job). At the default size the GPU is at least 10x the CPU on
     the desktop.
  G4 60 FRAMES A SECOND (Simon). No training step runs on the frame's thread - except while the inline checkbox is on,
     which exists to show exactly that. The frame time is on screen and stays under 17 ms on the desktop.
  G5 IT TEACHES WORKERS (Simon). The page's job is the reference for zimr's jobs API: a kernel as a pure function, a
     header and a payload, submit, poll into a buffer owned once, take, one job in flight, the state shipped each way -
     and the same code on Web Workers and on native threads. One readout line shows it working: the job's length, the
     worker's busy share, the frame time, and whether real workers exist or jobs run inline.
  G6 THE CPU IS WHERE THE KERNELS ARE READ (Simon). Toggled to the CPU, a breakpoint in `dense_fwd_tiled`, `adam` or
     `sgd` (zn_mlp.zig) stops there - natively under LLDB, on the job's thread - in the exact code the GPU runs.
  G7 IT WORKS UNDER A FINGER on the S23 FE: draw, tap every control; the panel sized by `scaleToViewport`.
  G8 EVERY ADDITION HAS A HEADLESS CHECK on the CPU twin against zimrnum's own steps, over WARM steps (claude.md:1698),
     each seen to fail once by its own failure line; the engine changes by the pages that already use jobs.


## 1. What exists - verified in the code

### 1.1 The GPU learning kit already trains an ordinary MLP, on a device or on its CPU twin

- `KitMlp(M)` (kit_mlp.zig:1261) is "an ordinary multilayer perceptron with its own pipe and batch": a `Spec`
  (kit_mlp.zig:1229 - inputs, hidden widths, outputs, relu or tanh, rows, Adam's settings, seed), He or Xavier
  initialisation (1321), `forward` (1397) and `trainStep` (1431): forward, `mse_value`, `mse_bwd`, backward, `adam`,
  one recorded submission, only the loss read back. Its dense path dispatches `dense_fwd_tiled`, `act_bwd`,
  `dense_bwd_w_tiled` and `dense_bwd_x_tiled` (kit_mlp.zig:981, 1063-1166).
- The kernels (`zn_mlp.zig`) are ONE source for both machines: `compute_host.Compute(M)` runs them as WGSL or SPIR-V on
  a device, or as a plain loop on the host (compute_host.zig:1-16). `kit_mlp_tests.zig:63` holds KitMlp's forward to a
  plain-Zig reference within 1e-6, and the next test one Adam step to its formula.
- Optimisers on the kit: `adam` (zn_mlp.zig:1101), plus clipped Adam and Muon. **No SGD kernel exists.** A dense layer's
  activation is relu or tanh (`Act`, zn_mlp.zig:68).
- The page sizes (zn_mlp_sizes.zig): activations 2^21 floats, their gradients 2^20, each parameter buffer 2^18 -
  262,144 weights. `KitLayout.checkFitsKit` (kit_mlp.zig:234) says whether a layout fits; `requireFitsKit` (250)
  asserts it - so the UI asks first.

### 1.2 What KitMlp does not do yet

- One step per submission, its batch uploaded again on every step (kit_mlp.zig:1445-1446). A page wants many steps in
  one recording over a batch that changes only when the drawing does.
- No way to hand its state - weights, Adam's two moments, the step count - to another pipe or to a job.
- `forward` reads back through `readLatest`: a frame late on a device, and it widens EVERY buffer's readback.

### 1.3 The compute host

- `Backend` (compute_host.zig:77): `.cpu` runs a kernel as a loop on the host and BLOCKS the thread; `.worker` runs the
  same loop in a Web Worker but copies the whole `Buffers` there and back on every dispatch (61-75) - the kit's are
  17 MB, so not for training; `.gpu` is asynchronous.
- RECORDING (1705-1721): every `run` between `beginRecording` and `submitRecording` goes into one submission, each
  dispatch with its own params slot; 2,048 slots, then it submits and carries on (1703). An upload issued
  mid-recording lands before the WHOLE recording, so a batch is uploaded before it begins.
- `requestRange` (2838) copies a range of one field into a staging buffer of its own after every dispatch so far,
  collected a frame later on the web; on the twin it is a snapshot. The curve is N floats of the activations.
- A GPU pipe may be made from a SUBSET of a module's kernels: `run` finds its kernel by name among those registered
  (2422-2433). `initGpuInBackground` (1082) makes the pipelines off the page's thread; `pipelineProgress` says when.
- A `.gpu` pipe's `upload` and `uploadAt` write the device's buffer only, never the twin's globals (1611-1616).
- Compute timestamps are native only (`enableTimings`, 2059): speed is wall time over completed steps.

### 1.4 Budgeting the GPU - solved once already

`cartpole_duel` issues a GPU batch only once the last one is BACK - `readGeneration().mirrored` past the generation
recorded after it - so at most one batch is in flight and the queue never floods; on a phone a flooded queue stalls the
compositor (cartpole_duel.zig:108-121, 719-757). Its lesson: poll the readback every frame, first, or the gate
deadlocks; the smoke runner's GPU stub reports generation 0/0 and cannot see it (730-738).

### 1.5 The UI, the plot and the pointer

- `z.plot_ui.show` (plot_ui.zig:1088): axes, ticks, line series of f64 (302-307), pan and zoom unless `.interactive =
  false` (370); `PlotState.pixelsToPlot` and `getPlotMousePos` (218, 228) put the pointer in data space.
- `ui.plotCurves` (ui.zig:16678): learning curves on one frame, y linear or logarithmic - the loss.
- `slider` (ui.zig:16614) has no logarithmic scale (`SliderOpts`, 10635): the learning rate slides over its exponent.
  `combo` (17596), `checkbox` (16599), `scaleToViewport` and `isNarrow` (17251, 17270), `wantCaptureMouse` (17360).
- The pointer: `z.getMousePosition(f.input)`, `z.isMouseButtonDown` (textures_mouse_painting.zig:59, 76); a finger
  arrives as the same pointer, and a stroke anchors on its press frame (claude.md:2455).

### 1.6 Workers: zimr's jobs

- ONE API, TWO WORLDS (jobs.zig:1-90). A kernel is a pure function `fn (gpa, header, payload, out: *Io.Writer) !void`,
  driven by `submit`, `poll` and `take`. In a browser it runs on a Web Worker, in a separate wasm instance with its own
  memory; natively on threads of the program's own (jobs.zig:112-140: a `std.Io.Threaded`, at most min(cores - 1, 4)
  jobs at once, 233-245); in a sandboxed iframe inline. The browser's pool takes half the cores, at most four
  (bridge.zig:4708-4720). `parallel()` says whether real workers exist (694).
- A KERNEL's WASM IMPORTS NOTHING, and the build asserts it (worker_png/kernels.zig:1-23). It is built freestanding
  with three modules, `zimr`, `kompute` and `zm` (build.zig:1832-1910), under the web build's options, which name no
  host (5019-5022) - so `host.zig` picks `.web` for any wasm (host.zig:33-46) and compute_host's eight `.gpu` arms are
  compiled in (compute_host.zig:1611, 1666, 2406, 2573, 2658, 2703, 2873, 2950; four other places already gate on
  `host.has_gpu`: 1936, 2206, 2244, 2292). So TODAY a kernel cannot hold a `.cpu` `Compute(M)`.
- Natively, a registry whose kernels work in their module's globals - the kit's do, in `M.g.B` - runs INLINE, never
  on a thread, because a thread would share the globals with the app's frame (`kernels_work_in_globals`,
  jobs.zig:705-712).
- With no imports a kernel has NO CLOCK: a job runs a fixed number of steps, and the page times it.
- JOBS ARE STATELESS: a job carries its inputs in and its result out; the page holds the state between jobs.
- COLLECT INTO A BUFFER OWNED ONCE: `pollInto` (jobs.zig:510-531) - an allocating `poll` of a 2.7 MB result cost 154 ms
  on a phone, nine times the work it collected.
- PRECEDENTS: `worker_png` (one job, a spinning dot that exposed a 95 ms stall), `rt_workers` (`Group`, and the
  identical kernel run inline for contrast: "the dot stops dead", rt_workers.zig:1-23), `four_ways`.

### 1.7 zimrnum

`sgdStep` (zimrnum.zig:6985), `sgdMomentum` (11043: velocity = momentum x velocity + gradient, then w -= rate x
velocity) and `adamStep` (11141) are the oracles a new kernel is held to. zimrnum's Graph (11753) would be another CPU
implementation of the same math - its `matmul` (11914) sums with Neumaier compensation (5714) - which is why D2 did not
put it on the page.


## 2. The decisions - what was considered, and what was picked

  D1  THE COMPUTE CORE. Considered: the kit extended additively; the kit as it is (Adam only - no SGD against Adam); a
      kernel module of the page's own, as `zn_train` is for XOR (any activation, but a second definition of a dense
      layer free to drift from the kit's). PICKED (Simon): the kit, extended - and per "as simple as possible" (Claude)
      by ONE kernel, `sgd` with momentum, not the five of v1.
  D2  WHAT "CPU" MEANS. Considered: the kit's CPU twin; zimrnum's Graph; both. Simon first picked both, after asking
      what "the Graph's slower matmul flatters the GPU" meant - an arithmetic count, it turned out, not a measurement
      (zimrnum's compensated sums do about five times a plain sum's arithmetic but are CPU-shaped code; the twin is
      GPU-shaped code doing plain sums; which is faster on a CPU is unmeasured). D3 then ruled the twin out as a
      frame-thread machine, and D4's breakpoints ruled the Graph out as the thing to step through. PICKED (Simon): THE
      GPU's OWN KERNELS - the kit's twin, in a job - after the engine work that allows it (3.2); the same job run
      inline as a contrast. zimrnum's Graph is not on the page.
  D3  WHERE THE CPU TRAINS. Considered: the frame's thread, budgeted; one worker; several workers splitting the batch.
      PICKED (Simon): jobs - a Web Worker in a browser, a thread natively - one job in flight.
  D4  A TOGGLE OR A RACE. PICKED (Simon): the toggle only.
  D5  THE DRAWING. Considered: a fixed grid painted with an undrawn mask (extrapolation on show), erase and noise; a
      free point cloud; spline handles. PICKED (Claude, simplest): a fixed grid whose targets you RESHAPE by dragging -
      every sample always has a target, so there is no mask, no erase and no noise. It starts as a sine; Clear makes it
      flat, Sine restores it.
  D6  THE BATCH. PICKED (Claude): the whole grid, every step - full-batch gradient descent - and the last forward's
      outputs ARE the curve drawn: one range readback, no extra pass.
  D7  THE ALGORITHMS. Considered: SGD, momentum, Nesterov, RMSprop, Adam, and the kit's clipped Adam and Muon. PICKED
      (Claude): SGD (momentum slider, 0 is plain SGD) and Adam; the learning rate on a log slider.
  D8  THE NETWORK's KNOBS. Considered: per-layer widths, eight activations, an input encoding. PICKED (Claude): hidden
      layers 1-4 of one width (4-256), relu or tanh, Reset (from a fixed seed). A shape change rebuilds; a shape that
      does not fit the kit is refused with its numbers.
  D9  WHAT THE PAGE SHOWS. PICKED (Claude): your curve and the network's; one readout line (step, loss, steps/s); one
      worker line (G5); the loss on a log scale against seconds, coloured by machine - its slope changes at a flip.
  D10 THE SPEED STORY. Considered: size presets including one where the CPU wins. PICKED (Claude): no presets - one
      default size where the GPU is clearly ahead (measured at S4, G3) and the width slider to explore; one line under
      the readout says why (a GPU pays per dispatch, a CPU per multiplication).
  D11 NAME AND PLACE. PICKED (Claude): `examples/zimrnum_fit/`, in the family of zimrnum_hello, _field and _train; a
      gallery card and a catalog row.
  D12 WORKER LESSONS. Considered: a job-length slider, a transfer readout, a pool readout, `Group` fan-out. PICKED
      (Claude): only the job chain and the inline contrast, with the one worker line of G5. (`Group` would also
      mislead natively: twin jobs share the program's globals, so they could only run one after another.)
  D13 A WRITTEN TUTORIAL. PICKED (Claude): the example's own comments are the tutorial, in worker_png's and rt_workers'
      style; no separate page for now.


## 3. The design

### 3.1 Files

    src/compute_host.zig                     its `.gpu` arms compiled only where there is a GPU (S0)
    src/jobs.zig                             a globals registry may run natively on ONE thread at a time (S0)
    build.zig                                kernel wasms built with no host, given `zn` and `zn_mlp` (S0); the app
                                             entry, with the eight kernels it runs (S2, S3)
    src/gpu/zn_mlp.zig                       + the `sgd` kernel (S1)
    src/gpu/zn_mlp_kernels.zig               + "sgd" (S1)
    src/kit_mlp.zig                          KitMlp grown (S1, 3.3)
    src/kit_mlp_tests.zig                    its checks (S1)
    examples/zimrnum_fit/kernels.zig         the job (S2, 3.4)
    examples/zimrnum_fit/sketch.zig          the drawing, pure functions (S2, 3.7)
    examples/zimrnum_fit/zimrnum_fit.zig     the page (S2, S3)
    src/web/manifest.json, src/notes/examples_catalog.md, src/web/readme.html     card, row, mention (S4)

### 3.2 The engine (S0) - so the GPU's kernels can train in a job

  E1  KERNEL WASMS WITH NO HOST. `buildJobKernels` gives the kernel's engine `host = "none"`. FOUND AT S0 (Nov 22):
      compute_host itself needs no change - every wgpu wrapper it calls already returns at once where there is no GPU
      (`if (comptime !host.has_gpu)`, wgpu.zig - the `none` host's design, host.zig:9), and its timestamp helpers gate
      the same way. What DID need a gate is `web.jobs`, which chose its externs by architecture (`is_wasm`): a twin's
      `.worker` arms reach it from inside a kernel, so it now asks `host.is_browser`. The other host reads a kernel
      can reach - `host.heap` (by architecture, still the wasm allocator), jobs' `has_job_threads`, goban's frame-loop
      checks - are unchanged or unreached.
  E2  ONE THREAD FOR A GLOBALS JOB, NATIVELY. A third choice beside today's two for `kernels_work_in_globals`
      (jobs.zig:705-712): run such jobs on a thread, ONE AT A TIME, the app promising not to dispatch on a `.cpu` pipe
      of that module while one runs. This page keeps the promise by construction - its frame thread drives only a GPU
      pipe, which never writes the twin's globals (1.3), and the inline contrast runs only with no job in flight. The
      option's name and shape, and whether compute_host can assert the promise cheaply, are settled at S0.
  E3  THE KERNEL WASM's MODULES: `zn` (kit_mlp needs it) and `zn_mlp`, beside `zimr`, `kompute` and `zm`.

### 3.3 The kit (S1)

    KitMlp
      Spec.optimizer        union: adam (the default - today's behaviour), sgd { momentum }
      setBatch(inputs, targets)   uploaded once, before a recording; again only when the drawing changes
      trainSteps(count)     `count` steps - forward, mse_bwd, backward, the optimiser - in ONE recording, nothing read
                            back. `trainStep` becomes setBatch + trainSteps(1) + its loss read: one step's code.
      requestOutputs(gpa)   the last forward's N outputs as a range request: the curve
      requestState(gpa), takeState, putState
                            the weights, both moment buffers (SGD's velocity lives in `adam_m`) and the step count
      fits(spec)            the size check, asked before a rebuild

    zn_mlp: `sgd`, one thread per parameter: velocity = momentum x velocity + gradient, w -= rate x velocity -
    zimrnum's form (1.7) - the velocity in `adam_m` (laid out like the parameters already), the momentum read from
    `beta1`, so `Params` and every kit kernel's uniform stay as they are. Momentum 0 is plain SGD, exactly.

### 3.4 The job (S2)

    examples/zimrnum_fit/kernels.zig   compiled twice, as worker_png's is: into the app (the header's type) and into
                                       the kernel wasm
    trainSteps(gpa, header, payload, out)
      header    extern: the step count K; the shape (layers, width, relu or tanh); the optimiser, rate, momentum and
                Adam's numbers; the steps taken so far (Adam's bias corrections); N
      payload   the weights | adam_m | adam_v in the kit's layout, then the N inputs and the N targets
      out       the weights | adam_m | adam_v after K steps, then the curve (the last forward's N outputs)
      body      a `.cpu` pipe over the twin's buffers - in a browser the worker's own, natively the program's, lent to
                this one job (E2) - a KitMlp with the header's spec, putState, setBatch, trainSteps(K), the regions
                written out. A breakpoint in any kit kernel stops here, on the job's thread (G6).
    registry  `jobs.Registry(.{ .{ "trainSteps", trainSteps } }, ...)`, its bounds the largest network the kit holds
              (3 x 262,144 floats each way, under 4 MB); its globals choice E2's.

At the default size a job ships about 100 KB each way (3 x ~8,500 weights of 1 -> 3 x 64 -> 1).

### 3.5 The frame

  CPU (the job chain)
    1. Poll the job into the buffer owned once. When it lands: its state is the state, its curve is drawn, the loss is
       computed on the host from N outputs and N targets, the steps advance by K, its time is noted.
    2. With nothing in flight: submit the next job with the state and the drawing AS IT IS NOW - so a stroke reaches
       the training within a job. K is steered so that a job lasts about two frames: doubled when one lands within a
       frame, halved past four, never below one.
    INLINE: the same call on this thread instead of a submit - the same bytes in and out.
  GPU (batches)
    1. Poll the curve's range request first (1.4). When it lands: the curve, the loss on the host, the steps by K.
    2. With nothing in flight: setBatch if the drawing changed, record K steps, submit, request the curve. K doubles
       while a batch comes back within a frame and the frame is on time, halves when late, and is capped by the
       recording ring (2,048 slots / dispatches a step).
  BOTH: one loss point per landing, the readout, the UI. Under the smoke runner the jobs run inline and the GPU stub
  never delivers a readback: the CPU path must train headlessly, and the GPU path must not wait forever.

### 3.6 The toggle

  GPU -> CPU   requestState; when it lands, it is the next job's state.
  CPU -> GPU   wait for the job in flight to land (about two frames at most), then putState on the GPU pipe, setBatch.

The step count, the loss history and the drawing carry on. The page starts on the CPU at once - a job needs no
pipelines - and the GPU button is enabled once the GPU pipe's eight pipelines are ready (`initGpuInBackground`).

### 3.7 The drawing (sketch.zig, pure functions)

  grid      N = 512 x values, evenly over [-1, 1], each with a target y (a sine at first)
  paint     from the pointer's x and y last frame to this frame's: every sample between gets the straight line's y, so
            a fast stroke leaves no gap; a stroke starts on its press frame (claude.md:2455); y clamped to the plot
  Clear     every target 0           Sine     the starting curve again
  Any change marks the drawing dirty; the next job or batch carries it.

### 3.8 The panel and the layout

Desktop: the plot on the left two-thirds, the panel on the right, the loss under the plot. Narrow (`isNarrow`): the
plot on top, the panel under it. The plot is not interactive (no pan or zoom): dragging in it draws.

    Machine     (o) CPU  ( ) GPU        GPU: "preparing kernels 5/8" until ready
                [ ] run the CPU job on this thread (see the hitch)
                Run / Pause    Reset
    Algorithm   SGD | Adam     learning rate (log)     momentum (SGD)
    Network     hidden layers 1-4     width 4-256     relu | tanh          a change rebuilds from the seed
    Drawing     Clear    Sine
    Readout     step 1,234    loss 3.2e-4    2,900 steps/s
                frame 16.6 ms    CPU job 31 ms, 20 steps, worker busy 66%    4 worker threads | inline
    Loss        against seconds, log y, coloured by machine

### 3.9 The checks

  S0  a kernel wasm holding a `.cpu` `Compute(zn_mlp)` builds with ZERO imports (the build's own assertion); the five
      pages that use jobs (worker_png, rt_workers, four_ways, goban, launcher) rebuilt and run; natively, a one-thread
      globals job lands while its caller keeps going, and a second waits for the first (a jobs test).
  S1  `sgd` against zimrnum's `sgdMomentum` over five warm steps from a non-zero velocity, and momentum 0 against
      `sgdStep`; a KitMlp with `.sgd` stepping every weight and its velocity as zimrnum's `sgdMomentum` does, three
      steps; a state taken out, the twin's buffers poisoned with NaN (claude.md:854), put back - the run goes on bit for
      bit as if never interrupted; the existing kit tests. (DROPPED at S1, Nov 22: "`trainSteps(k)` equal to k
      `trainStep`s" - on the twin `beginRecording` and `submitRecording` do nothing, so both sides run the identical
      calls and the check could not fail, claude.md's self-referential check. The recording is a DEVICE property: S4's
      toggle, the loss continuous across a flip, is where it is seen.)
  S2  the job called as a plain function equal to KitMlp on the twin, bit for bit; one job of K steps equal to K jobs
      of one; the page's smoke test.
  Every check seen to fail once, by the test's own failure line.


## 4. Stages - each one small turn, each on Simon's go

  S0  THE ENGINE (3.2). Nothing of the page yet.
  S1  THE KIT (3.3): KitMlp grown and the `sgd` kernel, one gate: the kit's tests, `vk-host-test` (the device against
      the twin), the robot learners' kit steps (claude.md, "WHICH STEPS A ROBOTGPU CHANGE NEEDS"), the corpus refresh
      for zn_mlp's new kernel.
  S2  THE JOB AND THE PAGE ON THE CPU (3.4, 3.5's CPU half, 3.7, 3.8 without the GPU): the tutorial half. Simon runs it
      in a browser and natively - 60 fps while it trains - and steps a kernel under LLDB (G6).
  S3  THE GPU AND THE TOGGLE (3.5's GPU half, 3.6), on the desktop and the phone.
  S4  POLISH: the default size measured (G3), the phone layout, the card, the catalog row, the readme's mention.

The commands for each stage's gate are written into the stage when it starts - the step names checked against build.zig
then, not guessed now. Every build and test is Simon's to run.


## 5. Decisions - for Simon's agreement

| #   | Decision            | Pick                                                                                    | By     |
|-----|---------------------|-----------------------------------------------------------------------------------------|--------|
| D1  | compute core        | the kit, extended by one kernel: `sgd` with momentum                                     | Simon (the one kernel: Claude) |
| D2  | what "CPU" means    | the GPU's own kernels: the kit's twin in a job, after S0; the same job inline as contrast | Simon  |
| D3  | where the CPU trains | jobs: a Web Worker in a browser, a thread natively; one in flight                       | Simon  |
| D4  | toggle or race      | toggle only                                                                              | Simon  |
| D5  | the drawing         | a 512-sample grid reshaped by dragging; starts as a sine; Clear, Sine; no mask           | Claude |
| D6  | the batch           | the whole grid every step; its outputs are the drawn curve                               | Claude |
| D7  | the algorithms      | SGD (momentum) and Adam; log learning rate                                               | Claude |
| D8  | the network         | 1-4 hidden layers of one width 4-256, relu or tanh, Reset                                | Claude |
| D9  | what it shows       | both curves; step, loss, steps/s; the worker line; loss over seconds by machine          | Claude |
| D10 | the speed story     | one measured default size, the width slider, one line of why; no presets                 | Claude |
| D11 | name and place      | examples/zimrnum_fit; gallery card; catalog row                                          | Claude |
| D12 | worker lessons      | the job chain and the inline contrast; one worker line                                   | Claude |
| D13 | written tutorial    | the example's own comments; no separate page for now                                     | Claude |


## 6. Left out on purpose - each a later option, on its own go

An in-page Verify (the GPU against the twin; `zn_mlp_web_twin_plan.md`'s page covers WGSL against the twin), an
undrawn mask and extrapolation, erase, noise, an input encoding (sine/cosine octaves), more activations (leaky relu, ELU,
softplus, sigmoid; SiLU, GELU and sin need the pre-activation kept), RMSprop, Nesterov, AdamW, clipping and Muon on the
menu, size presets, the hidden units' curves, `Group` fan-out, a job-length slider, a race, a written tutorial page.


## 7. Journal

- Nov 22 - v1 draft: the kit extended by five kernels; the CPU as the kit's twin on the frame's thread, budgeted; a
  painted grid with an undrawn mask; eight activations, four optimisers, presets, a Verify button.
- Nov 22 - D1 decided by Simon: the kit, extended.
- Nov 22 - D2: Simon asked what "the Graph's slower matmul flatters the GPU" meant. Read `matmulColumns` and
  `blockedProduct`: an arithmetic count, not a measurement, and the flip cost was overstated. Decided: both CPU paths.
- Nov 22 - Simon: the page is also a WORKER TUTORIAL at 60 fps, learning while drawing. Read jobs.zig, the kernel
  wasm's build, worker_png and rt_workers. D3 decided: jobs. The twin can be neither a job (without engine work) nor a
  frame-thread machine at 60 fps: D2 decided again - a zimrnum Graph job, the GPU, and the job inline as a contrast.
- Nov 22 - D4 decided by Simon: toggle only, the CPU kept for stepping through the kernels with breakpoints. D2 decided
  a third time: the GPU's own kernels, the kit's twin in a job, after engine work (S0). Checked that a GPU pipe never
  writes the twin's globals (compute_host.zig:1611-1616).
- Nov 22 - Simon: "I let you decide ... as simple as possible." Claude decided D5-D13, cutting v1's mask, erase, noise,
  encoding, extra activations and optimisers, presets and Verify (section 6); one kernel instead of five. Rewritten as
  v2. Awaiting Simon's agreement with section 5.
- Nov 22 - Simon: "agree. Start". The plan is FINAL; S0 begun.
- Nov 22 - S0, written (NOT BUILT - Simon's runs): E1 as found (3.2): build.zig's `build_opts_kernel` (the web's
  options plus `host = "none"`), passed to `buildJobKernels` by its three callers (the AppContext field renamed from
  `build_opts_wgpu`, whose only use it was); web.zig's `jobs` asks `host.is_browser`. E2: jobs.zig's `Globals` enum
  (`untouched`, `shared_with_the_app`, `lent_to_one_job`) replaces `Options.kernels_work_in_globals`; native slots
  carry `works_in_lent_globals`, `oldestStartable` never starts a second lent job while one runs; komputeRegistry now
  says `.shared_with_the_app`; test "jobs: natively, jobs in lent globals run on a thread, one at a time" (its
  control: two free jobs overlap where the pool runs two). E3: the kernel wasm's engine gets `zn`, and every kernels
  module `zn` and `zn_mlp`. zig fmt, ast-check and zimrlint (all 60 rules, baseline; proven live on a plant) clean.
  LEFT IN S0: the probe - a kernel wasm holding a `.cpu` `Compute(zn_mlp)` - which proves E1 and E3.
- Nov 22 - S0's PROBE written (NOT BUILT): `examples/zimrnum_fit/kernels.zig` - `trainProbe`, a KitMlp of two tanh
  layers of 32 on a `.cpu` pipe, Adam on a sine over 256 samples for 25 steps, its first and last loss sent back; the
  registry `.globals = .lent_to_one_job` - and `zimrnum_fit.zig`, a job chain (one in flight, `pollInto` a buffer
  owned once, a new seed each job) drawing the loss, where jobs run, and the worst frame gap beside worker_png's
  orbiting dot. The build entry (`job_kernels`, and `compute_kernels` with zn_mlp's seven existing kernels for S4) and
  a gallery card: `checkGalleryCatalog` (build.zig) stops the configure step for an app without one, so the card the
  plan put at S4 came now. fmt, ast-check, zimrlint (all rules) clean. Noticed meanwhile: someone else is changing the
  kit (`zn_mlp_sizes.zig` gained `ring_len`) - S1 touches kit_mlp.zig and zn_mlp.zig, so it waits for that work to
  settle or is coordinated with it.
- Nov 22 - Simon: "Yes, S1 next" (S0 still unbuilt; the kit's other writer idle since 13:21). S1, FIRST HALF, written
  (NOT BUILT): zn_mlp's `sgd` kernel (beside `adam`; velocity in `adam_m`, momentum in `beta1`) and "sgd" appended to
  zn_mlp_kernels.zig - the end, so no kernel's index moves under the other work; kit_mlp.zig's `MlpOptimizer` (`adam`,
  `sgd { momentum }`) and `Spec.optimizer`; KitMlp's `setBatch`, `trainSteps(count)` (one recording), `recordStep` and
  `recordOptimizerStep`, with `trainStep` now setBatch + trainSteps(1) + the loss read (the same calls in the same
  order as before). Tests: gpu_learn_tests "the kit's SGD is zimrnum's sgdMomentum over five warm steps, and plain SGD
  at momentum 0"; kit_mlp_tests "an SGD network steps every weight as zimrnum's sgdMomentum does, step after step".
  Simon's lint-fix found one 121-column line of the kernel's doc; fixed. fmt, ast-check, zimrlint (a newer binary,
  proven live on a plant) clean. LEFT IN S1: `requestOutputs`, the training state out and in, and its round-trip test.
- Nov 22 - Simon asked whether a red `zig build test` was this work or the other writer's: the other's (its
  uncommitted RecordRing rewires the resident trainer's window staging, which the failing robot_track_resident test
  checks; the `joint_positions[0]: world 1 ..., world 2 ...` line is robotgpu_tests' `expectWorldsIdentical`, robotgpu
  uncommitted since 10:32) - judged by what each test reaches and by file times, not by a rerun.
- Nov 22 - S1, SECOND HALF, written (NOT BUILT): kit_mlp.zig's file-level `TrainingState` (weights, both moment
  buffers, step count); in KitMlp `Pipe` (= `Network.Pipe`, as KitFlow has it), `requestOutputs` (the last forward's
  outputs as a range request), `StateRequest` (one range request per buffer, each landing as it arrives; `collect`,
  `discard`), `requestState` and `putState`. Tests in kit_mlp_tests.zig: "a training state taken out and put back goes
  on as if never interrupted, bit for bit" (Adam and SGD; the resumed network from another seed, its working buffers
  poisoned with NaN) and "the outputs a step leaves are the network's on the weights before it" (against the file's
  plain-Zig Reference, and the weights must have moved). fmt, ast-check, zimrlint clean. S1 IS WRITTEN. `fits(spec)`
  is DEFERRED to S2, where the network knobs need it - sharing `init`'s layout code rather than restating it.
- Nov 22 - Simon: "Start S2". S2 split in three turns, each leaving the page building: S2a the job and a job chain
  with text readouts; S2b the plot and drawing with the pointer; S2c the panel. S2a WRITTEN (NOT BUILT):
    - `sketch.zig`: `sample_count` 512, `sampleX` (the one grid, the page's and the job's), `Sketch` (targets,
      version; `sine`, `drawSine`, `clear`, `paintSegment` - every sample between two pointer positions on the line).
    - `fits` came back at once: D8's largest shape, 4 x 256 over 512 samples, needs 1,050,112 floats of activation
      gradients against the pages' 1,048,576 (a dense layer reserves a gradient for its outputs and its inputs). So
      kit_mlp.zig's KitMlp gained `place` - init's placement, now shared - and `fits(gpa, spec)`, answering with
      `checkFitsKit`'s buffer name; kit_mlp_tests "fits names the buffer a network would overflow, where init would
      assert" (2 x 512: the parameters; 4 x 256 over 512: the gradients; 3 x 64 fits).
    - `kernels.zig`: the probe replaced by `trainSteps` - header `TrainHeader` (steps, shape, optimiser, rate,
      momentum, `starts_fresh`, seed, steps taken); payload the state (unless fresh) then the targets; result a
      `TrainResultHead` (steps taken, parameter count, loss), the state, the curve. `fits` first, so a shape too big is
      an error name, not a trap in a worker. Bounds: the largest state the kit holds.
    - `zimrnum_fit.zig`: the chain - poll into a buffer owned once, take the state and curve, submit the next with the
      drawing as it is now; steps per job steered to about two frames (doubled under one, halved past four); steps a
      second; three samples' drawing against network; the worst frame gap beside the dot.
  DEPARTURE: the worker's "busy share" (G5) is not shown - a kernel has no clock, so it cannot be measured honestly;
  the job's own steps and time stand in for it.
- Nov 22 - Simon: "Start S2b". S2b WRITTEN (NOT BUILT), all in zimrnum_fit.zig: a UiHost; `pageLayout` (plot and
  panel side by side, the plot over the panel when `isNarrow`; the panel's text scaled by `scaleToViewport`); the
  plot window (no title, no move) with `plot_ui.show` NOT interactive - the view held at x in [-1, 1], y within the
  targets' range - showing the drawing and, once a job has landed, the network's curve; `drawWithThePointer`, right
  after the plot: `isItemActivated` starts a stroke where the pointer IS (anchored on the press frame), `isItemActive`
  continues it from the last frame's point (`Sketch.paintSegment`). Read before relying on it: `plot_ui.show`'s one
  item is its invisible button, every other Ui call in it a query, so after it the plot's hit target is the last item;
  and its query snapshot (`getPlotMousePos`) is written whether or not it is interactive. The panel: the readout, Clear
  and Sine, and the orbiting dot drawn in the panel's draw list (UI windows now cover the frame's own drawing).
- Nov 22 - Simon: "Start S2c". S2c WRITTEN (NOT BUILT):
    - `kernels.zig`: `shapeIsOffered`, `networkSpec` (a header's network as the kit's `Spec`, built in one place) and
      `fitsTheKit` - the page's "does it fit", asked of the very network the job builds (`ShapeOutOfRange` for a
      shape the page does not offer). `trainSteps` uses the same two.
    - `zimrnum_fit.zig`, the panel in 3.8's order: Machine (where the training runs; the box "run on this thread";
      Pause / Run; Reset), Algorithm (Adam or SGD; the rate on a slider over its log10, -5 to -0.5, the rate itself
      shown under it; SGD's momentum, disabled under Adam), Network (hidden layers 1-4, width 4-256, relu or tanh),
      Drawing (Clear, Sine), then the Readout and the dot.
    - THE PANEL's CHANGES WAIT FOR THE NEXT SUBMIT, since a job may be in flight, and are made to the state the last
      job sent back: a new shape or Reset starts the network afresh from the seed (`fresh_start_due`); a new optimiser
      keeps the weights and zeroes both moments and the step count (`moments_reset_due`) - Adam's moments mean nothing
      as SGD's velocity, nor the velocity as Adam's moments. The rate and momentum go out with the next header. A
      shape is taken only when `fitsTheKit` passes; a refused one leaves the shape as it was and names the error.
    - THE INLINE CONTRAST, `runJobHere`: the kernel called as a plain function on the frame's thread, with an arena
      and a fixed writer over the page's result buffer - what jobs itself does inline (jobs.zig:1259-1263) - and the
      result taken by the same `takeResult`. A job is now timed by `wgpu.nowMs`, submit to landing, so an inline job
      is timed within its frame (natively `nowMs` is the monotonic clock: its doc's "0 on native" is stale). Under the
      smoke runner that clock steps 16 ms a call (webtests/runner.mjs:392), so the steps per job stay at one there.
    - "step" counts the steps since the network last started afresh; "a job" is the last landed job's steps and time.
      The window 1200 x 720 (was 640), the wide panel up to 460 px and 28 characters (was 440 and 26), the narrow plot
      45% of the height (was half): room for the panel's new rows.
    - DEPARTURES: a refused shape is named by the kit's error (`KitGradientsTooSmall`, ...), not by its numbers (D8):
      the numbers would need `fits` to return its layout. The box reads "run on this thread", not 3.8's longer label:
      the panel is about 28 characters wide, and the line above it says where the training runs and, ticked, that the
      frame waits for every step.
    - Checked against the sources, not compiled: every Ui, plot_ui, jobs, wgpu and std call (a slider reserves its
      label's whole width, so no label is cut; `Job.pollInto` of an idle job returns null). This compiler spells
      `@intFromEnum` as `@backingInt` and `@enumFromInt` as `@fromBackingInt` (fmt rewrote the page's two). fmt,
      ast-check and zimrlint (60 rules; a planted copy seen to fail) clean.
    - LEFT FOR S2d, which ends S2: 3.9's S2 checks - the job called as a plain function equal to KitMlp on the twin,
      bit for bit, and one job of K steps equal to K jobs of one (an example's `test` blocks only typecheck today, so
      they need a test root of their own) - and 3.8's loss row (one point per landing, log y, against seconds).
- Nov 22 - Simon: "Start S2d". While it was written, Simon ran S2c natively (Debug) and sent a screenshot: strokes
  landed as one-sample spikes. THE CAUSE WAS THE ENGINE's: `isItemActivated` compares the active item with
  `active_id_prev_frame`, which only ui.zig's unit tests ever set - by hand. `beginFrameRaw` carried `hovered_id` over
  and never `active_id` (the field's doc said "Snapshotted in `endFrame`", which nothing did), so every held frame read
  as a press frame, and the page started a new stroke - one sample - on each. FIXED in src/ui.zig: `beginFrameRaw`
  sets `active_id_prev_frame = active_id`. The page was the only caller of these queries outside ui.zig. Its test, in
  ui.zig, takes every frame from `beginFrameRaw` alone: "isItemActivated is the press frame alone, and
  isItemDeactivated the release frame, over real frames" (hover, press, hold, hold, release).
  S2d WRITTEN (NOT BUILT):
    - 3.9's S2 checks, `examples/zimrnum_fit/kernels_tests.zig`, step `test-zimrnum-fit` (the quick tier, so in
      `zig build test`), compiled natively in Debug from the kernel wasm's own module graph: build.zig's
      `JobKernelModules` (`create`, `kernelsModule`), taken out of `buildJobKernels`, which now uses it. "its steps
      are KitMlp's own on the twin, bit for bit" (a fresh job against KitMlp from a `Spec` written out by hand: steps,
      parameter count, loss, weights, both moments, curve) and "one job of K steps is K jobs of one, the state carried
      in the bytes". Adam over tanh, SGD (momentum 0.9) over relu, 2 x 16; every twin buffer poisoned with NaN
      before each run (claude.md, two CPU pipes are one set of buffers).
    - THE LOSS CHART, 3.8's row: under the drawing, a point per landing - seconds since the page started
      (`wgpu.nowMs`), and the loss, on a log axis - in a room of 1,024 points: when it fills, every other point goes
      and every other landing is kept from then on, so the whole run stays in view. The network's colour for now; S3
      colours it by machine.
    - The readout's last line, "frames N ms, worst M ms": the frames' average beside the worst gap (3.8's "frame
      16.6 ms"), telling a slow build's frames from a hitch.
    - FROM THE SCREENSHOT: 6 steps a second, a job of one step in 196 ms, the worst gap 65 ms - a Debug build, whose
      twin runs every kernel as host loops with every safety check (natively `-Dmode=release` is ReleaseSafe; Debug
      is for stepping a kernel). The worst gap is the run's worst frame, red after a single hitch; the average says
      which it was. The panel's slider labels looked cut at the window's right edge: a crop or the layout - S4 looks.
    - To see each check fail once (3.9): drop the new line in `beginFrameRaw` (the ui test fails at the first held
      frame); swap relu and tanh in kernels.zig's `networkSpec` (the first job check fails); write `.step_count = 0`
      in `trainSteps`' `putState` (the second fails, for Adam).
    - fmt, ast-check and zimrlint (60 rules) clean on every file touched: the four example files, build.zig, ui.zig.
  S2 IS WRITTEN. Its gate (section 4) is Simon's: the page in a browser and natively at 60 fps, a kernel stepped
  under LLDB (G6), and the tests above. S3 (the GPU and the toggle) on his go.
- Nov 22 - Simon ran S2d natively: drawing in the window panicked in the loss chart's ticks (plot.zig `generateLog`,
  `@intCast(-e)` into a u8). TWO ENGINE BUGS: plot_ui's `fitToSeries` padded every axis by 5% of its span, a log axis
  too, so once the smallest loss was under a twentieth of the largest - a stroke raises the loss - the fitted minimum
  went below zero; and `generateLog` met a range at or below zero by starting its decades at 1e-300, whose label asked
  300 decimals of a u8. FIXED: `padRange` pads a log axis in decades; `fitToSeries` fits a log axis to its values
  above zero (`expandShown`), `show` handing it each primary axis's scale, picked once; `generateLog` cuts a label's
  decimals to what a u8 holds. Tests: plot_ui "fitToSeries: a log axis is fitted in decades to the values above zero,
  and never reaches zero"; plot "plot.Ticker: a log axis whose range reaches below zero gets its ticks without a
  panic" (the panic itself, before the fix). fmt, ast-check, zimrlint clean.
- Nov 22 - Simon: "Start S3". S3 split in two turns: S3a the GPU machine and the toggle (3.5's GPU half, 3.6); S3b
  the loss chart coloured by machine (D9), a device check that the kit's plain MLP steps alike on the device and the
  twin (G2's footing, in `vk-host-test`), and Simon's desktop and phone pass (G7). S3a WRITTEN (NOT BUILT):
    - build.zig: `sgd` among zimrnum_fit's kernel entries. compute_host: `recording_slots` public, so a page sizes a
      batch by it. kernels.zig: `networkSpec` public - the job's network, the GPU's, one function.
    - THE GPU's PIPE, made at init in the background (`initGpuInBackground`) from the page's eight kernels
      (`gpu_kernel_names`, each `<name>_wgsl`); the panel's GPU button is enabled once `pipelineProgress` is complete,
      "preparing kernels i/8" meanwhile, "no GPU here" without a pipe.
    - THE GPU's BATCHES (`submitBatch`, `collectBatch`): the panel's changes made first (`applySettingsOnTheGpu`: a
      fresh start makes a new network; a new optimiser zeroes both moments on the device and the step count; the rate
      and SGD's momentum set on the live network's spec, which each recorded step reads), `setBatch` with the drawing
      as it is, `trainSteps(K)` as one submission, then two readbacks, the curve and the loss; one batch in flight;
      both landings polled every frame. K doubles while a batch is back within two frames and the frames keep time,
      halves past four frames or when they run late, and never passes `recording_slots` over the dispatches a step
      makes (4 a layer + 3).
    - THE TOGGLE (`switchMachines`): CPU to GPU once the job in flight has landed - the GPU's network made for the
      settings takes the page's state (`putState`) unless the training starts afresh; GPU to CPU once the batch has
      landed - the GPU's state asked back (`requestState`) into the page's, and the next job goes on from it. Nothing
      is submitted while a switch is pending, so no step is lost; a toggle turned back before the GPU's state lands
      gives the request up.
    - DEPARTURE from 3.5: the GPU's loss comes back as a one-float range of the loss buffer, not computed on the host
      from the curve. A range request copies only its range, so nothing widens, and the loss is the kit's own
      `mse_value` - the number the CPU's job sends - so two definitions cannot make the chart jump at a flip.
    - fmt, ast-check and zimrlint (60 rules) clean: the page, kernels.zig, compute_host.zig, build.zig.
- Nov 22 - Simon: "Start S3b". S3b WRITTEN (NOT BUILT):
    - THE LOSS CHART BY MACHINE (D9): each point keeps the machine that trained it (`loss_machines`, moved with the
      points when the room halves); one line per machine - the CPU's in the network's orange, the GPU's in violet -
      each holding a missing number (NaN, which breaks a plot's line: plot.zig's `finite2`) where the other machine
      trained, and the point before a flip on both lines, so the line runs on unbroken in the new colour. A legend
      names them.
    - THE DEVICE CHECK, G2's footing - vk-host-test "zimrnum_fit's network handed between the device and the twin,
      both ways, goes on as the twin's own run" (`runFitHandOver`): the page's default network (3 x 64, tanh, Adam at
      5e-3) and SGD with momentum 0.9 over relu (1e-2), on the page's grid and starting sine. Four steps on one
      machine, its state (`requestState`) put on a network of another seed on the other (`putState`), four more
      there - device to twin and twin to device - each against the twin's own eight uninterrupted steps, every number
      compared (weights, both moments, curve, loss) by the kit check's own measure and bar (`largestRelativeGap`,
      1e-5), both gaps printed. It fails if the device steps otherwise than the twin, or if the state leaves out
      anything a step reads. To see it fail once (3.9): hand over `.step_count = 0` in `fitStepsHandedOver` - Adam's
      corrections then restart, and the Adam case parts from the straight run.
    - fmt, ast-check and zimrlint (60 rules) clean: the page, vk_host_test.zig.
  S3 IS WRITTEN. Its gate is Simon's: the page on the desktop and on the S23 FE (G1, G3, G4, G7), and vk-host-test.
  Then S4 on his go: the default size measured (G3), the phone layout, the card, the catalog row, the readme.
- Nov 22 - Simon: "Start S4". S4 split in two: S4a what needs no measurement; S4b the default size, set from Simon's
  measurements (G3), and whatever his S23 FE run asks of the phone layout (G7). S4a WRITTEN (NOT BUILT):
    - D10's line, under the readout: "a GPU pays per dispatch, a CPU per multiplication: the wider the layers, the
      further ahead the GPU".
    - The card (src/web/manifest.json): the finished page's description; three stars (jobs, the GPU and the kit).
    - The catalog row (src/notes/examples_catalog.md, "Compute, workers and numerics"), between zimrnum_field and
      zimrnum_train. FOUND: five other examples have no row (geno_mirror, hello_world_owned_main, music_theory,
      robotgpu_lab, robotgpu_sidebyside), and the header's counts (309 cards, 333 directories) are stale - 332 and 340
      today; left as they were, other work's.
    - The readme (src/web/readme.html): a paragraph under "Training on the GPU" (the page, its toggle, the breakpoint in
      a kernel on the CPU), and one under the jobs section (a job keeps nothing, so a training ships its state in and
      out with every call).
    - THE PHONE: unchanged, on purpose. A window scrolls under a finger when its content overflows (ui.zig's
      touch-pan), so the panel stays reachable below the plot; what else G7 needs is for the S23 FE to say.
    - fmt, ast-check, zimrlint clean; the manifest parses.
  S4b NEEDS, from Simon's desktop, release builds: steps a second on the CPU and on the GPU at 3 hidden layers of 16,
  64, 128 and 256 (the readout's line, after a few seconds on each), in the browser and natively. The default becomes
  the narrowest width where the GPU is at least ten times the CPU on the desktop (G3).
- Nov 22 - Simon: "maybe let the app write some logs you could read? Look at what geno lab training logs?" geno_lab's
  trainer keeps a run as a folder beside the program (`runs/<name>/`: `run.zon`, `log.csv` a line per batch, `status`,
  `times.csv`), written natively through `native_os` (`servicesIo`, `executableFolder`, `writeWhole`), never in a page.
  THE SPEED LOG, the same way, WRITTEN (NOT BUILT): a line a second - at each renewal of the steps a second - of
  seconds, machine, inline, layers, width, activation, optimiser, rate, steps a second, the last job's or batch's steps
  and milliseconds, the frames' average and worst, the loss, the steps since a fresh start; under a head naming the
  platform, the build's mode and whether jobs had workers. Natively it is written ONCE, as the page closes -
  `zimrnum_fit_log.csv` beside the executable, its path on the console - so that no frame of a measured run waits on a
  file. In a browser, the panel's "save the log" downloads it (`z.userfile.offerDownload` and `setSaveRect`, as geno_ppo
  saves its weights; natively the same button opens the system's dialog). S4b reads G3's numbers from it.
- Nov 22 - THE FIRST SPEED LOG (Simon's native run, ReleaseSafe, the RTX 5060 laptop; zig-out/windows/
  zimrnum_fit_log.csv, 19 lines; no browser log reached Downloads). Steady windows only (a window that straddles a
  flip counts the other machine's landings too):
      3 x 64, tanh, Adam    CPU ~41 steps/s (a job of 1 step, 22-33 ms)    GPU ~1,005 steps/s (32-64 a batch)   25x
      4 x 250               CPU ~3 steps/s (a job of 1 step, 365 ms)       GPU ~585 steps/s (16-32 a batch)    195x
  G3 HOLDS at the default: keep 3 x 64. The GPU is dispatch-bound - about 0.86 ms a step at 3 x 64, 19 dispatches
  each - as D10's line says. BUT G4 FAILS ON THE GPU: frames average 7 ms on the CPU and 17-21 ms on the GPU, the worst
  52-66 ms. The batches are 25-55 ms of device work, back to back, and the page's drawing waits behind them. The cause
  is S3a's steering, which departed from 3.5 without saying so: it doubled a batch while it came back within TWO frames
  and halved it only past FOUR, or when the AVERAGE frame passed 20 ms. 3.5 said within a frame, and the frame on time.
  Also: the log's worst-frame column is the run's worst so far, not the window's, so it cannot say which window
  hitched.
  THE BROWSER's LOG (Simon's second web run, ReleaseSmall, workers; Downloads/zimrnum_fit_log.csv, 18 lines):
      3 x 64, tanh, Adam    CPU ~64 steps/s (a job of 2 steps, 21-35 ms)   GPU ~645 steps/s (32 a batch, 44 ms)  10x
      4 x 249               CPU ~5 steps/s (a job of 1 step, 220 ms)       GPU ~315 steps/s (16 a batch, 45 ms)  63x
  In the browser G3 holds only just (10x), and the worker's CPU is FASTER than native ReleaseSafe's (64 against 41:
  the native twin runs with every safety check). Frames stay at 16.5-16.8 ms on both machines - the rate at which the
  browser calls the page - and the worst is 22.7 ms but once (56.6 ms, at the flip to the GPU at 4 x 249). The browser
  calls the frame at 60 Hz even with the GPU busy back to back, so its frame time cannot show whether the canvas kept
  up. Natively the frame waits on the device and shows it.
- Nov 22 - Simon: "fix the steering, and this demo to the gallery, and in the launcher". WRITTEN (NOT BUILT):
    - THE STEERING, as the logs showed it must be (`steerStepsPerBatch`): a batch is halved when any frame while it
      was in flight ran late (past 21 ms) or it took past four frames to come back. It grows natively only while every
      frame during it stayed quick (under 12.5 ms) - the band between the two keeps it from rocking between two
      sizes - and in a browser while it comes back within two frames, a browser's frame time being blind to the
      device. The frame gap is now measured first in `update`, so the frame a batch lands on counts toward it; the
      log's worst-frame column is the window's worst.
    - THE GALLERY needs nothing more: both galleries - the web page and `zimr_gallery` - show every card of
      src/web/manifest.json, and zimrnum_fit's has been there since S0, its text final since S4a. Its thumbnail is
      the default shot (120 frames of the script's clock).
    - THE LAUNCHER: build.zig's flagship list and examples/launcher/launcher.zig's roster, after zimrnum_field (36
      each - `checkLauncherRoster` keeps them equal, and `flagships-check` now runs it too); the launcher's kernel wasm
      built with zimrnum_fit's kernels (`buildJobKernels`' list), and examples/launcher/kernels.zig naming
      `trainSteps` and taking zimrnum_fit's bounds into its max. The page submits through its own registry - natively
      lent to one job at a time - so the merged table only names the kernel for the kernel wasm.
    - A COST TO WATCH: the kit's CPU twin is static buffers - about 21 MB (acts 8, ring 4, dacts 4, the five
      parameter-sized buffers 5) - so the launcher's main wasm and each of its workers now reserve it, zimrnum_fit
      opened or not; untouched pages of a wasm memory are usually not backed by RAM, but a phone may say otherwise.
    - fmt, ast-check and zimrlint clean: the page, both launcher files, build.zig.
