// runner.mjs — the ONE hand-written JS file in the test path (ZIG_BRIDGE_PLAN
// Phase 5). It is a thin host boundary: it does nothing but the things a wasm
// module cannot do for itself — read files, call WebAssembly.instantiate, and
// run exported functions. ALL test LOGIC (which imports to shim, how to count
// and classify host calls, how to format the verdict) lives in a Zig module
// compiled to wasm and transpiled to JS by our own c2js. This file is the
// irreducible minimum and is meant to stay tiny and auditable.
//
// Contract with the test-logic module (compiled from webtests/*.zig via c2js):
//   It is a normal c2js bare-JS module. Its byte-level work is done through a
//   small host API we install on globalThis before its top-level runs:
//
//     __host.readFile(path)            -> Uint8Array | null
//     __host.argv()                    -> string[]   (argv after the script)
//     __host.print(str)                -> void        (stdout + newline)
//     __host.eprint(str)              -> void        (stderr + newline)
//     __host.exit(code)               -> void
//     __host.instantiateSut(bytes, importNames)
//         importNames: { wgpu:[...], wasi_snapshot_preview1:[...], dom:[...],
//                        audio:[...] } — names the SUT may import. The stub
//         builds shim namespaces where EVERY named function records its call
//         into a shared log and returns a fresh handle (numbers) or void. The
//         test logic declares which names are "void" via a second arg.
//         Returns a SUT id (int) or -1 on failure (message via eprint).
//     __host.sutExports(id)            -> string[]   (export names)
//     __host.sutCall(id, name, ...args)-> number     (calls an export)
//     __host.sutCallLog(id)            -> string[]    (the recorded call names,
//                                                      in order, since reset)
//     __host.sutResetLog(id)           -> void
//
// The shims return numeric handles for everything (the smoke battery only
// checks that wasms instantiate + run N frames without calling an undeclared
// import; it never inspects real GPU results). Names not in importNames but
// imported by the SUT are installed as "unhandled" stubs that record a
// distinct marker so the test logic can fail on undeclared imports.
import { readFileSync, readdirSync, writeFileSync, mkdirSync, statSync } from "node:fs";
import { createHash } from "node:crypto";

const suts = new Map(); // id -> { instance, log, voidNames, unhandled }
let nextSutId = 1;

// Fixed host-fact returns shared by all SUTs: stable environment values the
// headless host reports (DPI, audio sample rate, persistence "absent", etc.).
// These are NOT test logic — they're what a real host would return — so they
// live here rather than being threaded through the Zig side. Names not listed
// default to void (undefined) or a fresh handle per the test's voidNames set.
const FIXED_RETURNS = {
  // dom host facts
  js_persistence_save: 0, js_persistence_size: -1, js_persistence_read: -1,
  js_persistence_remove: 0, js_get_dpi_scale: 1, js_is_fullscreen: 0,
  js_pointer_lock_active: 0, js_overlay_input_is_visible: 0,
  js_get_overlay_input_text: 0, js_overlay_textarea_is_visible: 0,
  js_get_overlay_textarea_text: 0,
  // audio host facts
  js_audio_create_context: 1, js_audio_get_sample_rate: 48000,
  js_audio_get_current_time: 0, js_audio_get_master_volume: 1,
  js_audio_load_buffer: 1, js_audio_play_buffer: 1, js_audio_is_buffer_playing: 0,
  js_audio_play_buffer_at: 1, js_audio_play_buffer_with_offset: 1,
  js_audio_decode_ogg_bytes: 1, js_audio_is_decode_ready: 1,
  js_audio_take_decoded_buffer: 1,
};

function makeShim(log, names, voidNames, unhandled, state) {
  const ns = {};
  // ---- LOG SAFETY VALVE ---------------------------------------------------
  // `sutCallLog` hands the test logic `log.slice()` — a FULL COPY — and
  // wgpu_smoke.zig calls it six times. With a `-Dmode=debug` SUT that is fine:
  // the first assert @panics and the run stops after a few thousand entries.
  //
  // With a `-Dmode=release` SUT it is not. Release lowers `assertf` to
  // "log and keep running", so the SUT completes every frame, re-emits the SAME
  // assert message each frame, and the log grows without bound — node dies with
  // a 2 GB heap before the logic ever gets to read it. That made release, the
  // ONLY mode that surfaces more than one assert per run, impossible to put
  // through this runner at all.
  //
  // Two measures, both designed to be inert on a normal run so the gate's
  // semantics are untouched:
  //
  //  1. A generous hard cap. Plain call records are counted, not truncated
  //     early — debug smoke runs sit far below this, so verb counting and the
  //     GPU-handle-balance check see exactly what they saw before. Past the cap
  //     we stop appending and record how many were dropped, so the log never
  //     silently lies about being complete.
  //  2. Exact-duplicate `!ASSERT` suppression. wgpu_smoke fails on the FIRST
  //     matching entry, so keeping one copy of each distinct message loses
  //     nothing and removes the release-mode explosion at its source.
  const MAX_LOG = state.maxLog || 500000;
  const seenAsserts = new Map(); // message -> times seen
  let dropped = 0;
  const emit = (line) => {
    if (line.charCodeAt(0) === 33 /* '!' */ && line.startsWith("!ASSERT ")) {
      const n = (seenAsserts.get(line) || 0) + 1;
      seenAsserts.set(line, n);
      if (n > 1) return; // already recorded; the logic fails on the first
      // wgpu_smoke's assertMsg reports only the FIRST !ASSERT, so a second,
      // independent failure behind it stays invisible in the normal output.
      // Under --trace-calls echo every distinct one.
      if (state.traceCalls) process.stderr.write("[MARKER] " + line + "\n");
    }
    if (log.length >= MAX_LOG) { dropped += 1; return; }
    log.push(line);
    if (log.length === MAX_LOG) {
      log.push(
        "!LOGCAP reached " + MAX_LOG + " entries; further plain call records " +
        "are dropped (pass --max-log=N to raise). Distinct !ASSERT lines were " +
        "kept. This is a runaway-log guard, not a test failure.",
      );
    }
  };
  // Exposed so a caller can report suppression counts without reading the log.
  state.logStats = () => ({ dropped, asserts: [...seenAsserts.entries()] });
  const record = (name, args) => {
    // `--trace-calls` writes each host call to stderr UNBUFFERED, as it happens.
    // Everything else this runner prints is buffered until the logic finishes,
    // so a run that hangs or is killed produces a ZERO-BYTE log and no clue
    // where it stopped — which is exactly the situation where you most need one.
    // Args included: for a bind-group or pipeline bug the INDEX is the whole question, and a
    // bare list of verb names cannot answer it.
    if (state.traceCalls) {
      process.stderr.write(name + "(" + args.map((a) => String(a)).join(", ") + ")\n");
    }
    // Record the full call signature so the test logic can classify by name
    // and inspect args if it wants (it splits on "(" for the bare name).
    emit(name + "(" + args.map((a) => String(a)).join(", ") + ")");
  };
  // Decode a (ptr, len) UTF-8 label out of the SUT's linear memory. Safe to
  // call lazily (state.mem is attached after instantiation). Empty on failure.
  const readLabel = (ptr, len) => {
    if (!state.mem || !len) return "";
    try {
      const bytes = new Uint8Array(state.mem.buffer, ptr, len);
      return new TextDecoder().decode(bytes);
    } catch {
      return "";
    }
  };
  // ---- GPU ATTACHMENT-STATE VALIDATION -----------------------------------
  // WebGPU rejects a setPipeline() whose pipeline was built for a different
  // attachment state than the open pass ("Attachment state of [RenderPipeline X]
  // is not compatible with [RenderPassEncoder]"). That check only ever ran on a
  // real GPU, so every mismatch cost a device round-trip to discover — the
  // sandbox has no GPU and these shims happily return handles.
  //
  // But BOTH sides of the rule are visible right here: the pipeline's descriptor
  // blob carries its depth format + sample count, and begin_render_pass is told
  // its depth view (0 = none). So we can enforce WebGPU's own rule with pure
  // bookkeeping, no GPU required, and fail in-sandbox instead of on the phone.
  const pipeAttach = new Map(); // pipeline handle -> {depthFormat, sampleCount, colorFormat, label}
  const passAttach = new Map(); // pass handle     -> {hasDepth}

  // Forward-parse gpu.zig's encodeRenderPipelineDescriptor (see SECTION 3 there).
  // The tail is variable (depth-compare string, constants, extra color formats),
  // so the fixed fields must be walked to, not counted back from.
  const parsePipelineDesc = (ptr, len) => {
    if (!state.mem || !len) return null;
    try {
      const dv = new DataView(state.mem.buffer, ptr, len);
      let o = 0;
      const u32 = () => { const v = dv.getUint32(o, true); o += 4; return v; };
      const skipStr = () => { const n = u32(); o += n; };
      const vbCount = u32();
      for (let i = 0; i < vbCount; i++) {
        u32();                       // array_stride
        u32();                       // step_mode
        const attrs = u32();
        for (let a = 0; a < attrs; a++) { u32(); u32(); u32(); }
      }
      skipStr();                     // vs_entry_point
      skipStr();                     // fs_entry_point
      u32();                         // topology
      u32();                         // cull
      u32();                         // blend
      u32();                         // depth_mode
      const colorFormat = u32();
      const depthFormat = u32();     // TextureFormat.undefined_ == 0 == "no depth"
      const sampleCount = u32();
      return { colorFormat, depthFormat, sampleCount };
    } catch {
      return null;
    }
  };

  // ---- BIND-GROUP-LAYOUT COMPATIBILITY VALIDATION ------------------------
  // Same trick as the attachment validator above, applied to the other rule
  // that only ever fires on a real GPU: at draw time WebGPU requires that, for
  // every group index the bound pipeline's layout declares WITH BINDINGS, a
  // bind group is set there whose layout is group-equivalent. Violating it
  // rejects the WHOLE command buffer at submit — so the symptom is a black
  // canvas with no clear colour, and nothing in the JS console until you put it
  // on a device.
  //
  // Every edge of the graph is visible from here, which is what makes this
  // feasible at all:
  //   create_bind_group_layout(device, entriesPtr, entriesLen, ...) -> bgl
  //   create_bind_group(device, LAYOUT, ...)                        -> bg
  //   create_pipeline_layout(device, BGL_ARRAY_PTR, count, ...)     -> pl
  //   create_render_pipeline(device, LAYOUT, ...)                   -> pipeline
  //   set_pipeline(pass, pipeline) / set_bind_group(pass, i, bg) / draw*
  //
  // Layout identity is the raw entries blob. `encodeBindGroupLayoutEntries`
  // emits entries in a deterministic order for a given layout, so byte equality
  // is a sound identity: identical bytes always mean identical layouts. It can
  // in principle miss an equivalence (two orderings of the same entry set), and
  // that direction is the safe one — this validator stays silent rather than
  // crying wolf.
  const bglSig = new Map();     // bgl handle      -> {sig, count, label}
  const bgToBgl = new Map();    // bind group      -> bgl handle
  const plGroups = new Map();   // pipeline layout -> [bgl handle]
  const pipeToPl = new Map();   // pipeline        -> pipeline layout
  const passBound = new Map();  // pass            -> Map(index -> bind group)
  const passPipe = new Map();   // pass            -> pipeline

  // Read a (ptr,len) byte blob as a hex string, plus its leading u32 (the entry
  // count — 0 means an `empty_bgl`, which `loadShader` mints for every group
  // below the highest group a schema actually uses).
  const readBlob = (ptr, len) => {
    if (!state.mem || !len) return null;
    try {
      const bytes = new Uint8Array(state.mem.buffer, ptr, len);
      let sig = "";
      for (let i = 0; i < bytes.length; i += 1) sig += bytes[i].toString(16).padStart(2, "0");
      const count = len >= 4 ? new DataView(state.mem.buffer, ptr, 4).getUint32(0, true) : 0;
      return { sig, count };
    } catch {
      return null;
    }
  };

  const readHandleArray = (ptr, n) => {
    if (!state.mem) return null;
    try {
      const dv = new DataView(state.mem.buffer, ptr, n * 4);
      const out = [];
      for (let i = 0; i < n; i += 1) out.push(dv.getUint32(i * 4, true));
      return out;
    } catch {
      return null;
    }
  };

  // WebGPU inherits bind groups across a setPipeline only while the two
  // pipeline layouts agree index-by-index; from the first divergent index on,
  // the bound groups are UNSET. Modelling this is what keeps the validator from
  // flagging a stale group that the device would have discarded anyway.
  const applyInheritance = (passH, oldPipe, newPipe) => {
    const bound = passBound.get(passH);
    if (!bound) return;
    const oldPl = plGroups.get(pipeToPl.get(oldPipe));
    const newPl = plGroups.get(pipeToPl.get(newPipe));
    if (!newPl) return;
    let divergeAt = 0;
    if (oldPl) {
      while (divergeAt < oldPl.length && divergeAt < newPl.length) {
        const a = bglSig.get(oldPl[divergeAt]);
        const b = bglSig.get(newPl[divergeAt]);
        if (!a || !b || a.sig !== b.sig) break;
        divergeAt += 1;
      }
    }
    for (const idx of [...bound.keys()]) if (idx >= divergeAt) bound.delete(idx);
  };

  // THE CHECK, run at every draw.
  const checkDraw = (passH, what) => {
    const pipe = passPipe.get(passH);
    if (pipe === undefined) return;
    const pl = plGroups.get(pipeToPl.get(pipe));
    if (!pl) return; // unknown pipeline layout — stay silent rather than guess
    const bound = passBound.get(passH) || new Map();
    const pipeLabel = (pipeAttach.get(pipe) || {}).label || ("pipeline#" + pipe);
    for (let i = 0; i < pl.length; i += 1) {
      const want = bglSig.get(pl[i]);
      if (!want) continue;
      if (want.count === 0) continue; // empty layout declares no bindings
      const bg = bound.get(i);
      if (bg === undefined) {
        emit(
          "!ASSERT gpu-validation: " + what + " with pipeline \"" + pipeLabel +
          "\" needs a bind group at group " + i + " (its layout \"" +
          (want.label || "?") + "\" declares " + want.count + " binding(s)) but none is set. " +
          "WebGPU rejects the WHOLE command buffer at submit — the symptom is a " +
          "black canvas, pass clear included.",
        );
        continue;
      }
      const got = bglSig.get(bgToBgl.get(bg));
      if (got && got.sig !== want.sig) {
        emit(
          "!ASSERT gpu-validation: " + what + " with pipeline \"" + pipeLabel +
          "\" has an INCOMPATIBLE bind group at group " + i + ": bound group's layout \"" +
          (got.label || "?") + "\" (" + got.count + " binding(s)) does not match the " +
          "pipeline layout's \"" + (want.label || "?") + "\" (" + want.count + " binding(s)). " +
          "Most often this is a 2D shapes-batch flush running under a foreign " +
          "pipeline: the flush binds the atlas at gpu_iface.batch_reserved_group (1). " +
          "Draw through the shader's own pipeline instead — see wgpu_app.drawFullscreenShader.",
        );
      }
    }
  };

  // ---- WASI fd_write ------------------------------------------------------
  // MUST be implemented, not stubbed. A `-Dmode=release` SUT lowers `assertf`
  // to `std.log.err` + keep running, and on a wasi target that lands in
  // fd_write. The generic stub returns a value without ever writing `nwritten`
  // into memory, so Zig's writer — which loops until every byte is reported
  // written — spins FOREVER. That is not a hypothetical: it is why a known-bad
  // release bringup hung this runner indefinitely while `panic_probe.mjs`, which
  // implements fd_write for real, completed the same frame instantly.
  //
  // Decoding it also surfaces release-mode assert text to the smoke gate, which
  // is the only way the gate can see a SECOND assert — in debug the first one
  // @panics and everything behind it stays invisible.
  const fdWrite = (fd, iovsPtr, iovsLen, nwrittenPtr) => {
    if (!state.mem) return 0;
    try {
      const dv = new DataView(state.mem.buffer);
      let total = 0;
      let text = "";
      for (let i = 0; i < iovsLen; i += 1) {
        const base = dv.getUint32(iovsPtr + i * 8, true);
        const len = dv.getUint32(iovsPtr + i * 8 + 4, true);
        text += new TextDecoder().decode(new Uint8Array(state.mem.buffer, base, len));
        total += len;
      }
      if (nwrittenPtr) dv.setUint32(nwrittenPtr, total, true);
      state.wasiText = (state.wasiText || "") + text;
      if (text.indexOf("assert failed") !== -1) emit("!ASSERT " + text.trim());
      return 0;
    } catch {
      return 0;
    }
  };

  for (const name of names) {
    if (name === "js_device_create_render_pipeline") {
      // (device, layout, vs, fs, descPtr, descLen, labelPtr, labelLen)
      ns[name] = (...args) => {
        record(name, args);
        const h = state.nextHandle++;
        const desc = parsePipelineDesc(args[4] | 0, args[5] | 0);
        const label = readLabel(args[6] | 0, args[7] | 0) || ("pipeline#" + h);
        if (desc) pipeAttach.set(h, { ...desc, label });
        pipeToPl.set(h, args[1] | 0);
        return h;
      };
    } else if (name === "js_encoder_begin_render_pass") {
      // (encoder, colorView, r,g,b,a, loadOp, storeOp, depthView, resolveView)
      ns[name] = (...args) => {
        record(name, args);
        const h = state.nextHandle++;
        passAttach.set(h, { hasDepth: (args[8] | 0) !== 0 });
        return h;
      };
    } else if (name === "js_encoder_begin_render_pass_mrt") {
      ns[name] = (...args) => {
        record(name, args);
        const h = state.nextHandle++;
        // MRT's depth view is the last arg before the resolve view; be lenient —
        // if we can't tell, don't invent a constraint.
        passAttach.set(h, { hasDepth: undefined });
        return h;
      };
    } else if (name === "js_render_pass_set_pipeline") {
      // THE CHECK. This is the exact call the browser rejects.
      ns[name] = (...args) => {
        record(name, args);
        const passH = args[0] | 0;
        const pipeH = args[1] | 0;
        applyInheritance(passH, passPipe.get(passH), pipeH);
        passPipe.set(passH, pipeH);
        const pass = passAttach.get(args[0] | 0);
        const pipe = pipeAttach.get(args[1] | 0);
        if (!pass || !pipe || pass.hasDepth === undefined) return;
        const pipeWantsDepth = pipe.depthFormat !== 0;
        if (pipeWantsDepth !== pass.hasDepth) {
          emit(
            "!ASSERT gpu-validation: pipeline \"" + pipe.label + "\" has " +
            (pipeWantsDepth ? "a depth attachment" : "NO depth attachment") +
            " but the open render pass has " +
            (pass.hasDepth ? "one" : "none") +
            " — WebGPU rejects this setPipeline. " +
            "(A pipeline's depth state must match the pass it is bound into; " +
            "see renderer_2d: `if (depth_format != null) .always else .none` and " +
            "`depth_format orelse .undefined_`.)",
          );
        }
      };
    } else if (name === "js_surface_get_size" || name === "js_surface_get_css_size") {
      // Packed (800<<16)|600 so depth-texture creation paths run.
      ns[name] = (...args) => { record(name, args); return (800 << 16) | 600; };
    } else if (name === "js_now_ms") {
      ns[name] = (...args) => { record(name, args); state.nowMs += 16; return state.nowMs; };
    } else if (name === "js_log") {
      // Read the SUT's log message; if it's a fired assert, push a distinctive
      // marker the smoke logic scans for and FAILS on. This turns runtime
      // assertf()s (e.g. frameEncoder's "call ensureFrame first", or a phase
      // assert) into a headless CI failure instead of a device-only surprise.
      ns[name] = (...args) => {
        record(name, args);
        const len = args[args.length - 1] | 0;
        const ptr = args[args.length - 2] | 0;
        const msg = readLabel(ptr, len);
        if (msg.indexOf("assert failed") !== -1) emit("!ASSERT " + msg);
        // `--leak-trace` report lines (the SUT's LeakWatch.reportSinceMark, `who` =
        // "leak-trace") go into the call log where the smoke logic reads them.
        if (msg.startsWith("leak-trace")) emit("!TRACE " + msg);
      };
    } else if (name === "js_device_create_bind_group_layout") {
      // (device, entriesPtr, entriesLen, labelPtr, labelLen)
      ns[name] = (...args) => {
        record(name, args);
        const h = state.nextHandle++;
        const label = readLabel(args[3] | 0, args[4] | 0);
        const blob = readBlob(args[1] | 0, args[2] | 0);
        if (blob) bglSig.set(h, { ...blob, label });
        if (label) emit("LABEL_MAP(" + h + ", " + label + ")");
        return h;
      };
    } else if (name === "js_device_create_pipeline_layout") {
      // (device, bglsPtr, bglsLen, labelPtr, labelLen)
      ns[name] = (...args) => {
        record(name, args);
        const h = state.nextHandle++;
        const groups = readHandleArray(args[1] | 0, args[2] | 0);
        if (groups) plGroups.set(h, groups);
        return h;
      };
    } else if (name === "js_render_pass_set_bind_group") {
      // (pass, groupIndex, bindGroup)
      ns[name] = (...args) => {
        record(name, args);
        const passH = args[0] | 0;
        if (!passBound.has(passH)) passBound.set(passH, new Map());
        passBound.get(passH).set(args[1] | 0, args[2] | 0);
      };
    } else if (name === "js_render_pass_draw" || name === "js_render_pass_draw_indexed") {
      ns[name] = (...args) => {
        record(name, args);
        checkDraw(args[0] | 0, name === "js_render_pass_draw" ? "draw" : "drawIndexed");
      };
    } else if (name in FIXED_RETURNS) {
      const v = FIXED_RETURNS[name];
      ns[name] = (...args) => { record(name, args); return v; };
    } else if (voidNames.has(name)) {
      ns[name] = (...args) => { record(name, args); };
    } else if (
      name === "js_device_create_buffer" ||
      name === "js_device_create_bind_group" ||
      name === "js_device_create_bind_group_layout"
    ) {
      // Handle-returning creates that carry a (labelPtr, labelLen) tail: assign
      // the handle, then append a LABEL_MAP(handle, name) line to the log so the
      // clobber scan can NAME the buffer/group in its failure message.
      ns[name] = (...args) => {
        record(name, args);
        const h = state.nextHandle++;
        const len = args[args.length - 1] | 0;
        const ptr = args[args.length - 2] | 0;
        const label = readLabel(ptr, len);
        // (device, LAYOUT, entriesPtr, entriesLen, labelPtr, labelLen) — the
        // layout handle is what lets a draw compare this group against the
        // bound pipeline's layout.
        if (name === "js_device_create_bind_group") bgToBgl.set(h, args[1] | 0);
        if (label) emit("LABEL_MAP(" + h + ", " + label + ")");
        return h;
      };
    } else {
      ns[name] = (...args) => { record(name, args); return state.nextHandle++; };
    }
  }
  // A Proxy catches any import the SUT asks for that we didn't list, so
  // instantiation never fails on a missing import; instead it records an
  // "unhandled:<name>" marker the test logic can detect.
  return new Proxy(ns, {
    get(target, prop) {
      if (prop in target) return target[prop];
      if (typeof prop !== "string") return undefined;
      // fd_write must be REAL even when unlisted — see fdWrite above. It is not
      // marked unhandled, because it is handled; treating it as a missing import
      // would fail the gate for every release SUT that logs.
      if (prop === "fd_write") return fdWrite;
      // proc_exit likewise: returning 0 lets the SUT keep running past an exit
      // it expected to be terminal, which corrupts the rest of the run.
      return (...args) => {
        unhandled.add(prop);
        emit("!UNHANDLED " + prop + "(" + args.length + " args)");
        return 0;
      };
    },
  });
}

const host = {
  readFile(path) {
    try {
      return new Uint8Array(readFileSync(path));
    } catch {
      return null;
    }
  },
  // Read a file as a UTF-8 string (null on error). For the fixture JSON.
  readText(path) {
    try {
      return readFileSync(path, "utf8");
    } catch {
      return null;
    }
  },
  // List *.wasm files in a directory, sorted, newline-joined (or "" on
  // error). The test logic splits on "\n". Used by directory/--web-dir mode.
  listWasms(dir) {
    try {
      return readdirSync(dir).filter((f) => f.endsWith(".wasm")).sort().join("\n");
    } catch {
      return "";
    }
  },
  argv() {
    return process.argv.slice(2);
  },
  print(s) {
    process.stdout.write(s + "\n");
  },
  eprint(s) {
    process.stderr.write(s + "\n");
  },
  exit(code) {
    process.exit(code | 0);
  },
  instantiateSut(bytes, importSpec) {
    const log = [];
    const voidNames = new Set(importSpec.voidNames || []);
    const unhandled = new Set();
    // `--max-log=N` raises the runaway-log guard (see `emit` in makeShim).
    // Default 500k entries: far above any debug smoke run, so it is inert
    // there, and low enough that a release SUT logging an assert every frame
    // cannot exhaust node's heap before the logic reads the log.
    const maxLogArg = process.argv.find((a) => a.startsWith("--max-log="));
    const state = {
      nextHandle: 1,
      nowMs: 0,
      mem: null,
      maxLog: maxLogArg ? Number(maxLogArg.slice("--max-log=".length)) : 500000,
      traceCalls: process.argv.includes("--trace-calls"),
    };
    const imports = {};
    for (const nsName of Object.keys(importSpec.namespaces || {})) {
      imports[nsName] = makeShim(log, importSpec.namespaces[nsName], voidNames, unhandled, state);
    }
    // memory is sometimes imported; provide one if the SUT wants it.
    if (!imports.env) imports.env = {};
    let instance;
    try {
      const module = new WebAssembly.Module(bytes);
      // Any import namespace the SUT declares that we didn't get a name list
      // for still needs to exist — wrap the whole imports object in a Proxy
      // so unknown namespaces yield Proxy shims too.
      const importsProxy = new Proxy(imports, {
        get(target, prop) {
          if (prop in target) return target[prop];
          if (typeof prop !== "string") return undefined;
          return makeShim(log, [], voidNames, unhandled, state);
        },
      });
      instance = new WebAssembly.Instance(module, importsProxy);
    } catch (err) {
      this.eprint("instantiate failed: " + (err && err.message ? err.message : err));
      return -1;
    }
    const id = nextSutId++;
    state.mem = instance.exports.memory || null;
    suts.set(id, { instance, log, voidNames, unhandled });
    return id;
  },
  sutExports(id) {
    const s = suts.get(id);
    if (!s) return [];
    return Object.keys(s.instance.exports);
  },
  sutCall(id, name, ...args) {
    const s = suts.get(id);
    if (!s) return 0;
    const fn = s.instance.exports[name];
    if (typeof fn !== "function") {
      throw new Error("export not callable: " + name);
    }
    const r = fn(...args);
    return typeof r === "number" ? r : 0;
  },
  // ---- additions for the transpiler-corpus test (Phase 5c) -------------
  // Some SUT exports return a packed 64-bit value (ptr|len) as a BigInt.
  // Split it into [ptrLo32, lenHi32] so the wasm32 test logic (no i64
  // ergonomics through the bridge) gets two plain numbers. Returns null on
  // a 0/throw (the test reads that as transpile failure).
  sutCallPacked(id, name, ...args) {
    const s = suts.get(id);
    if (!s) return null;
    const fn = s.instance.exports[name];
    if (typeof fn !== "function") return null;
    let packed;
    try {
      packed = fn(...args);
    } catch {
      return null;
    }
    const big = BigInt(packed);
    if (big === 0n) return null;
    return {
      ptr: Number(big & 0xffffffffn),
      len: Number((big >> 32n) & 0xffffffffn),
    };
  },
  // Write bytes (a normal array of byte values) into the SUT's linear
  // memory at `ptr`. Used to place SPIR-V into the transpiler's input buffer.
  sutMemWrite(id, ptr, bytes) {
    const s = suts.get(id);
    if (!s) return false;
    const mem = new Uint8Array(s.instance.exports.memory.buffer);
    mem.set(bytes, ptr);
    return true;
  },
  // Read `len` bytes from the SUT's memory at `ptr` as a normal byte array.
  sutMemRead(id, ptr, len) {
    const s = suts.get(id);
    if (!s) return [];
    const mem = new Uint8Array(s.instance.exports.memory.buffer);
    return Array.from(mem.subarray(ptr, ptr + len));
  },
  // The SUT's current linear-memory size in bytes. Wasm memory never shrinks, so
  // this is a HIGH-WATER mark. Read HOST-SIDE from the SUT's own memory buffer —
  // this adds NO code to the example wasm, so it does NOT perturb the example's
  // transpiled output (a wasm-side @wasmMemorySize export would, and that shifts
  // codegen enough to trip latent transpiler edge cases). The smoke's twice-
  // lifecycle probe diffs this: growth from lifecycle 1 to lifecycle 2 means
  // lifecycle 2 could not reuse lifecycle 1's freed space — a per-lifecycle CPU
  // leak (the non-GPU twin of the handle census).
  sutMemBytes(id) {
    const s = suts.get(id);
    if (!s) return 0;
    const m = s.instance.exports.memory;
    return m ? m.buffer.byteLength : 0;
  },
  // Recursively list files under `root` ending in `suffix`, newline-joined.
  listFiles(root, suffix) {
    const out = [];
    const walk = (dir) => {
      let entries;
      try {
        entries = readdirSync(dir, { withFileTypes: true });
      } catch {
        return;
      }
      for (const e of entries) {
        const p = dir + "/" + e.name;
        if (e.isDirectory()) walk(p);
        else if (e.isFile() && e.name.endsWith(suffix)) out.push(p);
      }
    };
    walk(root);
    out.sort();
    return out.join("\n");
  },
  // MD5 of a file's bytes as lowercase hex (or "" if unreadable). Hashing the
  // raw SPIR-V; the test does WGSL hashing in Zig via std.crypto.
  md5File(path) {
    try {
      return createHash("md5").update(readFileSync(path)).digest("hex");
    } catch {
      return "";
    }
  },
  // File size in bytes (-1 if unreadable). Used to sort shaders small-first.
  fileSize(path) {
    try {
      return statSync(path).size;
    } catch {
      return -1;
    }
  },
  // Write a string to a file (creating parent dirs). For --refresh-fixture.
  writeFile(path, text) {
    try {
      const slash = path.lastIndexOf("/");
      if (slash > 0) mkdirSync(path.slice(0, slash), { recursive: true });
      writeFileSync(path, text);
      return true;
    } catch {
      return false;
    }
  },
  sutCallLog(id) {
    const s = suts.get(id);
    return s ? s.log.slice() : [];
  },
  sutResetLog(id) {
    const s = suts.get(id);
    if (s) s.log.length = 0;
  },
};

globalThis.__host = host;

// The test-logic module path is argv[0] after the script name; everything
// after is passed through to the logic via __host.argv() (which slices from
// argv[2], i.e. the same list minus the logic-module path the loader consumed).
const logicPath = process.argv[2];
if (!logicPath) {
  process.stderr.write("usage: node runner.mjs <logic.js> [args...]\n");
  process.exit(2);
}
// Re-base argv so the logic sees its own args starting after the logic path.
process.argv = [process.argv[0], logicPath, ...process.argv.slice(3)];

// c2js emits a bare script that DEFINES the entry (`_start`) in its own
// scope but does not call it (the --html path calls start() from an inline
// <script>; there's no auto-invoke in bare mode, and an ESM import would
// leave _start module-private). So we read the text, evaluate it in this
// scope via indirect eval, then invoke the entry. The kernel (js_* fns,
// __HEAPU8, etc.) is defined by that same text and stays available to it.
const logicSrc = readFileSync(logicPath, "utf8");
// Indirect eval runs in global scope; the c2js kernel declares its js_*
// helpers and the entry there. Append an invocation of the entry.
const entry = host.__entry || "_start";
(0, eval)(logicSrc + "\n;if (typeof " + entry + " === 'function') " + entry + "();\n");
