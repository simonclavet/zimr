// Tests c2js's prelude fallbacks - __base64Bytes, __utf8Decode and __utf8EncodeInto - against the built-ins they stand
// in for where a scope lacks them: atob, TextDecoder and TextEncoder.encodeInto. An audio worklet's scope lacks all
// three, so a transpiled program running there uses the fallbacks; everywhere else it uses the built-ins. Either way
// the program must see the same bytes and the same strings - so every comparison here must be exact.
//
// The fallbacks are taken from a transpiled program, exactly as c2js emitted them: from `function __base64Bytes` up to
// the marker line "// The prelude's fallbacks end here.".
//
// Usage: node prelude_fallbacks_test.js <a transpiled program>.
const fs = require('fs');
const assert = require('assert');

const transpiledProgram = fs.readFileSync(process.argv[2], 'utf8');
const fallbacksStart = transpiledProgram.indexOf('function __base64Bytes(');
const fallbacksEndMarker = "// The prelude's fallbacks end here.";
const fallbacksEnd = transpiledProgram.indexOf(fallbacksEndMarker, fallbacksStart);
assert.ok(fallbacksStart >= 0 && fallbacksEnd > fallbacksStart, 'the fallbacks were found in the program');
const fallbacksSource = transpiledProgram.slice(fallbacksStart, fallbacksEnd);
const fallbacks = new Function(fallbacksSource + '\nreturn { __base64Bytes, __utf8Decode, __utf8EncodeInto };')();

// A small random-number generator with a fixed seed, so that every run tests the same inputs.
let randomState = 12345;
function nextRandom() {
  randomState = (randomState * 1103515245 + 12345) >>> 0;
  return randomState / 4294967296;
}

// A random code point - a character's number - from every range UTF-8 writes differently: 1, 2, 3 and 4 bytes.
// Surrogates (D800 to DFFF) are left out: they are not characters, only halves of UTF-16 pairs.
function randomCodePoint() {
  const range = nextRandom();
  if (range < 0.4) {
    return Math.floor(nextRandom() * 0x80);
  }
  if (range < 0.6) {
    return 0x80 + Math.floor(nextRandom() * (0x800 - 0x80));
  }
  if (range < 0.85) {
    let codePoint = 0;
    do {
      codePoint = 0x800 + Math.floor(nextRandom() * (0x10000 - 0x800));
    } while (codePoint >= 0xd800 && codePoint < 0xe000);
    return codePoint;
  }
  return 0x10000 + Math.floor(nextRandom() * (0x110000 - 0x10000));
}

// ---- 1. Base64, with atob removed: random bytes of every length from 0 to 300, and 64 KB ----
const builtInAtob = globalThis.atob;
globalThis.atob = undefined;
for (let byteCount = 0; byteCount <= 300; byteCount++) {
  const originalBytes = new Uint8Array(byteCount);
  for (let byteIndex = 0; byteIndex < byteCount; byteIndex++) {
    originalBytes[byteIndex] = Math.floor(nextRandom() * 256);
  }
  const base64Text = Buffer.from(originalBytes).toString('base64');
  const decodedBytes = fallbacks.__base64Bytes(base64Text);
  assert.deepStrictEqual(Array.from(decodedBytes), Array.from(originalBytes), 'base64 of ' + byteCount + ' bytes');
}
const largeOriginal = new Uint8Array(65536);
for (let byteIndex = 0; byteIndex < largeOriginal.length; byteIndex++) {
  largeOriginal[byteIndex] = (byteIndex * 7919) & 255;
}
const largeDecoded = fallbacks.__base64Bytes(Buffer.from(largeOriginal).toString('base64'));
assert.ok(Buffer.from(largeDecoded).equals(Buffer.from(largeOriginal)), 'base64 of 64 KB');
globalThis.atob = builtInAtob;

// ---- 2. UTF-8 decoding: exactly as TextDecoder, for valid and for broken input ----
const builtInEncoder = new TextEncoder();
const builtInDecoder = new TextDecoder('utf-8');
// Valid: random strings, through the built-in encoder and back through the fallback decoder.
for (let trial = 0; trial < 3000; trial++) {
  const characterCount = Math.floor(nextRandom() * 40);
  let originalText = '';
  for (let characterIndex = 0; characterIndex < characterCount; characterIndex++) {
    originalText += String.fromCodePoint(randomCodePoint());
  }
  const decodedText = fallbacks.__utf8Decode(builtInEncoder.encode(originalText));
  assert.strictEqual(decodedText, originalText, 'a valid string decodes to itself');
}
const longText = 'é€😀a'.repeat(5000);
assert.strictEqual(fallbacks.__utf8Decode(builtInEncoder.encode(longText)), longText, 'a long string');
// Broken: random bytes, half of them taken from the bytes at the edges of UTF-8's ranges, where a decoder is most
// likely to go wrong.
const edgeBytes = [0x00, 0x7f, 0x80, 0x8f, 0x90, 0x9f, 0xa0, 0xbf, 0xc0, 0xc1, 0xc2, 0xdf, 0xe0, 0xed, 0xef,
  0xf0, 0xf4, 0xf5, 0xff, 0xbb, 0xef];
let brokenSequenceCount = 0;
for (let trial = 0; trial < 20000; trial++) {
  const byteCount = 1 + Math.floor(nextRandom() * 12);
  const sequence = new Uint8Array(byteCount);
  for (let byteIndex = 0; byteIndex < byteCount; byteIndex++) {
    const isEdgeByte = nextRandom() < 0.5;
    sequence[byteIndex] = isEdgeByte ? edgeBytes[Math.floor(nextRandom() * edgeBytes.length)] :
      Math.floor(nextRandom() * 256);
  }
  assert.strictEqual(fallbacks.__utf8Decode(sequence), builtInDecoder.decode(sequence), 'bytes ' + Array.from(sequence));
  brokenSequenceCount++;
}
// Byte order marks (EF BB BF): dropped at the very start only.
const byteOrderMarkCases = [[0xef, 0xbb, 0xbf], [0xef, 0xbb, 0xbf, 0x41], [0xef, 0xbb], [0x41, 0xef, 0xbb, 0xbf],
  [0xef, 0xbb, 0xbf, 0xef, 0xbb, 0xbf]];
for (const byteOrderMarkCase of byteOrderMarkCases) {
  const sequence = new Uint8Array(byteOrderMarkCase);
  assert.strictEqual(fallbacks.__utf8Decode(sequence), builtInDecoder.decode(sequence), 'byte order mark');
}
// Every sequence cut short: each code point at a range's edge, cut after each of its bytes.
for (const codePoint of [0x7f, 0x80, 0x7ff, 0x800, 0xffff, 0x10000, 0x10ffff]) {
  const wholeSequence = builtInEncoder.encode(String.fromCodePoint(codePoint));
  for (let keptByteCount = 0; keptByteCount <= wholeSequence.length; keptByteCount++) {
    const truncatedSequence = wholeSequence.slice(0, keptByteCount);
    const expectedText = builtInDecoder.decode(truncatedSequence);
    assert.strictEqual(fallbacks.__utf8Decode(truncatedSequence), expectedText, 'U+' + codePoint.toString(16) + ' cut');
  }
}

// ---- 3. encodeInto: the same bytes, and the same counts read and written, at every destination size ----
for (let trial = 0; trial < 500; trial++) {
  const unitCount = Math.floor(nextRandom() * 12);
  let text = '';
  for (let unitIndex = 0; unitIndex < unitCount; unitIndex++) {
    const choice = nextRandom();
    if (choice < 0.08) {
      text += String.fromCharCode(0xd800 + Math.floor(nextRandom() * 0x400));   // a high surrogate, alone
    } else if (choice < 0.16) {
      text += String.fromCharCode(0xdc00 + Math.floor(nextRandom() * 0x400));   // a low surrogate, alone
    } else {
      text += String.fromCodePoint(randomCodePoint());
    }
  }
  for (let destinationSize = 0; destinationSize <= text.length * 4; destinationSize++) {
    const fallbackDestination = new Uint8Array(destinationSize);
    const builtInDestination = new Uint8Array(destinationSize);
    const fallbackCounts = fallbacks.__utf8EncodeInto(text, fallbackDestination);
    const builtInCounts = builtInEncoder.encodeInto(text, builtInDestination);
    const expectedCounts = { read: builtInCounts.read, written: builtInCounts.written };
    assert.deepStrictEqual(fallbackCounts, expectedCounts, 'the counts read and written');
    assert.deepStrictEqual(Array.from(fallbackDestination), Array.from(builtInDestination), 'the bytes written');
  }
}

console.log('base64: lengths 0 to 300 and 64 KB exact');
console.log('decode: 3000 valid strings exact; ' + brokenSequenceCount + ' of ' + brokenSequenceCount +
  ' broken sequences exactly as TextDecoder');
console.log('encodeInto: 500 strings at every room, exact');
