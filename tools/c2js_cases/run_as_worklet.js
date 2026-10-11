// Runs one transpiled case as an audio worklet would load it, and prints run_test()'s result (or JS_ERROR and why).
//
// An audio worklet's module is an ES module, so it runs in strict mode; and its scope, an AudioWorkletGlobalScope,
// has only what the language itself provides - no atob, no TextDecoder, no TextEncoder. c2js's prelude falls back on
// its own base64 and UTF-8 there (__base64Bytes, __utf8Decode, __utf8EncodeInto); this run proves it does, on every
// case the differential suite has, by requiring the same result as the native program.
const fs = require('fs');
const source = fs.readFileSync(process.argv[2], 'utf8');
globalThis.atob = undefined;
globalThis.TextDecoder = undefined;
globalThis.TextEncoder = undefined;
try {
  const runTest = new Function('"use strict";\n' + source + '\nreturn run_test;')();
  console.log(String(runTest()));
} catch (error) {
  console.log('JS_ERROR:' + (error && error.message));
}
