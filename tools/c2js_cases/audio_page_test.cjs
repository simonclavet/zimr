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
  resume() { this.state = 'running'; return Promise.resolve(); }
  suspend() { this.state = 'suspended'; return Promise.resolve(); }
  close() { this.state = 'closed'; return Promise.resolve(); }
  // The rendering loop: one block of 128 frames to each connected node whose processor is alive, as Chrome renders
  // a graph - calling `process` again only while it returned exactly `true`. Returns each block's left channel.
  render(blockCount) {
    const leftBlocks = [];
    for (let block = 0; block < blockCount; block++) {
      if (this.state !== 'running') break;
      const left = new Float32Array(128);
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
      }
      leftBlocks.push(left);
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
      prepareRenderer: page_audio_prepare_renderer,
      isRendererSettled: page_audio_is_renderer_settled,
      setAppExports: page_audio_set_app_exports,
      startForwarding: page_audio_start_forwarding,
      forwardCommandBytes: page_audio_forward_command_bytes,
      forwardSamples: page_audio_forward_samples,
      forwardNote: page_audio_forward_note,
      takeNoticeBytes: page_audio_take_notice_bytes,
      startPulled: page_audio_start_pulled,
      outputLatencyMs: page_audio_output_latency_ms,
      pathCode: page_audio_path_code,
      noteMixer: page_audio_note_mixer,
      showDiagnostics: page_audio_show_diagnostics,
      stop: page_audio_stop,
    };`)();
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
  assert.strictEqual(pageAudio.startForwarding(2), 48000, 'the node starts, at the context\'s rate');
  const context = globalThis.lastContext;
  assert.strictEqual(pageAudio.pathCode(), 5, 'the processor ready, the context waiting for a gesture');
  assert.deepStrictEqual(document.listenedEvents.map((listened) => listened.type),
    ['keydown', 'pointerdown', 'pointerup', 'touchend', 'click'], 'the gestures listened for');
  assert.ok(document.listenedEvents.every((listened) => listened.isCapture), 'in the capture phase');
  // A tap: the gesture resumes the context.
  document.listenedEvents[0].handler({});
  await Promise.resolve();
  assert.strictEqual(context.state, 'running', 'resumed by the gesture');
  assert.strictEqual(pageAudio.pathCode(), 3, 'running');

  // The app's mixer forwards as a page's does: each message copied out of the app's memory by page audio.
  function forwardWhatTheAppSent() {
    const messageCount = appExports.zimr_audio_test_forward();
    const recordsAddress = appExports.zimr_audio_test_messages();
    const records = new Uint32Array(appExports.memory.buffer, recordsAddress, messageCount * 8);
    const recordFloats = new Float32Array(appExports.memory.buffer, recordsAddress, messageCount * 8);
    for (let index = 0; index < messageCount; index++) {
      const [kind, samplesId, address, byteCount, noteKey, noteIsDown] = records.subarray(index * 8);
      if (kind === 0) pageAudio.forwardCommandBytes(address, byteCount);
      else if (kind === 1) pageAudio.forwardSamples(samplesId, address, byteCount / 4);
      else if (kind === 2) pageAudio.forwardNote(noteKey, noteIsDown, recordFloats[index * 8 + 6]);
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
  assert.strictEqual(pageAudio.pathCode(), 3, 'no processor error');

  // ---- The panel: its lines written by page audio ----
  pageAudio.noteMixer(1);
  pageAudio.showDiagnostics();
  const panel = document.body.children[0];
  assert.strictEqual(panel.tagName, 'pre', 'a panel at the top of the page');
  assert.strictEqual(intervalCallback.intervalMs, 250, 'refreshed every 250 ms');
  intervalCallback.callback();
  const panelLines = panel.textContent.split('\n');
  assert.strictEqual(panelLines[0], 'audio: renderer worklet | 48000 Hz | latency 4 ms + 24 ms');
  assert.strictEqual(panelLines[1], 'playout: 3 glitches, 21 ms filled in | latency 31 ms (24 to 88)');
  assert.ok(panelLines[2].startsWith('renderer: running | 375 blocks (frame 47872, '), panelLines[2]);
  assert.ok(panelLines[2].endsWith('| posted 1 commands, 1 notes, 0 samples'), panelLines[2]);
  assert.ok(/^worklet: longest block \d+\.\d\d ms, longest gap \d+\.\d ms$/.test(panelLines[3]), panelLines[3]);
  assert.strictEqual(panelLines[4], 'mixer: voices 1');
  console.log('page audio, panel:\n  ' + panelLines.join('\n  '));

  // ---- A ramp of samples: registered, played, and its end back as a notice the app takes ----
  appExports.zimr_audio_test_play_ramp();
  forwardWhatTheAppSent();
  context.render(20);
  await Promise.resolve();
  const noticeTargetAddress = appExports.zimr_audio_test_messages();
  const takenByteCount = pageAudio.takeNoticeBytes(noticeTargetAddress, 64, 4);
  assert.strictEqual(takenByteCount, 4, 'the ramp\'s end, one notice of 4 bytes, copied into the app\'s memory');
  assert.strictEqual(pageAudio.takeNoticeBytes(noticeTargetAddress, 64, 4), 0, 'taken once');
  assert.strictEqual(Math.round(pageAudio.outputLatencyMs()), 28, 'past the output: the context\'s 4 + 24 ms');

  // ---- What a frame calls keeps no handle: the page's frame loop reclaims none ----
  const liveBeforeFrames = pageAudio.liveHandleCount();
  for (let frame = 0; frame < 100; frame++) {
    pageAudio.forwardNote(60, frame % 2, 0.5);
    pageAudio.takeNoticeBytes(noticeTargetAddress, 64, 4);
    pageAudio.outputLatencyMs();
    pageAudio.pathCode();
  }
  assert.strictEqual(pageAudio.liveHandleCount(), liveBeforeFrames, 'no handle kept by a frame\'s calls');

  // ---- Stopped: the node let go, the renderer's context suspended for the next start ----
  pageAudio.stop();
  assert.strictEqual(context.state, 'suspended', 'the renderer\'s context suspended, not closed');
  assert.strictEqual(pageAudio.pathCode(), 0, 'no output');

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
  assert.strictEqual(pageAudio.pathCode(), 0, 'the script processor plays');
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
