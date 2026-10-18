// The audio worklet's program, tested in Node: `zig build audio-worklet-test` runs
//     node tools/c2js_cases/audio_worklet_test.cjs <the transpiled worklet program> <the test module's .wasm>
// The program runs as an audio worklet would load it: strict mode, no atob, TextDecoder or TextEncoder, a stand-in
// AudioWorkletProcessor whose port records what is posted. The module (src/audio_worklet_test_module.zig) plays both
// parts of a page: instantiated here as the main thread's instance, its test entry points make commands with a real
// mixer; handed to the processor, it is the worklet's instance. The commands travel as the bytes the mixer wrote.
const fs = require('fs');
const assert = require('assert');

// What a forwarded message carries, numbered as the test module numbers it (`ForwardedKind`, a record's first word).
const forwardedKind = {
  commands: 0,
  samples: 1,
  note: 2,
  streamFrames: 3,
};

// The three times of a measured start, numbered as the test module numbers them (`StartTime`).
const startTime = {
  requested: 0,
  applied: 1,
  firstFrameOut: 2,
};
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
    // As a browser's port does, `postMessage` reads its transfer list: a freed handle passed as one throws.
    this.port = { onmessage: null, postMessage: function (sent, transfer) { if (transfer !== undefined) { for (const item of transfer) { void item; } } posted.push(sent); } };
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

const quantumFrames = 128;
function processOneQuantum() {
  const left = new Float32Array(quantumFrames), right = new Float32Array(quantumFrames);
  const keepCalling = processor.process([], [[left, right]], {});
  return { keepCalling, left, right };
}

// The module links asynchronously (`WebAssembly.instantiate`): until its promise resolves the processor is not ready -
// it has posted nothing, its port does not listen, and a block asked for meanwhile is silence, still kept running.
assert.strictEqual(posted.length, 0, 'nothing posted before the module is linked');
assert.strictEqual(processor.port.onmessage, null, 'the port does not listen before the module is linked');
const blockBeforeReady = processOneQuantum();
assert.strictEqual(blockBeforeReady.keepCalling, true, 'process returns exactly true before the module is linked');
assert.ok(blockBeforeReady.left.every(s => s === 0) && blockBeforeReady.right.every(s => s === 0),
  'silence before the module is linked');
async function main() {
  let turnsWaited = 0;
  while (!posted.some(sent => sent.kind === 'ready' || sent.kind === 'failed')) {
    await new Promise(resolve => setImmediate(resolve));
    turnsWaited++;
    assert.ok(turnsWaited < 1000, 'the module is linked within 1000 turns of the event loop');
  }
  assert.strictEqual(posted.length, 1, 'one status posted');
  assert.strictEqual(posted[0].kind, 'ready', 'the processor is ready: ' + JSON.stringify(posted[0]));
  posted.length = 0;
  assert.strictEqual(typeof processor.port.onmessage, 'function', 'the processor listens on its port once ready');
  console.log('start: ready after ' + turnsWaited + ' turns of the event loop, silence before');

  // The main side's forwarded commands sent as the main thread will send them: the bytes of commands in a row gathered
  // into one `commands` message, samples in a `samples` message of their own and a key's event in a `note` message, in
  // the order forwarded - so samples arrive before the play that names them.
  function forwardToWorklet() {
    const messageCount = mainSide.zimr_audio_test_forward();
    const recordWords = mainSide.zimr_audio_test_record_words();
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
      if (kind === forwardedKind.commands) {
        pendingCommandBytes.push(new Uint8Array(mainSide.memory.buffer, address, byteCount).slice());
      } else if (kind === forwardedKind.note) {
        sendPendingCommands();
        const velocity = recordFloats[index * recordWords + 6];
        const requestedAt = recordFloats[index * recordWords + 8];
        const pressedAt = recordFloats[index * recordWords + 9];
        processor.port.onmessage({ data: { kind: 'note', key: noteKey, isDown: noteIsDown === 1, velocity, requestedAt, pressedAt } });
      } else if (kind === forwardedKind.streamFrames) {
        // A stream's frames, copied out of the main side's ring before it is written again: its number, its channels,
        // its rate in the record's last word.
        sendPendingCommands();
        const frames = new Float32Array(mainSide.memory.buffer, address, byteCount / 4).slice();
        const sampleRate = records[index * recordWords + 7];
        processor.port.onmessage({ data: { kind: 'stream', streamId: samplesId, channels: noteKey, sampleRate, frames } });
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

  // The notices the worklet posted since `postedIndex`, handed to the main side as a page's platform hands them: at
  // the next frame, which reads them. Says how many messages they came in.
  function handNoticesToMainSide(postedIndex) {
    const noticeMessages = posted.slice(postedIndex).filter(sent => sent.kind === 'notices');
    const byteCount = noticeMessages.reduce((sum, sent) => sum + sent.bytes.byteLength, 0);
    const room = new Uint8Array(mainSide.memory.buffer, mainSide.zimr_audio_test_notice_room(), byteCount);
    let offset = 0;
    for (const sent of noticeMessages) { room.set(new Uint8Array(sent.bytes), offset); offset += sent.bytes.byteLength; }
    mainSide.zimr_audio_test_accept_notices(byteCount);
    return noticeMessages.length;
  }

  // ---- A stream: the main side's ring of a 750 Hz sine, its frames forwarded and played from the worklet's own ring ----
  // The main side keeps each frame until the worklet reports it read, and refills its ring from what the reports give
  // back, as an app's stream table does each frame. Five rounds of eight quanta - 5 120 frames, two and a half of its
  // ring's 2 048 - so the stream plays on only if the reports return its room.
  const streamVoice = mainSide.zimr_audio_test_play_stream(750);
  assert.notStrictEqual(streamVoice >>> 0, 0xffffffff, 'the stream plays');
  assert.strictEqual(forwardToWorklet(), 2, 'a stream is its start, then its frames');
  let streamQuanta = 0;
  for (let round = 0; round < 5; round++) {
    const postedBeforeRound = posted.length;
    for (let quantum = 0; quantum < 8; quantum++) {
      const result = processOneQuantum();
      const local = renderLocally();
      assert.ok(result.left.some(s => s !== 0), 'the stream sounds, quantum ' + streamQuanta);
      assertSameSamples(result.left, local.left, 'stream, quantum ' + streamQuanta + ', left');
      assertSameSamples(result.right, local.right, 'stream, quantum ' + streamQuanta + ', right');
      streamQuanta++;
    }
    assert.ok(handNoticesToMainSide(postedBeforeRound) >= 1, 'the worklet reports what the stream read');
    assert.ok(mainSide.zimr_audio_test_feed_stream() >= 1024 - 2, 'its room returns as it is read, round ' + round);
    forwardToWorklet();
  }
  // Stopped: its voice fades and ends there; its end, handed back, gives its number up, and the worklet is told to free
  // its ring.
  mainSide.zimr_audio_test_stop_voice(streamVoice);
  forwardToWorklet();
  const postedBeforeEnd = posted.length;
  for (let quantum = 0; quantum < 8; quantum++) {
    processOneQuantum();
    renderLocally();
  }
  handNoticesToMainSide(postedBeforeEnd);
  assert.strictEqual(mainSide.zimr_audio_test_is_playing(streamVoice), 0, 'the stream\'s voice has ended');
  assert.strictEqual(forwardToWorklet(), 1, 'its ring\'s release is one command');
  console.log('stream: ' + streamQuanta + ' quanta from the worklet\'s own ring, as the local renderer, its room ' +
    'returned by its reports, its ring released at its end');

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
  // ---- A long session, as the phone runs it: the real renderer in WebAssembly, fed through its port - last, after
  // every comparison with the local renderer, which plays none of it, and alone: the sine above stopped first ----
  // Notes as the two-hand scale star sends them, at its pace - some twelve events a second: the thumb's chord changing
  // every one to two seconds, its three notes at 0.15; the right hand striking and lifting notes of the scale at 0.5
  // between, half of them notes the chord already sounds. Every output sample is checked: finite, within full scale,
  // not subnormal - WebAssembly has no flush-to-zero mode, where the native renderer flushes them - and the renderer's
  // own counts of clicks and of samples it bent under full scale are summed from its stats messages, as the page's
  // panel sums them. The minutes are the run's argument after the module's path, 2 by default.
  {
    const soakMinutes = Number(process.argv[4] || 2);
    const quantaPerSecond = 48000 / quantumFrames;
    const soakQuanta = Math.round(soakMinutes * 60 * quantaPerSecond);
    let randomState = 0x5eed50a4;
    const nextRandom = function () {
      randomState = (randomState * 1664525 + 1013904223) >>> 0;
      return randomState / 4294967296;
    };
    const scaleKeys = [60, 62, 64, 65, 67, 69, 71];
    let thumbKeys = [60, 64, 67];
    const rightHandKeys = [null, null, null, null];
    let quantaUntilChordChange = 0;
    let quantaUntilRightHandEvent = 0;
    let notFiniteCount = 0, pastFullScaleCount = 0, subnormalCount = 0, clickCount = 0, clippedCount = 0;
    let largestJump = 0;
    let firstBadQuantum = null;
    const smallestNormal = 1.1754943508222875e-38;
    mainSide.zimr_audio_test_stop_voice(sineVoice);
    mainSide.zimr_audio_test_set_shepard_instrument();
    forwardToWorklet();
    // The renderer reports its counts every 375 quanta, each report the counts since the one before: the first report
    // after this point would carry the clicks of the sections above, whose test generators start and end abruptly on
    // purpose. Rendered until a report arrives, it is set aside, and the session's counting starts clean.
    posted.length = 0;
    let quantaUntilReport = 0;
    while (!posted.some(sent => sent.kind === 'stats')) {
      processOneQuantum();
      quantaUntilReport++;
      assert.ok(quantaUntilReport <= 400, 'a stats report within 400 quanta');
    }
    posted.length = 0;
    const startedMs = Date.now();
    for (let quantum = 0; quantum < soakQuanta; quantum++) {
      if (quantaUntilChordChange <= 0) {
        for (const key of thumbKeys) mainSide.zimr_audio_test_send_note(key, 0, 0);
        const rootIndex = Math.floor(nextRandom() * 7);
        thumbKeys = [0, 1, 2].map(function (chordNoteIndex) {
          const scaleIndex = rootIndex + 2 * chordNoteIndex;
          return scaleKeys[scaleIndex % 7] + (scaleIndex >= 7 ? 12 : 0);
        });
        for (const key of thumbKeys) mainSide.zimr_audio_test_send_note(key, 1, 0.15);
        quantaUntilChordChange = Math.round((0.5 + 1.5 * nextRandom()) * quantaPerSecond);
      }
      quantaUntilChordChange -= 1;
      if (quantaUntilRightHandEvent <= 0) {
        const finger = Math.floor(nextRandom() * rightHandKeys.length);
        if (rightHandKeys[finger] !== null) {
          mainSide.zimr_audio_test_send_note(rightHandKeys[finger], 0, 0);
          rightHandKeys[finger] = null;
        } else {
          const isChordNote = nextRandom() < 0.5;
          const key = isChordNote ? thumbKeys[Math.floor(nextRandom() * 3)] :
            scaleKeys[Math.floor(nextRandom() * 7)] + 12 * Math.floor(nextRandom() * 2);
          mainSide.zimr_audio_test_send_note(key, 1, 0.5);
          rightHandKeys[finger] = key;
        }
        quantaUntilRightHandEvent = Math.floor(nextRandom() * quantaPerSecond / 5);
      }
      quantaUntilRightHandEvent -= 1;
      forwardToWorklet();
      const result = processOneQuantum();
      for (const channel of [result.left, result.right]) {
        for (const sample of channel) {
          const isFiniteSample = Number.isFinite(sample);
          const isPastFullScale = Math.abs(sample) > 1;
          const isSubnormal = sample !== 0 && Math.abs(sample) < smallestNormal;
          if (!isFiniteSample) notFiniteCount++;
          if (isPastFullScale) pastFullScaleCount++;
          if (isSubnormal) subnormalCount++;
          if ((!isFiniteSample || isPastFullScale) && firstBadQuantum === null) firstBadQuantum = quantum;
        }
      }
      for (const sent of posted) {
        if (sent.kind === 'stats') {
          clickCount += sent.clicks || 0;
          clippedCount += sent.clipped || 0;
          largestJump = Math.max(largestJump, sent.largestJump || 0);
        }
      }
      posted.length = 0;
    }
    const secondsTaken = (Date.now() - startedMs) / 1000;
    console.log('long session: ' + soakMinutes + ' min in ' + secondsTaken.toFixed(1) + ' s - not finite ' + notFiniteCount +
      ', past full scale ' + pastFullScaleCount + ', subnormal ' + subnormalCount + ', clicks ' + clickCount +
      ' (largest jump ' + largestJump.toFixed(4) + '), clipped ' + clippedCount + ', first bad quantum ' + firstBadQuantum);
    assert.strictEqual(notFiniteCount, 0, 'every sample finite');
    assert.strictEqual(pastFullScaleCount, 0, 'every sample within full scale');
    assert.strictEqual(clickCount, 0, 'no click');
    for (const key of thumbKeys) mainSide.zimr_audio_test_send_note(key, 0, 0);
    for (const key of rightHandKeys) if (key !== null) mainSide.zimr_audio_test_send_note(key, 0, 0);
    forwardToWorklet();
    for (let quantum = 0; quantum < 3 * quantaPerSecond; quantum++) processOneQuantum();
    posted.length = 0;
  }


  // ---- The analysis: the renderer's last frames mixed, asked for as an analyser on a page asks ----
  // A note held through 20 quanta - 2 560 frames, more than the 2 048 the renderer keeps - each frame's mean kept as
  // the renderer computes it, in f32; then the worklet asked, and its answer held to those frames, bit for bit.
  assert.strictEqual(mainSide.zimr_audio_test_send_note(64, 1, 0.5), 1, 'the analysis note is queued');
  forwardToWorklet();
  const frameMeans = [];
  for (let quantum = 0; quantum < 20; quantum++) {
    const result = processOneQuantum();
    for (let frame = 0; frame < quantumFrames; frame++) {
      frameMeans.push(Math.fround(Math.fround(result.left[frame] + result.right[frame]) / 2));
    }
  }
  const postedBeforeAnalysis = posted.length;
  processor.port.onmessage({ data: { kind: 'analysis' } });
  const analysisAnswers = posted.slice(postedBeforeAnalysis).filter(sent => sent.kind === 'analysis');
  assert.strictEqual(analysisAnswers.length, 1, 'one answer');
  const analysisFrames = new Float32Array(analysisAnswers[0].bytes);
  assert.strictEqual(analysisFrames.length, 2048, 'the renderer\'s 2 048 frames');
  const lastMeans = frameMeans.slice(frameMeans.length - 2048);
  let differingFrames = 0;
  for (let frame = 0; frame < 2048; frame++) if (analysisFrames[frame] !== lastMeans[frame]) differingFrames++;
  assert.strictEqual(differingFrames, 0, 'the last frames mixed, oldest first, each the mean of its channels');
  assert.ok(analysisFrames.some(sample => sample !== 0), 'the note sounds in them');
  mainSide.zimr_audio_test_send_note(64, 0, 0);
  forwardToWorklet();
  posted.length = 0;
  console.log('analysis: the last 2 048 frames mixed, each the mean of its channels, as the processor played them');

  // ---- Starts measured on the page's clock: the context's timeline tied to it, a note timed by its block ----
  // The page says the context's moment 2 000 ms is rendered at 9 000 ms of its own clock. The next block begins at
  // frame 96 000 of the timeline - 2 000 ms - plus 480 frames, 10 ms: so it is rendered at 9 010 ms, and a note
  // requested at 9 004 ms waits 6 ms for it. The measurement comes back with the worklet's notices.
  assert.strictEqual(mainSide.zimr_audio_test_newest_start(startTime.applied), -1, 'nothing measured before the clocks are tied');
  processor.port.onmessage({ data: { kind: 'clock', contextMs: 2000, pageMs: 9000 } });
  mainSide.zimr_audio_test_set_clock(9004);
  assert.strictEqual(mainSide.zimr_audio_test_send_note(67, 1, 0.5), 1, 'the measured note is queued');
  forwardToWorklet();
  const postedBeforeMeasuredBlock = posted.length;
  globalThis.currentFrame = 96000 + 480;
  processOneQuantum();
  handNoticesToMainSide(postedBeforeMeasuredBlock);
  assert.strictEqual(mainSide.zimr_audio_test_newest_start(startTime.requested), 9004, 'the note was requested at 9 004 ms');
  assert.strictEqual(mainSide.zimr_audio_test_newest_start(startTime.applied), 9010, 'its block, rendered at 9 010 ms of the page');
  assert.strictEqual(mainSide.zimr_audio_test_newest_start(startTime.firstFrameOut), 9010, 'and sent out as it was made');
  mainSide.zimr_audio_test_set_clock(0);
  mainSide.zimr_audio_test_send_note(67, 0, 0);
  forwardToWorklet();
  globalThis.currentFrame = 0;
  posted.length = 0;
  console.log('measured: a note requested at 9 004 ms, its block rendered at 9 010 ms on the page\'s clock');

  console.log('audio worklet test: passed');
}
main().catch(failure => { console.error(failure); process.exit(1); });
