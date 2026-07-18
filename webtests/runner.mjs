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
  const record = (name, args) => {
    // Record the full call signature so the test logic can classify by name
    // and inspect args if it wants (it splits on "(" for the bare name).
    log.push(name + "(" + args.map((a) => String(a)).join(", ") + ")");
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

  for (const name of names) {
    if (name === "js_device_create_render_pipeline") {
      // (device, layout, vs, fs, descPtr, descLen, labelPtr, labelLen)
      ns[name] = (...args) => {
        record(name, args);
        const h = state.nextHandle++;
        const desc = parsePipelineDesc(args[4] | 0, args[5] | 0);
        const label = readLabel(args[6] | 0, args[7] | 0) || ("pipeline#" + h);
        if (desc) pipeAttach.set(h, { ...desc, label });
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
        const pass = passAttach.get(args[0] | 0);
        const pipe = pipeAttach.get(args[1] | 0);
        if (!pass || !pipe || pass.hasDepth === undefined) return;
        const pipeWantsDepth = pipe.depthFormat !== 0;
        if (pipeWantsDepth !== pass.hasDepth) {
          log.push(
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
        if (msg.indexOf("assert failed") !== -1) log.push("!ASSERT " + msg);
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
        if (label) log.push("LABEL_MAP(" + h + ", " + label + ")");
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
      return (...args) => {
        unhandled.add(prop);
        log.push("!UNHANDLED " + prop + "(" + args.length + " args)");
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
    const state = { nextHandle: 1, nowMs: 0, mem: null };
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
