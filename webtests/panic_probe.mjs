// panic_probe.mjs — run a zimr wasm far enough to trap, and PRINT THE PANIC TEXT.
//
// Why this exists: `webtests/runner.mjs` shims every import generically, so
// WASI `fd_write` — which is where Zig's `defaultPanic` writes the message —
// lands in a stub that discards it. The smoke output is then just
// `RuntimeError: unreachable` plus a stack, which names the FUNCTION but not
// WHICH of its asserts fired or with what values. `flushBatch` has two
// assertfs whose messages are 300 words apart in meaning, so the text is the
// whole diagnosis.
//
// Everything else is stubbed to 0. That is enough to reach a host-side assert:
// the assert reads batch/pipeline state the engine itself maintains, not
// anything a real GPU would have to answer.
//
//   node webtests/panic_probe.mjs <wasm> [frames]

import fs from "fs";

const wasmPath = process.argv[2];
const frames = Number(process.argv[3] || 1);

let mem = null;
const decoder = new TextDecoder();

// Decode a WASI ciovec array and print it — this is the panic message.
function fdWrite(fd, iovsPtr, iovsLen, nwrittenPtr) {
  const dv = new DataView(mem.buffer);
  let total = 0;
  let out = "";
  for (let i = 0; i < iovsLen; i += 1) {
    const base = dv.getUint32(iovsPtr + i * 8, true);
    const len = dv.getUint32(iovsPtr + i * 8 + 4, true);
    out += decoder.decode(new Uint8Array(mem.buffer, base, len));
    total += len;
  }
  if (nwrittenPtr) dv.setUint32(nwrittenPtr, total, true);
  process.stdout.write(out);
  return 0;
}

// runner.mjs hands back a FRESH incrementing handle from every non-void import
// (`return state.nextHandle++`). That detail is load-bearing: returning 0 for
// everything makes every GPU handle compare equal, so any assert that compares
// two handles trivially passes and the probe reports a false green. Mirror it.
let nextHandle = 1;
const calls = [];

const stub = (name) => new Proxy({}, {
  get(_t, fn) {
    if (name === "wasi_snapshot_preview1" && fn === "fd_write") return fdWrite;
    if (name === "wasi_snapshot_preview1" && fn === "proc_exit") {
      return (code) => { throw new Error("proc_exit(" + code + ")"); };
    }
    return (...args) => {
      // runner.mjs answers the size queries with a real 800x600 rather than a
      // handle; geometry counts depend on it, so mirror that too or the probe
      // exercises a different code path than the smoke gate does.
      if (fn === "js_surface_get_size" || fn === "js_surface_get_css_size") {
        return (800 << 16) | 600;
      }
      const h = nextHandle++;
      calls.push(fn + "(" + args.join(", ") + ") -> " + h);
      return h;
    };
  },
});

const imports = new Proxy({}, { get: (_t, ns) => stub(ns) });

const bytes = fs.readFileSync(wasmPath);
const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), imports);
mem = instance.exports.memory;

try {
  instance.exports._initialize?.();
  for (let f = 0; f < frames; f += 1) instance.exports.update?.(16.0);
  console.log("\n[probe] completed " + frames + " frame(s) with no trap");
} catch (err) {
  console.log("\n[probe] TRAPPED: " + (err && err.message ? err.message : err));
  console.log("[probe] last host calls before the trap:");
  for (const c of calls.slice(-200)) console.log("    " + c);
}
