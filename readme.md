# zimr

A Zig port of raylib, Dear ImGui, ImPlot, Box2D, Jolt and MuJoCo, with a numerics library
in the style of numpy, pandas and PyTorch. The same app runs in the browser on WebGPU and
natively on Windows on Vulkan. Everything is Zig, down to the shaders (we have a spv2wgsl 
transpiler for webgpu, using the compiler's spv target) and the browser glue (we have a c2js 
transpiler using the compiler's c target), so the Zig compiler is the only dependency.

A shader written in Zig runs unchanged on the GPU, on the CPU in a software renderer, 
and even at compile time. The demos include ray
tracing, physically based rendering and fractals. Neural networks work the same way: debug
the training on the CPU, then run the same code on the GPU.

Work in progress.

- Live demos: https://simonclavet.github.io/zimr/
- Overview, with demos running in the page: https://simonclavet.github.io/zimr/readme.html

## Start a project

Begin from `template/`, a starter with two small apps. It builds in place, right after
a clone:

    git clone https://github.com/simonclavet/zimr
    cd zimr/template
    zig build serve -Dplatform=web     # then open http://127.0.0.1:8081/
    zig build run -Dplatform=windows   # or natively on Windows: the first app, as a program

Then copy it wherever your project should live and fix one line of its `build.zig.zon`,
the relative path to zimr. [template/README.md](template/README.md) has the layouts and the
Zig version zimr needs.
