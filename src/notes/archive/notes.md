

## Top-level files

| File                      | What it is                                           |
|---------------------------|------------------------------------------------------|
| **`README.md`**           | pitch, quickstart           |
| **`CHEATSHEET.md`**       | hand-curated public-API quick reference             |
| **`CHANGELOG.md`**        | what landed when                                    |
| **`PLAN.md`**             | roadmap + status + 20-step coverage backlog         |
| `LICENSE`                 | zlib/libpng (matches raylib upstream)               |
| `THIRD_PARTY_LICENSES.md` | attribution for vendored deps (zigimg, TrueType, …) |

For deeper docs see `docs/`:

- `docs/getting-started.md` — your first 30-line zimr app
- `docs/architecture.md` — three layers, import groups, testing
- `docs/style-guide.md` — code conventions (mandatory for new code)
- `docs/migration-from-raylib.md` — for users coming from raylib
- `docs/effects-design.md` — the four Frame effects
- `docs/multiapp-design.md` — gallery's sub-app harness
- `docs/coverage-report.md` — auto-generated raylib coverage audit
- `docs/raylib-coverage-gaps.md` — what's still missing
- `docs/examples-plan.md` — backlog of example ideas
- `docs/archive/` — historical planning docs (don't read first)

---

## Layout

```
zimr/
├── build.zig                # single source of truth for build/test/serve
├── build.zig.zon
├── src/                     # 9 root .zig modules
│   ├── zimr.zig             # public API root, re-exports
│   ├── types.zig            # types + enums + errors + colors
│   ├── raymath.zig          # full raymath.h port (146 fns)
│   ├── web.zig              # browser bindings (dom + gl + audio + fetch)
│   ├── rlgl.zig             # rlgl matrix stack + GPU + wasm forwarders
│   ├── runtime.zig          # core + input + camera + effects + allocator
│   ├── drawing.zig          # shapes + textures + text + models + shaders
│   ├── codecs.zig           # png (encode + decode) + truetype + rectpack + code_point
│   ├── tests.zig            # test aggregator
│   ├── tests/               # per-module test files (next turn: colocate)
│   └── web/                 # runtime TS + HTML (not Zig)
├── examples/                # 23 self-contained .zig demos
├── webtests/                # Bun-driven smoke + dev server
├── assets/                  # smiley.png + RobotoMono-Regular.ttf
├── docs/                    # reference docs + archive
└── prebuilt/                # release-only: pre-built wasm + docs
```

---

## Toolchain

- **Zig 0.16.0** — pinned, no automatic upgrades.  Will not build
  on 0.15 (different `std.Io`) or 0.17 (not yet released).
- **Bun ≥ 1.3** — for `zig build smoke-test` and `zig build serve`.
  See "Want to hack on it?" above for install commands.
  `zig build test` is pure-Zig and works without Bun.
- **Python 3** — only for `serve.sh` / `serve.bat` (release
  workflow + the `zimr_template` starter).  Not needed for
  development against zimr proper.
- No other dependencies.  No npm packages, no node_modules, no
  system libraries.

---