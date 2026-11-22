// Runs one transpiled case as a page runs it - sloppy mode, the built-ins present - and prints run_test()'s result
// (or JS_ERROR and the first line of why). c2js_diff.zig compares it with the native program's answer, and with
// run_as_worklet.js's.
// Usage: node run_as_page.js <transpiled case>.
const fs = require('fs');
const source = fs.readFileSync(process.argv[2], 'utf8');
try {
  const runTest = new Function(source + '\nreturn run_test;')();
  console.log(runTest());
} catch (error) {
  console.log('JS_ERROR:' + String(error && error.message).split('\n')[0]);
}
