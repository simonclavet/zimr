// Stands in for an audio worklet's scope, for subclass.zig: AudioWorkletProcessor, whose constructor gives each object
// its port, as the browser's does; and registerProcessor, which - as the browser would - constructs the class it is
// given with options, calls its process once on a block of outputs, and records what it saw.
class AudioWorkletProcessor {
  constructor() {
    this.port = { isBasePort: true };
  }
}
globalThis.AudioWorkletProcessor = AudioWorkletProcessor;
globalThis.registerProcessor = function (name, processorClass) {
  const instance = new processorClass({ value: 42 });
  const firstChannel = new Float32Array(4);
  const keepAlive = instance.process([], [[firstChannel, new Float32Array(4)]], {});
  globalThis.fixtureRecord = {
    isProcessor: instance instanceof AudioWorkletProcessor ? 1 : 0,
    keepAlive: keepAlive === 1 ? 1 : 0,
    firstSample: firstChannel[0],
    portFromBase: instance.port && instance.port.isBasePort ? 1 : 0,
    nameMatches: name === 'zimr-test' ? 1 : 0,
  };
};
