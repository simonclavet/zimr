// Runs one JS-only case (tools/c2js_cases/js_cases): installs its fixture - the JavaScript objects the case reaches -
// then runs it as a page runs it ("page": the built-ins present) or as an audio worklet loads it ("worklet": strict
// mode, and no atob, TextDecoder or TextEncoder). Prints run_test()'s result, or JS_ERROR and why.
// Usage: node run_js_case.js <transpiled case> <fixture> <page | worklet>.
const fs = require('fs');
const [programPath, fixturePath, mode] = process.argv.slice(2);
const source = fs.readFileSync(programPath, 'utf8');
const fixture = fs.readFileSync(fixturePath, 'utf8');
if (mode === 'worklet') {
  globalThis.atob = undefined;
  globalThis.TextDecoder = undefined;
  globalThis.TextEncoder = undefined;
}
try {
  new Function(fixture)();
  const strictness = mode === 'worklet' ? '"use strict";\n' : '';
  const runTest = new Function(strictness + source + '\nreturn run_test;')();
  console.log(String(runTest()));
} catch (error) {
  console.log('JS_ERROR:' + (error && error.message));
}
