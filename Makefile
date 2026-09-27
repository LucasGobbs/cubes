ODIN      ?= odin
SLANG     ?= $(HOME)/.local/opt/slang/bin/slangc
SRC       := ./src
BIN       := main
BIN_DEBUG := main_debug

GOOSE_BUILD         := src/goose/tools/build
GOOSE_BUILD_BIN     := goose-build.bin
GOOSE_MANIFEST      := shaders/goose.json
GOOSE_TEST_MANIFEST := src/goose/tests/goose.json
GBBFX_DEFAULTS_MANIFEST := src/gbbfx/defaults/goose.json
GOOSE_PLATFORM      ?= metal

RELEASE_FLAGS := -o:aggressive -microarch:native -no-bounds-check -disable-assert
DEBUG_FLAGS   := -debug -o:none

# Editor UI (microui overlay) is compiled in only when EDITOR=true.
EDITOR        ?= false
EDITOR_DEFINE := -define:EDITOR=$(EDITOR)

.PHONY: all build run run-optimized debug debug-optimized shaders default-shaders \
        goose-test-fixtures test-goose-core test-goose-build test-goose-uniforms \
        test-goose-vertex-buffers test-goose-compute test-goose-graphics \
        test-goose-runtime test-glove test-glove-optimized test-gbbfx \
        test-gbbfx-optimized test test-optimized compute editor clean
all: build

# The shader tool skips up-to-date shaders itself; build it once and only
# rebuild when its sources (or goose core) change.
$(GOOSE_BUILD_BIN): $(wildcard src/goose/tools/build/*.odin) $(wildcard src/goose/*.odin)
	$(ODIN) build $(GOOSE_BUILD) -out:$(GOOSE_BUILD_BIN)

shaders: default-shaders $(GOOSE_BUILD_BIN)
	./$(GOOSE_BUILD_BIN) --manifest $(GOOSE_MANIFEST) \
		--platform $(GOOSE_PLATFORM) --slang $(SLANG)

default-shaders: $(GOOSE_BUILD_BIN)
	./$(GOOSE_BUILD_BIN) --manifest $(GBBFX_DEFAULTS_MANIFEST) \
		--platform $(GOOSE_PLATFORM) --slang $(SLANG)

goose-test-fixtures: $(GOOSE_BUILD_BIN)
	./$(GOOSE_BUILD_BIN) --manifest $(GOOSE_TEST_MANIFEST) \
		--platform $(GOOSE_PLATFORM) --slang $(SLANG)

test-goose-core:
	$(ODIN) test src/goose
	$(ODIN) test src/goose/adapters/sdl_gpu

test-goose-build: goose-test-fixtures
	$(ODIN) test $(GOOSE_BUILD)

test-goose-uniforms: goose-test-fixtures
	$(ODIN) test src/goose/tests \
		-define:ODIN_TEST_NAMES=goose_tests.shader_uniform_layout_is_reflected_independently

test-goose-vertex-buffers: goose-test-fixtures
	$(ODIN) test src/goose/tests \
		-define:ODIN_TEST_NAMES=goose_tests.shader_vertex_attributes_are_reflected_independently

test-goose-compute: goose-test-fixtures
	$(ODIN) run src/goose/tests/runtime -- compute

test-goose-graphics: goose-test-fixtures
	$(ODIN) run src/goose/tests/runtime -- graphics

test-goose-runtime: test-goose-uniforms test-goose-vertex-buffers test-goose-compute test-goose-graphics

test-glove:
	$(ODIN) test src/glove/tests

test-glove-optimized:
	$(ODIN) test src/glove/tests $(RELEASE_FLAGS)

test-gbbfx: default-shaders
	$(ODIN) test src/gbbfx

test-gbbfx-optimized: default-shaders
	$(ODIN) test src/gbbfx $(RELEASE_FLAGS)

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

test: shaders test-goose-core test-goose-build test-goose-runtime test-glove test-gbbfx
	$(ODIN) test $(SRC) -all-packages

test-optimized: shaders test-goose-core test-goose-build test-goose-runtime test-glove-optimized test-gbbfx-optimized
	$(ODIN) test $(SRC) -all-packages $(RELEASE_FLAGS)

clean:
	rm -f $(BIN) $(BIN_DEBUG) $(GOOSE_BUILD_BIN)
	rm -rf shaders/generated src/goose/tests/generated src/gbbfx/defaults/generated
	rm -f src/shader_parameters/*_shader_parameters.odin \
		src/gbbfx/defaults/*_shader_parameters.odin \
		src/goose/tests/*_shader_parameters.odin
