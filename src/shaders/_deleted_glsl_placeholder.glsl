// LEGACY-WEBGL-PATH PLACEHOLDER — intentionally not a real shader.
//
// This file stands in for engine GLSL outputs that are NO LONGER
// GENERATED because their source `.zig` is in the `old_3d_shaders`
// skip-list in build.zig (the dying WebGL2/GLSL 3D path that is being
// replaced by the wgpu/WGSL pipeline).
//
// It exists so that `@embedFile("<name>.glsl")` calls still surviving
// in `src/rlgl.zig` and `src/render.zig` (and a couple of GLSL example
// CPU sides) RESOLVE at build time instead of aborting the entire
// `zig build test` with a cryptic per-file `FileNotFound` — which used
// to mask every other example's typecheck result.
//
// If you are reading this because a shader rendered as garbage: that
// consumer needs to be MIGRATED to the wgpu/WGSL path (or deleted),
// not pointed at a real GLSL file again. See:
//   - src/notes/claude.md  (KNOWN-RED / doomed-subsystem rule)
//   - src/notes/spv2wgsl_ir_rewrite.md
//
// The single space below is deliberate: @embedFile wants non-empty.
 
