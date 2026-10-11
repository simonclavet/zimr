// The fixture interop.zig reads: a property, methods taking numbers and a string, and a truthy flag.
globalThis.fixture = {
  x: 42,
  add: function (a, b) { return a + b; },
  strlen: function (text) { return text.length; },
  scale: function (a, b) { return a * b; },
  flag: true,
};
