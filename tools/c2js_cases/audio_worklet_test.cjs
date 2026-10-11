// Run by hand for now: node tools/c2js_cases/audio_worklet_test.cjs <the transpiled worklet program> <an app's .wasm>.
// The audio worklet's program, run in Node as an audio worklet would load it: strict mode, no atob, TextDecoder or
// TextEncoder; a stand-in AudioWorkletProcessor whose port records what is posted; the real browser build's module
// passed in the processor's options.
const fs = require('fs');
const assert = require('assert');
const [programPath, wasmPath] = process.argv.slice(2);
globalThis.atob = undefined;
globalThis.TextDecoder = undefined;
globalThis.TextEncoder = undefined;
const posted = [];
class AudioWorkletProcessor {
  constructor() {
    this.port = { onmessage: null, postMessage: function (sent, transfer) { posted.push(sent); } };
  }
}
globalThis.AudioWorkletProcessor = AudioWorkletProcessor;
const registered = {};
globalThis.registerProcessor = function (name, processorClass) { registered[name] = processorClass; };
const source = fs.readFileSync(programPath, 'utf8');
const program = new Function('"use strict";\n' + source +
  '\nreturn { start, handleTableLength: function () { return __H.length; }, freeSlotCount: function () { return __Hf.length; } };')();
program.start();
assert.ok(registered['zimr-renderer'], 'the processor is registered under its name');
const compiledModule = new WebAssembly.Module(fs.readFileSync(wasmPath));
const processor = new registered['zimr-renderer']({ processorOptions: { module: compiledModule } });
assert.ok(processor instanceof AudioWorkletProcessor, 'the processor extends AudioWorkletProcessor');
assert.strictEqual(typeof processor.port.onmessage, 'function', 'the processor listens on its port');
function processOneQuantum() {
  const left = new Float32Array(128), right = new Float32Array(128);
  const keepCalling = processor.process([], [[left, right]], {});
  return { keepCalling, left, right };
}
for (let quantum = 0; quantum < 3; quantum++) {
  const result = processOneQuantum();
  assert.strictEqual(result.keepCalling, 1, 'process asks to be kept');
  assert.ok(result.left.every(s => s === 0) && result.right.every(s => s === 0), 'silence, with no voice');
}
const ramp = new Float32Array(960).map((_, index) => index / 2048);
processor.port.onmessage({ data: { kind: 'samples', samplesId: 0, samples: ramp } });
processor.port.onmessage({ data: { kind: 'commands', bytes: new ArrayBuffer(0) } });
const tableLengthBefore = program.handleTableLength();
const freeSlotsBefore = program.freeSlotCount();
for (let call = 0; call < 2000; call++) {
  processOneQuantum();
  if (call % 10 === 0) {
    processor.port.onmessage({ data: { kind: 'commands', bytes: new ArrayBuffer(0) } });
  }
}
const tableLengthAfter = program.handleTableLength();
const freeSlotsAfter = program.freeSlotCount();
console.log('handle table: ' + tableLengthBefore + ' slots before, ' + tableLengthAfter + ' after 2000 quanta and 200 messages; free slots ' +
  freeSlotsBefore + ' -> ' + freeSlotsAfter + '; notices posted: ' + posted.length);
// Live handles - the table's slots less its free ones - are what a leak would grow; the table itself may grow by the
// most handles one callback holds at once, then keeps them as free slots.
const liveBefore = tableLengthBefore - freeSlotsBefore;
const liveAfter = tableLengthAfter - freeSlotsAfter;
console.log('live handles: ' + liveBefore + ' before, ' + liveAfter + ' after');
assert.strictEqual(liveAfter, liveBefore, 'no handle is kept by a callback');
console.log('worklet program: registered, linked the module, silent quanta, messages taken');
