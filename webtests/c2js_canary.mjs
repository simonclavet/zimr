// Runs the c2js CANARY: evaluates the transpiled JS and compares the runtime
// battery against the comptime-folded oracle baked into the same module.
//
// A mismatch means c2js lowered some operation to a WRONG VALUE — the failure
// mode that ships green through build, lint, fmt and verify_imports (see the
// header of webtests/c2js_canary.zig). Exit 1 on any disagreement.
//
// Usage: node webtests/c2js_canary.mjs <transpiled.js>
import fs from "node:fs";

const path = process.argv[2];
if (!path) {
  console.error("usage: node c2js_canary.mjs <transpiled.js>");
  process.exit(2);
}

const src = fs.readFileSync(path, "utf8");

// The generated file is a bare script of top-level functions plus its own heap
// setup, so evaluating it in a fresh Function scope is enough to initialise it.
let mod;
try {
  mod = new Function(`${src}\nreturn { canary, canaryExpected, canarySeed };`)();
} catch (e) {
  console.error(`CANARY FAIL: transpiled JS did not evaluate: ${e.message}`);
  process.exit(1);
}

for (const name of ["canary", "canaryExpected", "canarySeed"]) {
  if (typeof mod[name] !== "function") {
    console.error(`CANARY FAIL: transpiled JS is missing '${name}'`);
    process.exit(1);
  }
}

const seed = mod.canarySeed() >>> 0;
const want = mod.canaryExpected() >>> 0;
const got = mod.canary(seed) >>> 0;

const hex = (n) => `0x${n.toString(16).padStart(8, "0")}`;

if (got !== want) {
  console.error(`CANARY FAIL: seed ${hex(seed)}`);
  console.error(`  comptime oracle (never touches c2js): ${hex(want)}`);
  console.error(`  transpiled runtime path:              ${hex(got)}`);
  console.error("  => c2js is lowering some integer operation to a wrong value.");
  console.error("     Diff the emitted JS for the battery against lib/zig.h.");
  process.exit(1);
}

// A seed-independent oracle would be a tautology, so prove the runtime path
// actually varies with its input rather than returning a folded constant.
const other = mod.canary((seed ^ 0x5bf03635) >>> 0) >>> 0;
if (other === got) {
  console.error("CANARY FAIL: canary() ignored its seed — the runtime path was");
  console.error("  constant-folded, so this test proves nothing. Make battery()");
  console.error("  depend on its argument again.");
  process.exit(1);
}

console.log(`CANARY PASS: seed ${hex(seed)} -> ${hex(got)} (matches comptime oracle)`);
