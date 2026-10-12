// The audio worklet's program, tested in Node: `zig build audio-worklet-test` runs
//     node tools/c2js_cases/audio_worklet_test.cjs <the transpiled worklet program> <the test module's .wasm>
// The program runs as an audio worklet would load it: strict mode, no atob, TextDecoder or TextEncoder, a stand-in
// AudioWorkletProcessor whose port records what is posted. The module (src/audio_worklet_test_module.zig) plays both
// parts of a page: instantiated here as the main thread's instance, its test entry points make commands with a real
// mixer; handed to the processor, it is the worklet's instance. The commands travel as the bytes the mixer wrote.
const fs = require('fs');
const assert = require('assert');
const [programPath, wasmPath] = process.argv.slice(2);

// ---- The worklet's global scope ----
globalThis.atob = undefined;
globalThis.TextDecoder = undefined;
globalThis.TextEncoder = undefined;
// A worklet's scope has its clock, `currentFrame`; the program's reports read it.
globalThis.currentFrame = 0;
// A Float32Array that counts the views made over a buffer - the program's views of its instance's memory; the
// harness's own channel arrays, made by length, are not counted - so that the test can require a steady block to make
// none.
let float32ArraysMade = 0;
const NodeFloat32Array = Float32Array;
globalThis.Float32Array = class CountedFloat32Array extends NodeFloat32Array {
  constructor(...constructorArguments) {
    super(...constructorArguments);
    if (constructorArguments[0] instanceof ArrayBuffer) float32ArraysMade += 1;
  }
};
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

// ---- The two instances ----
const compiledModule = new WebAssembly.Module(fs.readFileSync(wasmPath));
const mainSide = new WebAssembly.Instance(compiledModule, {}).exports;
assert.strictEqual(mainSide.zimr_audio_test_start(), 1, 'the main side starts');
const processor = new registered['zimr-renderer']({ processorOptions: { module: compiledModule } });
assert.ok(processor instanceof AudioWorkletProcessor, 'the processor extends AudioWorkletProcessor');
assert.strictEqual(typeof processor.port.onmessage, 'function', 'the processor listens on its port');

const quantumFrames = 128;
function processOneQuantum() {
  const left = new Float32Array(quantumFrames), right = new Float32Array(quantumFrames);
  const keepCalling = processor.process([], [[left, right]], {});
  return { keepCalling, left, right };
}

// The main side's forwarded commands sent as the main thread will send them: the bytes of commands in a row gathered
// into one `commands` message, samples in a `samples` message of their own and a key's event in a `note` message, in
// the order forwarded - so samples arrive before the play that names them.
function forwardToWorklet() {
  const messageCount = mainSide.zimr_audio_test_forward();
  const recordWords = 8;
  const recordsAddress = mainSide.zimr_audio_test_messages();
  const records = new Uint32Array(mainSide.memory.buffer, recordsAddress, messageCount * recordWords);
  const recordFloats = new Float32Array(mainSide.memory.buffer, recordsAddress, messageCount * recordWords);
  let pendingCommandBytes = [];
  const sendPendingCommands = function () {
    if (pendingCommandBytes.length === 0) return;
    const total = pendingCommandBytes.reduce((sum, bytes) => sum + bytes.length, 0);
    const gathered = new Uint8Array(total);
    let offset = 0;
    for (const bytes of pendingCommandBytes) { gathered.set(bytes, offset); offset += bytes.length; }
    processor.port.onmessage({ data: { kind: 'commands', bytes: gathered.buffer } });
    pendingCommandBytes = [];
  };
  for (let index = 0; index < messageCount; index++) {
    const [kind, samplesId, address, byteCount, noteKey, noteIsDown] = records.subarray(index * recordWords);
    if (kind === 0) {
      pendingCommandBytes.push(new Uint8Array(mainSide.memory.buffer, address, byteCount).slice());
    } else if (kind === 2) {
      sendPendingCommands();
      const velocity = recordFloats[index * recordWords + 6];
      processor.port.onmessage({ data: { kind: 'note', key: noteKey, isDown: noteIsDown === 1, velocity } });
    } else {
      sendPendingCommands();
      const samples = new Float32Array(mainSide.memory.buffer, address, byteCount / 4).slice();
      processor.port.onmessage({ data: { kind: 'samples', samplesId, samples } });
    }
  }
  sendPendingCommands();
  return messageCount;
}

// The same quantum, rendered by the main side's own host: one channel after the other.
function renderLocally() {
  const address = mainSide.zimr_audio_test_render_locally(quantumFrames);
  const channels = new Float32Array(mainSide.memory.buffer, address, quantumFrames * 2);
  return { left: channels.slice(0, quantumFrames), right: channels.slice(quantumFrames) };
}

function assertSameSamples(actual, expected, what) {
  for (let index = 0; index < expected.length; index++) {
    if (actual[index] !== expected[index]) {
      assert.fail(what + ': sample ' + index + ' is ' + actual[index] + ', expected ' + expected[index]);
    }
  }
}

// ---- Silence, with no voice ----
for (let quantum = 0; quantum < 3; quantum++) {
  const result = processOneQuantum();
  // Exactly `true`, not merely truthy: Chrome keeps calling a processor with no inputs only while `process`
  // returns the boolean `true` (it checks `IsTrue()`, where the specification says `ToBoolean`) - a 1 there played one
  // block and then silence.
  assert.strictEqual(result.keepCalling, true, 'process returns exactly true');
  assert.ok(result.left.every(s => s === 0) && result.right.every(s => s === 0), 'silence, with no voice');
  renderLocally();
}

// ---- A sine: the generator's own samples, times the centre's gain ----
const sineFrequency = 1000;
const sineVoice = mainSide.zimr_audio_test_play_sine(sineFrequency);
assert.strictEqual(forwardToWorklet(), 1, 'a generator is one command');
const centreGain = Math.fround(Math.SQRT1_2);
for (let quantum = 0; quantum < 4; quantum++) {
  const result = processOneQuantum();
  const firstFrame = quantum * quantumFrames;
  const generatedAddress = mainSide.zimr_audio_test_sine_frames(sineFrequency, firstFrame, quantumFrames);
  const generated = new Float32Array(mainSide.memory.buffer, generatedAddress, quantumFrames * 2);
  const expected = new Float32Array(quantumFrames);
  for (let frame = 0; frame < quantumFrames; frame++) expected[frame] = Math.fround(generated[frame * 2] * centreGain);
  assert.ok(expected.some(s => s !== 0), 'the sine is not silent');
  assertSameSamples(result.left, expected, 'sine, quantum ' + quantum + ', left');
  assertSameSamples(result.right, expected, 'sine, quantum ' + quantum + ', right');
  const local = renderLocally();
  assertSameSamples(result.left, local.left, 'sine against the local renderer, left');
  assertSameSamples(result.right, local.right, 'sine against the local renderer, right');
}
console.log('sine: 4 quanta, the generator times ' + centreGain + ', bit for bit, and as the local renderer');

// ---- A ramp of samples at 24 000 Hz, over the sine, until the buffer ends ----
const rampVoice = mainSide.zimr_audio_test_play_ramp();
assert.strictEqual(forwardToWorklet(), 2, 'a first play of samples is their registration, then the play');
const postedBeforeRamp = posted.length;
let quantaWithRamp = 0;
for (let quantum = 0; quantum < 17; quantum++) {
  const result = processOneQuantum();
  const local = renderLocally();
  assertSameSamples(result.left, local.left, 'ramp, quantum ' + quantum + ', left');
  assertSameSamples(result.right, local.right, 'ramp, quantum ' + quantum + ', right');
  quantaWithRamp++;
}
const notices = posted.slice(postedBeforeRamp);
assert.strictEqual(notices.length, 1, 'the ramp\'s end is one message');
assert.strictEqual(notices[0].kind, 'notices', 'a notices message');
console.log('ramp: ' + quantaWithRamp + ' quanta as the local renderer, then one notice of ' +
  notices[0].bytes.byteLength + ' bytes');

// The notice, handed to the main side as the main thread will: the ramp's voice has ended, the sine's has not.
assert.strictEqual(mainSide.zimr_audio_test_is_playing(rampVoice), 1, 'the ramp plays until its notice is read');
const noticeBytes = new Uint8Array(notices[0].bytes);
new Uint8Array(mainSide.memory.buffer, mainSide.zimr_audio_test_notice_room(), noticeBytes.length).set(noticeBytes);
mainSide.zimr_audio_test_accept_notices(noticeBytes.length);
assert.strictEqual(mainSide.zimr_audio_test_is_playing(rampVoice), 0, 'the notice names the ramp\'s slot');
assert.strictEqual(mainSide.zimr_audio_test_is_playing(sineVoice), 1, 'and not the sine\'s');

// ---- A note: the instrument set and a key's events sent on the main side, as an app reading its keys at the frame ----
mainSide.zimr_audio_test_set_instrument();
assert.strictEqual(mainSide.zimr_audio_test_send_note(69, 1, 0.5), 1, 'the key down is queued');
assert.strictEqual(forwardToWorklet(), 2, 'the instrument is a command, the key down a note');
for (let quantum = 0; quantum < 8; quantum++) {
  const result = processOneQuantum();
  const local = renderLocally();
  assertSameSamples(result.left, local.left, 'note held, quantum ' + quantum + ', left');
  assertSameSamples(result.right, local.right, 'note held, quantum ' + quantum + ', right');
}
assert.strictEqual(mainSide.zimr_audio_test_send_note(69, 0, 0), 1, 'the key up is queued');
assert.strictEqual(forwardToWorklet(), 1, 'the key up is a note');
for (let quantum = 0; quantum < 8; quantum++) {
  const result = processOneQuantum();
  const local = renderLocally();
  assertSameSamples(result.left, local.left, 'note released, quantum ' + quantum + ', left');
  assertSameSamples(result.right, local.right, 'note released, quantum ' + quantum + ', right');
}
console.log('note: key 69 held 8 quanta and released 8, as the local renderer');

// ---- Handles: none kept by a callback ----
const tableLengthBefore = program.handleTableLength();
const freeSlotsBefore = program.freeSlotCount();
const float32ArraysBefore = float32ArraysMade;
for (let call = 0; call < 2000; call++) {
  processOneQuantum();
  if (call % 10 === 0) {
    processor.port.onmessage({ data: { kind: 'commands', bytes: new ArrayBuffer(0) } });
  }
}
// Live handles - the table's slots less its free ones - are what a leak would grow; the table itself may grow by the
// most handles one callback holds at once, then keeps them as free slots.
const liveBefore = tableLengthBefore - freeSlotsBefore;
const liveAfter = program.handleTableLength() - program.freeSlotCount();
assert.strictEqual(liveAfter, liveBefore, 'no handle is kept by a callback');
// The rendered block's views are made once and kept: a steady block makes none, so the audio thread's garbage
// collector finds nothing of ours to collect.
assert.strictEqual(float32ArraysMade - float32ArraysBefore, 0, 'no view made by a steady block');
console.log('handles: ' + liveBefore + ' live before 2000 quanta and 200 messages, ' + liveAfter + ' after');
console.log('audio worklet test: passed');
