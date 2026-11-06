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
GBBFX_DEFAULTS_MANIFEST := src/gbbfx/defaults/goose.json

RELEASE_FLAGS := -o:aggressive -microarch:native -no-bounds-check -disable-assert
DEBUG_FLAGS   := -debug -o:none

# Editor UI (microui overlay) is compiled in only when EDITOR=true.
EDITOR        ?= false
EDITOR_DEFINE := -define:EDITOR=$(EDITOR)

.PHONY: all build run run-optimized debug debug-optimized shaders default-shaders \
        submodules test-glove test-glove-optimized test-gbbfx \
        test-gbbfx-optimized test test-optimized compute editor clean
all: build

# Fail early with the fix instead of an Odin "package not found" error.
submodules:
	@test -f $(GOOSE_DIR)/src/goose.odin || { echo "goose submodule missing: run 'git submodule update --init'"; exit 1; }

# The shader tool skips up-to-date shaders itself; build it once and only
# rebuild when its sources change.
$(GOOSE_BUILD_BIN): $(wildcard $(GOOSE_DIR)/src/tools/build/*.odin) $(wildcard $(GOOSE_DIR)/src/*.odin) | submodules
	$(ODIN) build $(GOOSE_BUILD) -out:$(GOOSE_BUILD_BIN)

shaders: default-shaders $(GOOSE_BUILD_BIN)
	./$(GOOSE_BUILD_BIN) --manifest $(GOOSE_MANIFEST) --slang $(SLANG)

default-shaders: $(GOOSE_BUILD_BIN)
	./$(GOOSE_BUILD_BIN) --manifest $(GBBFX_DEFAULTS_MANIFEST) --slang $(SLANG)

# goose's own tests run in the goose repo (make -C $(GOOSE_DIR) test).
test-glove:
	$(ODIN) test src/glove/tests

test-glove-optimized:
	$(ODIN) test src/glove/tests $(RELEASE_FLAGS)

test-gbbfx: default-shaders
	$(ODIN) test src/gbbfx
	$(ODIN) test src/gbbfx/loader
	$(ODIN) test src/gbbfx/sdl_gpu

test-gbbfx-optimized: default-shaders
	$(ODIN) test src/gbbfx $(RELEASE_FLAGS)
	$(ODIN) test src/gbbfx/loader $(RELEASE_FLAGS)
	$(ODIN) test src/gbbfx/sdl_gpu $(RELEASE_FLAGS)

build: shaders
	$(ODIN) build $(SRC) -out:$(BIN) $(RELEASE_FLAGS) $(EDITOR_DEFINE)

run: shaders
	$(ODIN) run $(SRC) $(EDITOR_DEFINE) -- $(ARGS)

run-optimized: shaders
	$(ODIN) run $(SRC) $(RELEASE_FLAGS) $(EDITOR_DEFINE) -- $(ARGS)

debug: shaders
	$(ODIN) build $(SRC) -out:$(BIN_DEBUG) $(DEBUG_FLAGS) $(EDITOR_DEFINE)

debug-optimized: shaders
	$(ODIN) build $(SRC) -out:$(BIN_DEBUG) $(RELEASE_FLAGS) -debug $(EDITOR_DEFINE)

editor: EDITOR = true
editor: debug
	./$(BIN_DEBUG)

compute: shaders
	$(ODIN) run compute

test: shaders test-glove test-gbbfx
	$(ODIN) test $(SRC) -all-packages

test-optimized: shaders test-glove-optimized test-gbbfx-optimized
	$(ODIN) test $(SRC) -all-packages $(RELEASE_FLAGS)

clean:
	rm -f $(BIN) $(BIN_DEBUG) $(GOOSE_BUILD_BIN)
	rm -rf shaders/generated src/gbbfx/defaults/generated
	rm -f src/shader_parameters/*_shader_parameters.odin \
		src/gbbfx/defaults/*_shader_parameters.odin
