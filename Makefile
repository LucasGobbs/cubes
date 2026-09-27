ODIN      ?= odin
SLANG     ?= $(HOME)/.local/opt/slang/bin/slangc
SRC       := ./src
BIN       := main
BIN_DEBUG := main_debug

GOOSE_BUILD         := src/goose/tools/build
GOOSE_MANIFEST      := shaders/goose.json
GOOSE_TEST_MANIFEST := src/goose/tests/goose.json
GOOSE_PLATFORM      ?= metal

RELEASE_FLAGS := -o:aggressive -microarch:native -no-bounds-check -disable-assert
DEBUG_FLAGS   := -debug -o:none

.PHONY: all build run run-optimized debug debug-optimized shaders goose-test-fixtures \
        test-goose-core test-goose-build test-goose-uniforms test-goose-vertex-buffers \
        test-goose-compute test-goose-graphics test-goose-runtime test-glove \
        test-glove-optimized test test-optimized compute clean
all: build

shaders:
	$(ODIN) run $(GOOSE_BUILD) -- --manifest $(GOOSE_MANIFEST) \
		--platform $(GOOSE_PLATFORM) --slang $(SLANG)

goose-test-fixtures:
	$(ODIN) run $(GOOSE_BUILD) -- --manifest $(GOOSE_TEST_MANIFEST) \
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

build: shaders
	$(ODIN) build $(SRC) -out:$(BIN) $(RELEASE_FLAGS)

run: shaders
	$(ODIN) run $(SRC) -- $(ARGS)

run-optimized: shaders
	$(ODIN) run $(SRC) $(RELEASE_FLAGS) -- $(ARGS)

debug: shaders
	$(ODIN) build $(SRC) -out:$(BIN_DEBUG) $(DEBUG_FLAGS)

debug-optimized: shaders
	$(ODIN) build $(SRC) -out:$(BIN_DEBUG) $(RELEASE_FLAGS) -debug

compute: shaders
	$(ODIN) run compute

test: shaders test-goose-core test-goose-build test-goose-runtime test-glove
	$(ODIN) test $(SRC) -all-packages

test-optimized: shaders test-goose-core test-goose-build test-goose-runtime test-glove-optimized
	$(ODIN) test $(SRC) -all-packages $(RELEASE_FLAGS)

clean:
	rm -f $(BIN) $(BIN_DEBUG)
	rm -rf shaders/generated src/goose/tests/generated
	rm -f src/shader_parameters/*_shader_parameters.odin \
		src/goose/tests/*_shader_parameters.odin
