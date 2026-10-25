// The page's sound output, tested in Node: `zig build audio-page-test` runs
//     node tools/c2js_cases/audio_page_test.cjs <page audio's program> <the worklet's program> <the test module's .wasm>
// `src/page_audio.zig`, transpiled on its own (its entry points `page_audio_*`), loads the renderer worklet at boot,
// starts its node and forwards to it, as the bridge has it do in a page - against a stand-in browser that follows
// Chrome where Chrome is stricter than the specification:
//   - the rendering loop calls a processor with no inputs again only while `process` returned exactly `true`
//     (Chrome's `IsTrue()`; the specification's `ToBoolean` would accept a 1, which once played one block, then
//     silence);
//   - an exception from a processor's constructor or `process` fires the node's `processorerror`, and the processor
//     is not called again;
//   - a port holds the messages posted to it until its handler is set;
//   - the worklet's scope has `currentFrame` and `sampleRate`, and no `atob`, `TextDecoder` or `TextEncoder`.
// The test module (src/audio_worklet_test_module.zig) stands for the app: its mixer makes the commands, its memory is
// what page audio copies them from, and it is the module the worklet runs. The test plays a held note for 400 blocks
// and requires sound to the end; then a ramp, whose end comes back as a notice; then the pulled path; then the panel.
const fs = require('fs');
const assert = require('assert');

// What a forwarded message carries, numbered as the test module numbers it (`ForwardedKind`, a record's first word).
const forwardedKind = {
  commands: 0,
  samples: 1,
  note: 2,
  streamFrames: 3,
};

// The output's statuses, numbered as page audio numbers them (`page_audio.OutputStatus`).
const outputStatus = {
  scriptProcessor: 0,
  workletStarting: 1,
  workletRunning: 2,
  workletFailed: 3,
  workletWaitingForGesture: 4,
};
const [pageAudioProgramPath, rendererProgramPath, moduleWasmPath] = process.argv.slice(2);

// ---- The stand-in browser ----
const blobs = new Map();
let blobCount = 0;
globalThis.Blob = class { constructor(parts) { this.text = parts.join(''); } };
globalThis.URL = {
  createObjectURL(blob) { const url = 'blob:test/' + (blobCount++); blobs.set(url, blob.text); return url; },
  revokeObjectURL(url) { blobs.delete(url); },
};
// A document: the gesture listener's events, and the diagnostics panel's element.
globalThis.document = {
  listenedEvents: [],
  addEventListener(type, handler, isCapture) { this.listenedEvents.push({ type, handler, isCapture }); },
  createElement(tagName) { return { tagName, style: {}, textContent: '' }; },
  body: { children: [], appendChild(child) { this.children.push(child); } },
};
// The panel's refresh: kept for the test to call, rather than run by Node's timer.
let intervalCallback = null;
globalThis.setInterval = (callback, intervalMs) => { intervalCallback = { callback, intervalMs }; return 1; };

// A port that holds what is posted to it until its handler is set, as a MessagePort does.
function makePort() {
  const held = [];
  let handler = null;
  const port = { other: null };
  Object.defineProperty(port, 'onmessage', {
    get() { return handler; },
    set(newHandler) { handler = newHandler; while (handler && held.length > 0) handler({ data: held.shift() }); },
  });
  port.postMessage = function (message) {
    const receiver = port.other;
    if (receiver.onmessage) receiver.onmessage({ data: message });
    else receiver.held.push(message);
  };
  port.held = held;
  return port;
}
function makePortPair() {
  const first = makePort();
  const second = makePort();
  first.other = second;
  second.other = first;
  return [first, second];
}

// The worklet's scope: the program runs with these as its globals.
const registered = new Map();
let constructingPort = null;
class AudioWorkletProcessor {
  constructor() { this.port = constructingPort; }
}
function loadWorkletModule(moduleText) {
  globalThis.AudioWorkletProcessor = AudioWorkletProcessor;
  globalThis.registerProcessor = (name, processorClass) => {
    assert.ok(!registered.has(name), 'a processor name is registered once: ' + name);
    registered.set(name, processorClass);
  };
  globalThis.currentFrame = 0;
  globalThis.sampleRate = 48000;
  globalThis.atob = undefined;
  globalThis.TextDecoder = undefined;
  globalThis.TextEncoder = undefined;
  new Function('"use strict";\n' + moduleText)();
}

class AudioWorkletNode {
  constructor(context, name, options) {
    const processorClass = registered.get(name);
    if (!processorClass) throw new Error('InvalidStateError: no processor named ' + name);
    const [nodePort, processorPort] = makePortPair();
    this.port = nodePort;
    this.onprocessorerror = null;
    this.outputChannelCount = options.outputChannelCount[0];
    this.isAlive = true;
    this.context = context;
    constructingPort = processorPort;
    try {
      this.processor = new processorClass({ processorOptions: options.processorOptions });
    } catch (error) {
      this.isAlive = false;
      this.failWith(error);
    }
    constructingPort = null;
  }
  failWith(error) {
    this.isAlive = false;
    const node = this;
    queueMicrotask(() => { if (node.onprocessorerror) node.onprocessorerror({ message: String(error) }); });
  }
  connect(destination) { this.context.connectedNodes.push(this); }
  disconnect() { this.context.connectedNodes = this.context.connectedNodes.filter((node) => node !== this); }
}
globalThis.AudioWorkletNode = AudioWorkletNode;

class AudioContext {
  constructor(options) {
    globalThis.lastContext = this;
    this.sampleRate = (options && options.sampleRate) || 44100;
    this.state = 'suspended';
    this.baseLatency = 0.004;
    this.outputLatency = 0.024;
    // Chrome's own account of its playing: the frames it filled itself, and the latency it measured.
    this.playoutStats = {
      fallbackFramesEvents: 3,
      fallbackFramesDuration: 21.3,
      averageLatency: 31.4,
      minimumLatency: 24,
      maximumLatency: 88,
    };
    // The output's map of what it plays when, as Chrome gives it: a point of the context's timeline, and when the
    // speaker plays it on the page's clock. The test moves it by hand.
    this.outputTimestamp = { contextTime: 0, performanceTime: 0 };
    this.destination = {};
    this.connectedNodes = [];
    this.scriptProcessors = [];
    this.audioWorklet = {
      addModule: (url) => {
        const text = url.startsWith('blob:') ? blobs.get(url) : decodeURIComponent(url.split(',')[1]);
        loadWorkletModule(text);
        return Promise.resolve();
      },
    };
  }
  // A script processor: the browser calls its `onaudioprocess` for each buffer of `bufferSize` frames.
  createScriptProcessor(bufferSize, inputChannelCount, outputChannelCount) {
    const processor = { bufferSize, outputChannelCount, onaudioprocess: null, connect() {}, disconnect() {} };
    this.scriptProcessors.push(processor);
    return processor;
  }
  getOutputTimestamp() { return { contextTime: this.outputTimestamp.contextTime, performanceTime: this.outputTimestamp.performanceTime }; }
  resume() { this.state = 'running'; return Promise.resolve(); }
  suspend() { this.state = 'suspended'; return Promise.resolve(); }
  close() { this.state = 'closed'; return Promise.resolve(); }
  // The rendering loop: one block of 128 frames to each connected node whose processor is alive, as Chrome renders
  // a graph - calling `process` again only while it returned exactly `true`. Returns each block's left channel.
  render(blockCount) {
    const leftBlocks = [];
    // The right channel's blocks too, beside the left the call returns: an analyser's frames are both channels' mean.
    this.lastRightBlocks = [];
    for (let block = 0; block < blockCount; block++) {
      if (this.state !== 'running') break;
      const left = new Float32Array(128);
      const right = new Float32Array(128);
      for (const node of this.connectedNodes) {
        if (!node.isAlive) continue;
        const channels = [];
        for (let channel = 0; channel < node.outputChannelCount; channel++) channels.push(new Float32Array(128));
        try {
          const result = node.processor.process([], [channels], {});
          if (result !== true) node.isAlive = false;
        } catch (error) {
          node.failWith(error);
        }
        for (let frame = 0; frame < 128; frame++) left[frame] += channels[0][frame];
        for (let frame = 0; frame < 128; frame++) right[frame] += channels[1][frame];
      }
      leftBlocks.push(left);
      this.lastRightBlocks.push(right);
      globalThis.currentFrame += 128;
    }
    return leftBlocks;
  }
}
globalThis.AudioContext = AudioContext;

function loudestOf(blocks) {
  let loudest = 0;
  for (const block of blocks) for (const sample of block) loudest = Math.max(loudest, Math.abs(sample));
  return loudest;
}

(async function () {
  // Page audio's program, its entry points, and the runtime's table - through which a value crosses as a handle.
  const pageAudio = new Function('"use strict";\n' + fs.readFileSync(pageAudioProgramPath, 'utf8') + `
    return {
      handleOf: __href,
      liveHandleCount: () => __H.length - __Hf.length,
      // A frame's handle scope, as the bridge opens one around each frame of a page.
      markHandles: js_mark,
      resetHandles: js_reset,
      // The runtime's handles, for its own checks below.
      freeHandle: js_free,
      pinHandle: js_pin,
      tableLength: js_table_length,
      setHandleDebugging: js_set_handle_debugging,
      handleCensus: (limit) => __H[js_handle_census(limit)],
      valueOf: (h) => __H[h],
      registerPromise: js_promise_register,
      promiseStatus: js_promise_status,
      takePromise: js_promise_take,
      promiseRegistryLength: () => __P.length,
      prepareRenderer: page_audio_prepare_renderer,
      isRendererSettled: page_audio_is_renderer_settled,
      setAppExports: page_audio_set_app_exports,
      startForwarding: page_audio_start_forwarding,
      forwardCommandBytes: page_audio_forward_command_bytes,
      forwardSamples: page_audio_forward_samples,
      forwardNote: page_audio_forward_note,
      takeNoticeBytes: page_audio_take_notice_bytes,
      askAnalysis: page_audio_ask_analysis,
      takeAnalysisFrames: page_audio_take_analysis_frames,
      startPulled: page_audio_start_pulled,
      outputLatencyMs: page_audio_output_latency_ms,
      outputStatus: page_audio_output_status,
      noteMixer: page_audio_note_mixer,
      showDiagnostics: page_audio_show_diagnostics,
      stop: page_audio_stop,
    };`)();
  // ---- The runtime's handles: scopes leave the table flat; debugging names a stale handle's makers and a leak's ----
  {
    // 2 000 frames in scopes, with an event's argument made before and freed after each, and calls returning nothing.
    const lengthBefore = pageAudio.tableLength();
    for (let frame = 0; frame < 2000; frame += 1) {
      const eventArgument = pageAudio.handleOf({ event: frame });
      const frameScope = pageAudio.markHandles();
      for (let k = 0; k < 50; k += 1) pageAudio.handleOf({ k });
      pageAudio.resetHandles(frameScope);
      pageAudio.freeHandle(eventArgument);
      pageAudio.freeHandle(pageAudio.handleOf(undefined));
    }
    assert.ok(pageAudio.tableLength() <= lengthBefore + 2, 'the table grew to ' + pageAudio.tableLength());
    // A launcher's switches: each frame lets the last pin go, makes forty handles, then pins one more - page audio
    // started again, as each app a launcher shows starts it. The free slots below each pin are taken again by the next
    // frame: the table stays as long as after the first.
    let pinnedInFrame = 0;
    let lengthAfterFirstPin = 0;
    for (let frame = 0; frame < 100; frame += 1) {
      const frameScope = pageAudio.markHandles();
      if (pinnedInFrame !== 0) pageAudio.freeHandle(pinnedInFrame);
      for (let k = 0; k < 40; k += 1) pageAudio.handleOf({ k });
      pinnedInFrame = pageAudio.handleOf({ pinnedIn: frame });
      pageAudio.pinHandle(pinnedInFrame);
      pageAudio.resetHandles(frameScope);
      if (frame === 0) lengthAfterFirstPin = pageAudio.tableLength();
    }
    assert.ok(pageAudio.tableLength() <= lengthAfterFirstPin + 1, 'pins grew the table from ' + lengthAfterFirstPin
      + ' to ' + pageAudio.tableLength());
    assert.strictEqual(pageAudio.valueOf(pinnedInFrame).pinnedIn, 99, 'the last pin holds its value');
    pageAudio.freeHandle(pinnedInFrame);
    // A slot freed inside a scope and taken again there is released by the scope's reset.
    const liveBeforeReuse = pageAudio.liveHandleCount();
    const outerHandle = pageAudio.handleOf({ outer: true });
    const reuseScope = pageAudio.markHandles();
    pageAudio.freeHandle(outerHandle);
    assert.strictEqual(pageAudio.handleOf({ inner: true }), outerHandle, 'the scope takes the freed slot');
    pageAudio.resetHandles(reuseScope);
    assert.strictEqual(pageAudio.liveHandleCount(), liveBeforeReuse, 'the slot taken again outlived its scope');
    // Debugging: a stale handle named with where it was made and freed; a leak counted by the code that made it.
    // One handle made before debugging begins, to be counted apart.
    const madeBeforeDebugging = pageAudio.handleOf({ early: true });
    pageAudio.setHandleDebugging(1);
    const madeByTheTest = function madeByTheTest() { return pageAudio.handleOf({ soon: 'freed' }); };
    const freedByTheTest = function freedByTheTest(h) { pageAudio.freeHandle(h); };
    const stale = madeByTheTest();
    freedByTheTest(stale);
    assert.throws(() => pageAudio.valueOf(stale).anything, /used after it was freed - made at .*madeByTheTest.*freed at .*freedByTheTest/);
    const leakingByTheTest = function leakingByTheTest() { for (let k = 0; k < 30; k += 1) pageAudio.handleOf({ k }); };
    leakingByTheTest();
    const censusText = pageAudio.handleCensus(3);
    assert.ok(/^30 x .*leakingByTheTest/.test(censusText), censusText);
    // One line per place, joined by line breaks - the handles made before debugging began counted on a line of their own.
    const censusLines = censusText.split('\n');
    assert.ok(censusLines.length >= 2 && /made before debugging began$/.test(censusLines[censusLines.length - 1]), censusText);
    // The runtime's own functions are not places a handle was made, however they were called.
    assert.ok(!/__href/.test(censusText), censusText);
    pageAudio.freeHandle(madeBeforeDebugging);
    pageAudio.setHandleDebugging(0);
    // A promise each frame, its result taken in a later frame's scope - a GPU readback's shape: the handle is made at
    // the take, in that frame's scope, and reclaimed with it; the registry reuses the taken ids.
    const lengthBeforePromises = pageAudio.tableLength();
    let pending = 0;
    for (let frame = 0; frame < 500; frame += 1) {
      const frameScope = pageAudio.markHandles();
      if (pending !== 0 && pageAudio.promiseStatus(pending) !== 0) {
        pageAudio.valueOf(pageAudio.takePromise(pending));
        pending = 0;
      }
      if (pending === 0) pending = pageAudio.registerPromise(pageAudio.handleOf(Promise.resolve({ readback: frame })));
      pageAudio.resetHandles(frameScope);
      await null;
    }
    assert.ok(pageAudio.tableLength() <= lengthBeforePromises + 2, 'promises grew the table to ' + pageAudio.tableLength());
    assert.ok(pageAudio.promiseRegistryLength() <= 3, 'the registry grew to ' + pageAudio.promiseRegistryLength());
    console.log('runtime: 2 000 scoped frames, the table flat; 100 frames pinning a handle each, the table flat;'
      + ' a slot taken again in a scope released by it; a stale handle named; a leak counted where it was made;'
      + ' 500 frames of promises, the table and the registry flat');
  }

  const compiledModule = new WebAssembly.Module(fs.readFileSync(moduleWasmPath));
  // The app: the test module's own instance, whose mixer makes the commands, in whose memory they wait.
  const appExports = new WebAssembly.Instance(compiledModule, {}).exports;
  assert.strictEqual(appExports.zimr_audio_test_start(), 1, 'the app starts its mixer');
  pageAudio.setAppExports(pageAudio.handleOf(appExports));

  // ---- Boot: the renderer's module loads before the app starts ----
  const rendererProgram = fs.readFileSync(rendererProgramPath, 'utf8');
  pageAudio.prepareRenderer(pageAudio.handleOf(rendererProgram), pageAudio.handleOf(compiledModule));
  assert.strictEqual(pageAudio.isRendererSettled(), 0, 'loading, asynchronously');
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.strictEqual(pageAudio.isRendererSettled(), 1, 'settled');
  assert.ok(registered.has('zimr-renderer'), 'its processor is registered');

  // ---- The app starts its mixer: page audio starts the node ----
  // Inside a frame's handle scope, as on a page: what page audio keeps must be pinned, and survive the scope's end -
  // the slots freed are then taken by fifty new handles, which would overwrite anything kept unpinned.
  const startFrame = pageAudio.markHandles();
  assert.strictEqual(pageAudio.startForwarding(2), 48000, 'the node starts, at the context\'s rate');
  pageAudio.resetHandles(startFrame);
  for (let clobber = 0; clobber < 50; clobber += 1) pageAudio.handleOf({ clobber });
  const context = globalThis.lastContext;
  assert.strictEqual(pageAudio.outputStatus(), outputStatus.workletWaitingForGesture, 'the processor ready, the context waiting for a gesture');
  assert.deepStrictEqual(document.listenedEvents.map((listened) => listened.type),
    ['keydown', 'pointerdown', 'pointerup', 'touchend', 'click'], 'the gestures listened for');
  assert.ok(document.listenedEvents.every((listened) => listened.isCapture), 'in the capture phase');
  // A tap: the gesture resumes the context.
  document.listenedEvents[0].handler({});
  await Promise.resolve();
  assert.strictEqual(context.state, 'running', 'resumed by the gesture');
  assert.strictEqual(pageAudio.outputStatus(), outputStatus.workletRunning, 'running');

  // The app's mixer forwards as a page's does: each message copied out of the app's memory by page audio.
  function forwardWhatTheAppSent() {
    const messageCount = appExports.zimr_audio_test_forward();
    const recordsAddress = appExports.zimr_audio_test_messages();
    const recordWords = appExports.zimr_audio_test_record_words();
    const records = new Uint32Array(appExports.memory.buffer, recordsAddress, messageCount * recordWords);
    const recordFloats = new Float32Array(appExports.memory.buffer, recordsAddress, messageCount * recordWords);
    for (let index = 0; index < messageCount; index++) {
      const [kind, samplesId, address, byteCount, noteKey, noteIsDown] = records.subarray(index * recordWords);
      const noteFloat = (word) => recordFloats[index * recordWords + word];
      if (kind === forwardedKind.commands) pageAudio.forwardCommandBytes(address, byteCount);
      else if (kind === forwardedKind.samples) pageAudio.forwardSamples(samplesId, address, byteCount / 4);
      else if (kind === forwardedKind.note) pageAudio.forwardNote(noteKey, noteIsDown, noteFloat(6), noteFloat(8), noteFloat(9));
    }
  }

  // ---- A held note through the instrument: it sounds to the end of 400 blocks ----
  appExports.zimr_audio_test_set_instrument();
  assert.strictEqual(appExports.zimr_audio_test_send_note(69, 1, 0.5), 1, 'the key down is queued');
  forwardWhatTheAppSent();
  const blocks = context.render(400);
  assert.strictEqual(blocks.length, 400, '400 blocks rendered');
  const firstLoudest = loudestOf(blocks.slice(0, 10));
  const lastLoudest = loudestOf(blocks.slice(390));
  assert.ok(firstLoudest > 0.3, 'the note sounds from the first blocks: ' + firstLoudest);
  assert.ok(lastLoudest > 0.3, 'and still in the last ones - the processor was kept alive: ' + lastLoudest);
  await Promise.resolve();
  assert.strictEqual(pageAudio.outputStatus(), outputStatus.workletRunning, 'no processor error');

  // ---- An analyser's frames: asked of the worklet through page audio, the answer kept, the newest copied over ----
  const analysisRoom = appExports.zimr_audio_test_analysis_room();
  assert.strictEqual(pageAudio.takeAnalysisFrames(analysisRoom, 1024), 0, 'no frames before the first answer');
  pageAudio.askAnalysis();
  assert.strictEqual(pageAudio.takeAnalysisFrames(analysisRoom, 1024), 1024, 'the answer came back through the port');
  const copiedFrames = new Float32Array(appExports.memory.buffer, analysisRoom, 1024);
  const lastLeftFrames = blocks.slice(-8).flatMap((block) => Array.from(block));
  const lastRightFrames = context.lastRightBlocks.slice(-8).flatMap((block) => Array.from(block));
  let differingCopied = 0;
  for (let frame = 0; frame < 1024; frame++) {
    const mean = Math.fround(Math.fround(lastLeftFrames[frame] + lastRightFrames[frame]) / 2);
    if (copiedFrames[frame] !== mean) differingCopied++;
  }
  assert.strictEqual(differingCopied, 0, 'the newest 1 024 frames, each the mean of the last blocks\' channels');
  assert.ok(copiedFrames.some((sample) => sample !== 0), 'the held note in them');
  console.log('page audio, analysis: asked, answered through the port, the newest 1 024 frames copied into the app');

  // ---- The panel: its lines written by page audio ----
  const panelFrame = pageAudio.markHandles();
  pageAudio.noteMixer(1);
  pageAudio.showDiagnostics();
  pageAudio.resetHandles(panelFrame);
  for (let clobber = 0; clobber < 50; clobber += 1) pageAudio.handleOf({ clobber });
  const panel = document.body.children[0];
  assert.strictEqual(panel.tagName, 'pre', 'a panel at the top of the page');
  assert.strictEqual(intervalCallback.intervalMs, 250, 'refreshed every 250 ms');
  // The output's map: the timeline's second 1 played at the page's 5 000 ms, then a reading 250 ms on, unbroken.
  context.outputTimestamp = { contextTime: 1, performanceTime: 5000 };
  intervalCallback.callback();
  context.outputTimestamp = { contextTime: 1.25, performanceTime: 5250 };
  intervalCallback.callback();
  const panelLines = panel.textContent.split('\n');
  assert.strictEqual(panelLines[0], 'audio: renderer worklet | 48000 Hz | latency 4 ms + 24 ms');
  assert.strictEqual(panelLines[1], 'playout: 3 glitches, 21 ms filled in | latency 31 ms (24 to 88)');
  assert.strictEqual(panelLines[2], 'dropouts: none in 0 s | offset: net +0.0 ms, falls up to 0.0 ms');
  assert.ok(panelLines[3].startsWith('renderer: running | 375 blocks (frame 47872, '), panelLines[3]);
  assert.ok(panelLines[3].endsWith('| posted 1 commands, 1 notes, 0 samples'), panelLines[3]);
  // Node gives the worklet `performance`, a fine clock: no word on its resolution.
  assert.ok(/^worklet: longest block \d+\.\d\d ms, mean \d+\.\d\d\d ms, longest gap \d+\.\d ms, handles \d+$/.test(panelLines[4]), panelLines[4]);
  // The mixer's voices, then the page's own frames, timed where the mixer reports each.
  assert.ok(/^mixer: voices 1 \| page frames: longest gap \d+\.\d ms, mean \d+\.\d ms, handles \d+$/.test(panelLines[5]), panelLines[5]);
  console.log('page audio, panel:\n  ' + panelLines.join('\n  '));

  // ---- Dropouts: a step of the speaker's time past the timeline's is silence played ----
  // 9 ms of silence: the speaker's time moves 259 ms while the timeline moves 250.
  context.outputTimestamp = { contextTime: 1.5, performanceTime: 5509 };
  intervalCallback.callback();
  // A slow drift of 0.01 ms is no dropout; then 3 ms more of silence.
  context.outputTimestamp = { contextTime: 1.75, performanceTime: 5759.01 };
  intervalCallback.callback();
  context.outputTimestamp = { contextTime: 2, performanceTime: 6012.01 };
  intervalCallback.callback();
  context.outputTimestamp = { contextTime: 3, performanceTime: 7012.01 };
  intervalCallback.callback();
  const dropoutLine = panel.textContent.split('\n')[2];
  assert.strictEqual(
    dropoutLine,
    'dropouts: 2 in 2 s, 12 ms of silence, the last 1.0 s ago | offset: net +12.0 ms, falls up to 0.0 ms',
  );
  // Suspended, then running again: a pause is no dropout, and the count starts afresh with the next reading.
  context.state = 'suspended';
  intervalCallback.callback();
  context.state = 'running';
  context.outputTimestamp = { contextTime: 3.25, performanceTime: 60000 };
  intervalCallback.callback();
  context.outputTimestamp = { contextTime: 3.5, performanceTime: 60250 };
  intervalCallback.callback();
  assert.strictEqual(panel.textContent.split('\n')[2], 'dropouts: none in 0 s | offset: net +0.0 ms, falls up to 0.0 ms');
  // Jitter: the speaker's time, estimated from a position the output reports in chunks, swings 5 ms up and down. The
  // first rise is counted - nothing tells it from silence yet - and no other: each comes back to the same top. The net
  // shift ends at 0 and the falls say 5 ms: jitter, not silence.
  const jitterOffsets = [5, 0, 5, 0, 5, 0];
  for (let reading = 0; reading < jitterOffsets.length; reading += 1) {
    const contextTime = 3.75 + 0.25 * reading;
    context.outputTimestamp = { contextTime, performanceTime: 56750 + 1000 * contextTime + jitterOffsets[reading] };
    intervalCallback.callback();
  }
  const jitterLine = panel.textContent.split('\n')[2];
  assert.ok(jitterLine.startsWith('dropouts: 1 in 2 s, 5 ms of silence'), jitterLine);
  assert.ok(jitterLine.endsWith('| offset: net +0.0 ms, falls up to 5.0 ms'), jitterLine);
  console.log('page audio, dropouts: ' + dropoutLine + '\npage audio, jitter: ' + jitterLine);

  // ---- A ramp of samples: registered, played, and its end back as a notice the app takes ----
  appExports.zimr_audio_test_play_ramp();
  forwardWhatTheAppSent();
  context.render(20);
  await Promise.resolve();
  const noticeTargetAddress = appExports.zimr_audio_test_messages();
  const noticeByteCount = appExports.zimr_audio_test_notice_byte_count();
  const takenByteCount = pageAudio.takeNoticeBytes(noticeTargetAddress, 64, noticeByteCount);
  assert.strictEqual(takenByteCount, noticeByteCount, 'the ramp\'s end, one notice, copied into the app\'s memory');
  assert.strictEqual(pageAudio.takeNoticeBytes(noticeTargetAddress, 64, noticeByteCount), 0, 'taken once');
  assert.strictEqual(Math.round(pageAudio.outputLatencyMs()), 28, 'past the output: the context\'s 4 + 24 ms');

  // ---- What a frame calls keeps no handle: the page's frame loop reclaims none ----
  const liveBeforeFrames = pageAudio.liveHandleCount();
  for (let frame = 0; frame < 100; frame++) {
    pageAudio.forwardNote(60, frame % 2, 0.5);
    pageAudio.takeNoticeBytes(noticeTargetAddress, 64, 4);
    pageAudio.outputLatencyMs();
    pageAudio.outputStatus();
  }
  assert.strictEqual(pageAudio.liveHandleCount(), liveBeforeFrames, 'no handle kept by a frame\'s calls');

  // ---- Stopped: the node let go, the renderer's context suspended for the next start ----
  pageAudio.stop();
  assert.strictEqual(context.state, 'suspended', 'the renderer\'s context suspended, not closed');
  assert.strictEqual(pageAudio.outputStatus(), outputStatus.scriptProcessor, 'no output');

  // ---- The fallback where no worklet loads: the output pulled on the main thread ----
  // Stand-in app exports: each pull renders a block of known samples - the left channel all 0.25, the right all
  // -0.5 - at a known address, one channel after the other, as `pullAudioBlock` lays them out.
  const pulledMemory = new WebAssembly.Memory({ initial: 1 });
  const pulledBlockAddress = 1024;
  const pulledFrameCounts = [];
  const pulledExports = {
    memory: pulledMemory,
    zimr_audio_pull_block(frameCount) {
      pulledFrameCounts.push(frameCount);
      const block = new Float32Array(pulledMemory.buffer, pulledBlockAddress, frameCount * 2);
      block.fill(0.25, 0, frameCount);
      block.fill(-0.5, frameCount, frameCount * 2);
      return pulledBlockAddress;
    },
  };
  pageAudio.setAppExports(pageAudio.handleOf(pulledExports));
  assert.strictEqual(pageAudio.startPulled(48000, 2), 48000, 'the pulled output starts');
  assert.strictEqual(pageAudio.outputStatus(), outputStatus.scriptProcessor, 'the script processor plays');
  const processorNode = context.scriptProcessors[0];
  assert.ok(processorNode, 'on the context made at boot');
  assert.strictEqual(processorNode.bufferSize, 2048, 'a buffer of 2 048 frames');
  const leftChannel = new Float32Array(2048);
  const rightChannel = new Float32Array(2048);
  const outputBuffer = {
    length: 2048,
    numberOfChannels: 2,
    getChannelData(channel) { return channel === 0 ? leftChannel : rightChannel; },
  };
  processorNode.onaudioprocess({ outputBuffer });
  assert.deepStrictEqual(pulledFrameCounts, [2048], 'one pull for the buffer, of its frames');
  assert.ok(leftChannel.every((sample) => sample === 0.25), 'the left channel copied from the rendered block');
  assert.ok(rightChannel.every((sample) => sample === -0.5), 'the right channel, after it');
  const pulledLatencyMs = pageAudio.outputLatencyMs();
  assert.strictEqual(Math.round(pulledLatencyMs), Math.round(2048 / 48 + 28), 'past the output: the buffer and more');
  pageAudio.stop();
  assert.strictEqual(context.state, 'closed', 'the script processor\'s context closed');
  console.log('page audio, pulled: a buffer of 2 048 frames taken from the app, channel after channel; ' +
    pulledLatencyMs.toFixed(1) + ' ms past the output');
  console.log('page audio: loaded at boot, a held note sounding for 400 blocks (first ' + firstLoudest.toFixed(3) +
    ', last ' + lastLoudest.toFixed(3) + '), a ramp\'s notice taken');
  console.log('audio page test: passed');
})().catch(function (error) {
  console.error(error);
  process.exit(1);
});
