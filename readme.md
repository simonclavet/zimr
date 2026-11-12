# zimr

Hello, I am Simon Clavet, and this is my big monorepo of many different projects. 

Graphics, physics, mocap, reinforcement learnings. All in zig including shaders, without dependencies except the compiler.

- Hundreds of live demos: https://simonclavet.github.io/zimr/
- Overview, with hero demos running in the page: https://simonclavet.github.io/zimr/readme.html

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
