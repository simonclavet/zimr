// webtests/verify_imports.js — does a standalone bundle actually PROVIDE every
// wasm import namespace it declares?
//
//   node webtests/verify_imports.js zig-out/standalone/<app>.html
//
// WHY THIS EXISTS: the engine declared `extern "audio" fn js_audio_*` and the
// smoke harness STUBBED them, so every audio example passed in-sandbox — and then
// died in the browser at `WebAssembly.instantiate` with "Import 'audio': module is
// not an object or function", because bridge.zig never built that namespace. Smoke
// cannot catch this class of bug: it SUPPLIES the very import the browser lacks.
// This runs the bundle's REAL host JS (the c2js output of bridge.zig), lets it
// assemble its importObject, and inspects what it hands to instantiate.
//
// This is the exact failure Simon hit: the wasm imports a module named "audio"
// and instantiate rejected because the host never built one. The only honest
// check is to run the bundle's REAL JS (the c2js output of bridge.zig), let it
// assemble its importObject, and look at what it hands to WebAssembly.instantiate.
//
// The browser is stubbed with an auto-mocking Proxy — enough for the boot to
// reach stage 3 without a canvas or a GPU.
const fs = require("fs");
const RealWasm = WebAssembly; // keep the real one: we stub the sandbox's copy
const vm = require("vm");

const html = fs.readFileSync(process.argv[2], "utf8");

// ---- pull every inline <script> out of the page, in order ----
const scripts = [];
const re = /<script\b[^>]*>([\s\S]*?)<\/script>/g;
let m;
while ((m = re.exec(html)) !== null) scripts.push(m[1]);

let captured = null;      // the importObject the bridge builds
let capturedBytes = null; // the wasm the page tried to instantiate

// An object that answers ANY property with something plausible, so the boot can
// walk through canvas/WebGPU calls it will never really use here.
function mock(name) {
  const f = function () { return mock(name + "()"); };
  return new Proxy(f, {
    get(_t, prop) {
      if (prop === "then") return undefined;          // not a thenable
      if (prop === Symbol.toPrimitive) return () => 1;
      if (prop === "length" || prop === "width" || prop === "height") return 1;
      return mock(name + "." + String(prop));
    },
    set() { return true; },
    apply() { return mock(name + "()"); },
    construct() { return mock("new " + name); },
  });
}

const listeners = {};
const rafQueue = [];
const sandbox = {
  console,
  atob: (b64) => Buffer.from(b64, "base64").toString("binary"),
  btoa: (s) => Buffer.from(s, "binary").toString("base64"),
  TextDecoder, TextEncoder, Uint8Array, Float32Array, Map, Object, Math, JSON, Promise,
  performance: { now: () => Date.now() },
  requestAnimationFrame: (cb) => { rafQueue.push(cb); return rafQueue.length; },
  setTimeout, clearTimeout,
  WebAssembly: {
    // THE CHECK: capture what the host passes as imports.
    instantiate(bytes, imports) {
      captured = imports;
      capturedBytes = bytes;
      return new Promise(() => {}); // never settle: we only want the imports
    },
    instantiateStreaming(_r, imports) {
      captured = imports;
      return new Promise(() => {});
    },
    Module: RealWasm.Module,
  },
  document: {
    addEventListener: (ev, cb) => { (listeners[ev] ||= []).push(cb); },
    createElement: () => mock("element"),
    getElementById: () => mock("el"),
    body: mock("body"),
    head: mock("head"),
    querySelector: () => mock("q"),
  },
  navigator: { gpu: mock("gpu") },
  addEventListener: (ev, cb) => { (listeners[ev] ||= []).push(cb); },
  removeEventListener: () => {},
  location: { href: "http://x/", search: "" },
  fetch: () => Promise.resolve(mock("resp")),
  AudioContext: mock("AudioContext"),
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;
sandbox.self = sandbox;

vm.createContext(sandbox);
for (const src of scripts) {
  try { vm.runInContext(src, sandbox, { timeout: 5000 }); }
  catch (e) { console.log('  [script threw]', String(e).slice(0,140)); }
}
// fire DOMContentLoaded if the page waited for it
for (const cb of listeners["DOMContentLoaded"] || []) {
  try { cb(); } catch (e) { console.log('  [DOMContentLoaded threw]', String(e).slice(0,200)); }
}

// Pump the rAF-driven boot machine, flushing microtasks between frames so the
// async WebGPU stubs settle.
(async () => {
  for (let frame = 0; frame < 200 && !captured; frame++) {
    const q = rafQueue.splice(0);
    for (const cb of q) { try { cb(frame * 16); } catch (e) {} }
    await new Promise((r) => setImmediate(r));
  }
  report();
})();

function report() {
// ---- report ----
if (!captured) {
  console.log("RESULT: instantiate was never reached (boot stalled on a stub)");
  process.exit(2);
}
const keys = Object.keys(captured);
console.log("import namespaces the host provided:", keys.join(", "));
if (!captured.audio) {
  console.log("RESULT: FAIL — no 'audio' namespace  <-- the original bug");
  process.exit(1);
}
// Derive what is REQUIRED from the wasm itself, so this gate stays correct when
// new host functions are added (a hardcoded list silently stops checking them).
let required = [];
try {
  const mod = new RealWasm.Module(capturedBytes);
  required = RealWasm.Module.imports(mod);
} catch (e) {
  console.log("RESULT: could not parse the wasm:", String(e).slice(0, 120));
  process.exit(2);
}
const missing = required.filter(
  (im) => !captured[im.module] || typeof captured[im.module][im.name] === "undefined",
);
const byMod = {};
for (const im of required) byMod[im.module] = (byMod[im.module] || 0) + 1;
console.log("wasm requires:", Object.entries(byMod).map(([m, n]) => `${m}=${n}`).join("  "));
if (missing.length) {
  console.log(`RESULT: FAIL — ${missing.length} unprovided import(s):`);
  for (const im of missing.slice(0, 10)) console.log(`   ${im.module}.${im.name}`);
  process.exit(1);
}
console.log(`RESULT: PASS — all ${required.length} imports provided`);
}
