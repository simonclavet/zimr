A zig port of raylib, imgui, implot, box2d / jolt physics, and MuJoCo-style robot
dynamics, for wasm/webgpu. Reads FBX and BVH for models and animation, and retargets
motion capture onto the robots. Carries a numerics library shaped like numpy, jax and
pandas that trains neural networks — attention and transformer blocks, the distributions
generative models are built from, PPO and SAC — on the GPU through compute shaders
written in the same zig. Includes transpilers from zig to wgsl (gpu) and javascript
(web) so we can live in a pure zig world. Work in progress.

Live demo gallery: https://simonclavet.github.io/zimr/

The long writeup, with the launcher running live in the page: https://simonclavet.github.io/zimr/readme.html
