# Tint test fixtures — derived works

The `.spvasm` files in this directory are SPIR-V assembly
inputs extracted from the Dawn project's Tint SPIR-V
reader test suite (`src/tint/lang/spirv/reader/parser/*_test.cc`).
They are reproduced here for the purpose of testing our
spv2wgsl translator against the same corner cases Tint
tests against.

Original source: https://dawn.googlesource.com/dawn  (Apache 2.0)
See: https://dawn.googlesource.com/dawn/+/refs/heads/main/LICENSE

Each `.spvasm` corresponds to one `TEST_F(SpirvParserTest, NAME)`
case.  Filename is the test name.
