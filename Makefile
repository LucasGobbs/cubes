ODIN      ?= odin
# goose is a git submodule (git submodule update --init). It vendors Slang
# (macOS arm64); override with SLANG=/path/to/slangc on other platforms.
GOOSE_DIR ?= third_party/goose
SLANG     ?= $(GOOSE_DIR)/vendor/slang/bin/slangc
SRC       := ./src
BIN       := main
BIN_DEBUG := main_debug

GOOSE_BUILD         := $(GOOSE_DIR)/src/tools/build
GOOSE_BUILD_BIN     := goose-build.bin
GOOSE_MANIFEST      := shaders/goose.json
DEFAULT_MANIFEST := src/engine/gfx/goose.json
# LuaJIT: vendored submodule built as a static lib (luajit-design.md section 9). Windows builds
# via scripts/build_luajit_windows.bat (msvcbuild.bat, /MD; UNVERIFIED until run on Windows).
# LUAJIT=vendored (default): `make luajit` builds $(LUAJIT_LIB).
# LUAJIT=system: `make luajit` is a no-op; the binding will point at a system lib
# (e.g. /opt/homebrew/lib/libluajit-5.1.a).
LUAJIT     ?= vendored
LUAJIT_DIR ?= third_party/luajit
LUAJIT_LIB := $(LUAJIT_DIR)/src/libluajit.a
ifneq ($(filter-out vendored system,$(LUAJIT)),)
$(error LUAJIT must be 'vendored' or 'system', got '$(LUAJIT)')
endif
ifeq ($(OS),Windows_NT)
LUAJIT_LIB := $(LUAJIT_DIR)/src/lua51.lib
else ifeq ($(shell uname -s),Darwin)
LUAJIT_OS_FLAGS := MACOSX_DEPLOYMENT_TARGET=15.0
ifneq ($(shell uname -m),arm64)
LUAJIT_XCFLAGS  := XCFLAGS=-DLUAJIT_ENABLE_GC64
endif
else ifeq ($(shell uname -s),Linux)
LUAJIT_XCFLAGS  := XCFLAGS=-DLUAJIT_ENABLE_GC64
endif


RELEASE_FLAGS := -o:aggressive -microarch:native -no-bounds-check -disable-assert
DEBUG_FLAGS   := -debug -o:none

# Editor UI (microui overlay) is compiled in only when EDITOR=true.
EDITOR        ?= false
EDITOR_DEFINE := -define:EDITOR=$(EDITOR)

.PHONY: all build run run-optimized debug debug-optimized shaders default-shaders constants \
        submodules luajit test-input test-input-optimized test-engine \
        test-engine-optimized test test-optimized compute editor example clean \
        new-scene new-actor
all: build

# Fail early with the fix instead of an Odin "package not found" error.
submodules:
	@test -f $(GOOSE_DIR)/src/goose.odin || { echo "goose submodule missing: run 'git submodule update --init'"; exit 1; }

# The shader tool skips up-to-date shaders itself; build it once and only
# rebuild when its sources change.
$(GOOSE_BUILD_BIN): $(wildcard $(GOOSE_DIR)/src/tools/build/*.odin) $(wildcard $(GOOSE_DIR)/src/*.odin) | submodules
	$(ODIN) build $(GOOSE_BUILD) -out:$(GOOSE_BUILD_BIN)

# Shared Odin <-> Slang constants (shaders/constants.json). The generator rewrites each file only when its content
# changes, so shaders importing constants.slang rebuild only when a value changes.
CONSTANTS_GEN_BIN := constants-gen.bin
$(CONSTANTS_GEN_BIN): $(wildcard tools/constants/*.odin)
	$(ODIN) build tools/constants -out:$(CONSTANTS_GEN_BIN)

constants: $(CONSTANTS_GEN_BIN)
	./$(CONSTANTS_GEN_BIN)

shaders: constants default-shaders $(GOOSE_BUILD_BIN)
	./$(GOOSE_BUILD_BIN) --manifest $(GOOSE_MANIFEST) --slang $(SLANG)

default-shaders: $(GOOSE_BUILD_BIN)
	./$(GOOSE_BUILD_BIN) --manifest $(DEFAULT_MANIFEST) --slang $(SLANG)

# LuaJIT 2.1 (vendored submodule, static lib). Rebuilds only when its sources change;
# make -C does the incremental work inside the submodule.
$(LUAJIT_LIB): $(wildcard $(LUAJIT_DIR)/src/*.c $(LUAJIT_DIR)/src/*.h $(LUAJIT_DIR)/src/*.dasc)
ifeq ($(OS),Windows_NT)
	scripts\build_luajit_windows.bat
else
	@test -f $(LUAJIT_DIR)/Makefile || { echo "luajit submodule missing: run 'git submodule update --init'"; exit 1; }
	$(MAKE) -C $(LUAJIT_DIR) amalg BUILDMODE=static $(LUAJIT_OS_FLAGS) $(LUAJIT_XCFLAGS)
endif

ifeq ($(LUAJIT),vendored)
luajit: $(LUAJIT_LIB)
else
luajit:
	@echo "LUAJIT=system: nothing to build"
endif

# goose's own tests run in the goose repo (make -C $(GOOSE_DIR) test).
test-input:
	$(ODIN) test src/engine/input/tests

test-input-optimized:
	$(ODIN) test src/engine/input/tests $(RELEASE_FLAGS)

test-engine: default-shaders luajit
	$(ODIN) test src/engine/gfx
	$(ODIN) test src/engine/gfx/loader
	$(ODIN) test src/engine/gfx/sdl_gpu
	$(ODIN) test src/engine
	$(ODIN) test src/engine/physics
	$(ODIN) test src/engine/jobs
	$(ODIN) test src/engine/luajit

test-engine-optimized: default-shaders luajit
	$(ODIN) test src/engine/gfx $(RELEASE_FLAGS)
	$(ODIN) test src/engine/gfx/loader $(RELEASE_FLAGS)
	$(ODIN) test src/engine/gfx/sdl_gpu $(RELEASE_FLAGS)
	$(ODIN) test src/engine $(RELEASE_FLAGS)
	$(ODIN) test src/engine/physics $(RELEASE_FLAGS)
	$(ODIN) test src/engine/jobs $(RELEASE_FLAGS)
	$(ODIN) test src/engine/luajit $(RELEASE_FLAGS)

build: shaders luajit
	$(ODIN) build $(SRC) -out:$(BIN) $(RELEASE_FLAGS) $(EDITOR_DEFINE)

# SCREEN = monitor number for the window (2 = second screen; falls back to the primary when there is only one).
SCREEN ?= 2
run: shaders luajit
	$(ODIN) run $(SRC) $(EDITOR_DEFINE) -- --display $(SCREEN) $(ARGS)

run-optimized: shaders luajit
	$(ODIN) run $(SRC) $(RELEASE_FLAGS) $(EDITOR_DEFINE) -- $(ARGS)

debug: shaders luajit
	$(ODIN) build $(SRC) -out:$(BIN_DEBUG) $(DEBUG_FLAGS) $(EDITOR_DEFINE)

debug-optimized: shaders luajit
	$(ODIN) build $(SRC) -out:$(BIN_DEBUG) $(RELEASE_FLAGS) -debug $(EDITOR_DEFINE)

editor: EDITOR = true
editor: debug
	./$(BIN_DEBUG)

compute: shaders
	$(ODIN) run compute

test: shaders test-input test-engine
	$(ODIN) test $(SRC) -all-packages

test-optimized: shaders test-input-optimized test-engine-optimized
	$(ODIN) test $(SRC) -all-packages $(RELEASE_FLAGS)

example: default-shaders
	$(ODIN) build examples/hello_engine -out:hello_engine $(RELEASE_FLAGS)

clean:
	rm -f $(BIN) $(BIN_DEBUG) $(GOOSE_BUILD_BIN) $(CONSTANTS_GEN_BIN)
	rm -rf shaders/generated src/engine/gfx/generated
	rm -f src/shader_parameters/*_shader_parameters.odin \
		src/engine/gfx/*_shader_parameters.odin
	@if [ -f $(LUAJIT_DIR)/Makefile ]; then $(MAKE) -C $(LUAJIT_DIR) clean $(LUAJIT_OS_FLAGS); fi

# Odin vs Lua benchmark (plan.md P2.1). Build first: make default-shaders shaders luajit && odin build src -out:/tmp/cubes_v
# Vars: BENCH_BIN (or BIN=) binary, N boats-per-model list, RUNS per scene, WAIT seconds to wait for idle (default 0 = refuse now).
BENCH_BIN ?= /tmp/cubes_v
ifeq ($(origin BIN),command line)
BENCH_BIN := $(BIN)
endif
N     ?= 100 150 400
RUNS  ?= 3
WAIT  ?= 0
bench-script:
	BIN="$(BENCH_BIN)" N="$(N)" RUNS="$(RUNS)" WAIT="$(WAIT)" scripts/bench_script.sh

# Scaffolding (tools/cubes). DATA=1: data-only scene. DRY=1: print plan, write nothing.
new-scene:
	@test -n "$(NAME)" || { echo "usage: make new-scene NAME=<name> [DATA=1] [DRY=1]"; exit 1; }
	$(ODIN) run tools/cubes -- new scene $(NAME) $(if $(DATA),--data) $(if $(DRY),--dry-run)

new-actor:
	@test -n "$(NAME)" -a -n "$(SCENE)" || { echo "usage: make new-actor NAME=<name> SCENE=<scene> [DRY=1]"; exit 1; }
	$(ODIN) run tools/cubes -- new actor $(NAME) --scene $(SCENE) $(if $(DRY),--dry-run)

.PHONY: dist
# Release bundle: binary + static assets. Shaders are embedded at build time,
# so run from inside dist/ (asset paths are relative to the cwd).
dist: build
	rm -rf dist
	mkdir dist
	cp $(BIN) dist/
	cp -R static dist/
