# .zenv.sh - zimr's shell environment. Source it from the repository root, in every new shell:
#
#     . ./.zenv.sh
#
# It puts the Zig toolchain and zimr's own tools on PATH, and checks the two things a fresh Linux sandbox lacks for
# GPU work - a Vulkan driver (lavapipe) and the Vulkan validation layer - naming the command that installs them.
#
# The toolchain is FOUND, never named: `tools/zig-<arch>-<os>-<version>/` as the uploaded tarball unpacks
# (`tar -xJf <upload> -C tools/`). A version string pinned here rots the day the compiler is bumped. When several
# toolchains are unpacked, the last in glob order - the newest version - wins.
#
# POSIX sh: the sandbox's /bin/sh is dash, which sources this too.

zimr_root=$(pwd)

zimr_zig_dir=""
for zimr_candidate in "$zimr_root"/tools/zig-*-*-*/; do
    if [ -x "${zimr_candidate}zig" ]; then
        zimr_zig_dir=${zimr_candidate%/}
    fi
done

if [ -z "$zimr_zig_dir" ]; then
    echo ".zenv.sh: no Zig toolchain under tools/ - unpack the uploaded tarball: tar -xJf <upload> -C tools/"
else
    # zbuild, measure and the other tools zimr builds land in tools/zig-out/bin (`zig build zbuild`, `zig build
    # measure`).
    PATH="$zimr_zig_dir:$zimr_root/tools/zig-out/bin:$PATH"
    export PATH
    echo ".zenv.sh: zig $("$zimr_zig_dir/zig" version) from ${zimr_zig_dir#"$zimr_root"/}"
fi

# GPU work in the sandbox - every `<app>-headless` run, the lab and trainer checks, `vk-host-test` - runs on lavapipe
# (Mesa's CPU Vulkan driver, `llvmpipe`) under the Khronos validation layer, which zimr turns on and requires:
# `vk-host-test` refuses to run without it (exit code 2). A fresh sandbox has neither.
zimr_icd="/usr/share/vulkan/icd.d/lvp_icd.json"
zimr_validation_layer="/usr/share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json"
if [ ! -f "$zimr_icd" ] || [ ! -f "$zimr_validation_layer" ]; then
    echo ".zenv.sh: lavapipe or the Vulkan validation layer is missing - install both (about a minute):"
    echo "    apt-get update && apt-get install -y mesa-vulkan-drivers vulkan-validationlayers"
fi

unset zimr_root zimr_zig_dir zimr_candidate zimr_icd zimr_validation_layer
