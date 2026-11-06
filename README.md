# Cubes

Demo of the `gbbfx` renderer (Odin + SDL3 GPU + Slang) with four scenes.

## Requirements

- [Odin](https://odin-lang.org) on `PATH` (or `ODIN=/path/to/odin make ...`).
- The `goose` submodule: `git submodule update --init`.
- `slangc`: the vendored one in `third_party/goose/vendor/slang/bin` (macOS arm64),
  or `SLANG=/path/to/slangc make ...` elsewhere.

## Build and run

```
make build                     # release binary ./main
make run ARGS=models           # scenes: simple, editor, models, benchmark (default)
make editor                    # debug build with the microui editor overlay
make test                      # shader generation + all test packages
make dist                      # dist/: binary + static/ assets
```

Asset paths (`static/...`) are relative to the working directory. Run from the
repo root (the `make` targets do this) or from inside `dist/`.

## Controls

- `1`-`4`: switch scene at runtime (order of `SCENES` in `src/scene.odin`).
- `M`: toggle MSAA.
- `Esc`: quit.

## Layout

- `src/` - app and scenes (`main.odin`, `*_scene.odin`).
- `src/gbbfx/` - renderer, loader (glTF), and default shaders in `defaults/`.
- `src/glove/` - input system.
- `static/` - models, textures, fonts, skybox.
- `third_party/goose/` - shader build tool and Slang.
