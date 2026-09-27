ODIN      ?= odin
SLANG     ?= $(HOME)/.local/opt/slang/bin/slangc
SRC       := ./src
BIN       := main
BIN_DEBUG := main_debug

SHADER_SRC   := shaders/triangle.slang
SHADER_OUT   := shaders/generated
SHADER_FILES := $(SHADER_OUT)/triangle.vert.msl $(SHADER_OUT)/triangle.frag.msl \
                $(SHADER_OUT)/triangle.vert.spv $(SHADER_OUT)/triangle.frag.spv \
                $(SHADER_OUT)/compute.msl $(SHADER_OUT)/compute.spv

# Reflection JSON is emitted as a byproduct of the Metal compiles (one per
# entry point). Used by the binding generator, not loaded at runtime.
REFL_FILES := $(SHADER_OUT)/triangle.vert.refl.json $(SHADER_OUT)/triangle.frag.refl.json \
              $(SHADER_OUT)/compute.refl.json

SHADER_GENERATOR := src/shader/tools/generator
SHADER_GENERATOR_SRC := $(SHADER_GENERATOR)/main.odin
SHADER_PARAMETER_DIR := src/shader_parameters
TRIANGLE_PARAMETERS := $(SHADER_PARAMETER_DIR)/triangle_shader_parameters.odin
COMPUTE_PARAMETERS := $(SHADER_PARAMETER_DIR)/compute_shader_parameters.odin
SHADER_PARAMETER_FILES := $(TRIANGLE_PARAMETERS) $(COMPUTE_PARAMETERS)

SHADER_TEST_DIR := src/shader/tests
SHADER_TEST_SRC := $(SHADER_TEST_DIR)/slang
SHADER_TEST_OUT := $(SHADER_TEST_DIR)/generated
SHADER_TEST_GRAPHICS := uniforms vertex_buffers graphics_pipeline
SHADER_TEST_COMPUTE := compute_pipeline
SHADER_TEST_FILES := $(foreach name,$(SHADER_TEST_GRAPHICS), \
                       $(SHADER_TEST_OUT)/$(name).vert.msl \
                       $(SHADER_TEST_OUT)/$(name).frag.msl \
                       $(SHADER_TEST_OUT)/$(name).vert.spv \
                       $(SHADER_TEST_OUT)/$(name).frag.spv) \
                     $(SHADER_TEST_OUT)/$(SHADER_TEST_COMPUTE).compute.msl \
                     $(SHADER_TEST_OUT)/$(SHADER_TEST_COMPUTE).compute.spv
SHADER_TEST_REFL := $(foreach name,$(SHADER_TEST_GRAPHICS), \
                      $(SHADER_TEST_OUT)/$(name).vert.refl.json \
                      $(SHADER_TEST_OUT)/$(name).frag.refl.json) \
                    $(SHADER_TEST_OUT)/$(SHADER_TEST_COMPUTE).compute.refl.json
SHADER_TEST_PARAMETERS := $(foreach name,$(SHADER_TEST_GRAPHICS), \
                            $(SHADER_TEST_DIR)/$(name)_shader_parameters.odin) \
                          $(SHADER_TEST_DIR)/$(SHADER_TEST_COMPUTE)_shader_parameters.odin

RELEASE_FLAGS := -o:aggressive -microarch:native -no-bounds-check -disable-assert
DEBUG_FLAGS   := -debug -o:none

.PHONY: all build run run-optimized debug debug-optimized test test-optimized shaders check-shader-parameters test-shader-generator shader-test-fixtures test-shader-uniforms test-shader-vertex-buffers test-shader-compute test-shader-graphics test-shader-runtime compute clean

all: build

shaders: $(SHADER_FILES) $(SHADER_PARAMETER_FILES)

$(SHADER_OUT)/triangle.vert.refl.json: $(SHADER_SRC)
	@mkdir -p $(SHADER_OUT)
	$(SLANG) $(SHADER_SRC) -entry vertexMain -target metal \
		-reflection-json $@ -o $(SHADER_OUT)/triangle.vert.msl

$(SHADER_OUT)/triangle.vert.msl: $(SHADER_OUT)/triangle.vert.refl.json

$(SHADER_OUT)/triangle.frag.refl.json: $(SHADER_SRC)
	@mkdir -p $(SHADER_OUT)
	$(SLANG) $(SHADER_SRC) -entry pixelMain -target metal \
		-reflection-json $@ -o $(SHADER_OUT)/triangle.frag.msl

$(SHADER_OUT)/triangle.frag.msl: $(SHADER_OUT)/triangle.frag.refl.json

$(SHADER_OUT)/triangle.vert.spv: $(SHADER_SRC)
	@mkdir -p $(SHADER_OUT)
	$(SLANG) $(SHADER_SRC) -entry vertexMain -target spirv -o $@

$(SHADER_OUT)/triangle.frag.spv: $(SHADER_SRC)
	@mkdir -p $(SHADER_OUT)
	$(SLANG) $(SHADER_SRC) -entry pixelMain -target spirv -o $@

$(SHADER_OUT)/compute.refl.json: shaders/compute.slang
	@mkdir -p $(SHADER_OUT)
	$(SLANG) shaders/compute.slang -entry computeMain -target metal \
		-reflection-json $@ -o $(SHADER_OUT)/compute.msl

$(SHADER_OUT)/compute.msl: $(SHADER_OUT)/compute.refl.json

$(SHADER_OUT)/compute.spv: shaders/compute.slang
	@mkdir -p $(SHADER_OUT)
	$(SLANG) shaders/compute.slang -entry computeMain -target spirv -o $@

$(TRIANGLE_PARAMETERS): $(SHADER_GENERATOR_SRC) \
                        $(SHADER_OUT)/triangle.vert.refl.json \
                        $(SHADER_OUT)/triangle.frag.refl.json
	$(ODIN) run $(SHADER_GENERATOR) -- --name triangle \
		--package shader_parameters --shader-import ../shader \
		--reflection $(SHADER_OUT)/triangle.vert.refl.json \
		--reflection $(SHADER_OUT)/triangle.frag.refl.json --output $@

$(COMPUTE_PARAMETERS): $(SHADER_GENERATOR_SRC) $(SHADER_OUT)/compute.refl.json
	$(ODIN) run $(SHADER_GENERATOR) -- --name compute \
		--package shader_parameters --shader-import ../shader \
		--reflection $(SHADER_OUT)/compute.refl.json --output $@

check-shader-parameters: $(SHADER_PARAMETER_FILES)
	$(ODIN) run $(SHADER_GENERATOR) -- --check --name triangle \
		--package shader_parameters --shader-import ../shader \
		--reflection $(SHADER_OUT)/triangle.vert.refl.json \
		--reflection $(SHADER_OUT)/triangle.frag.refl.json \
		--output $(TRIANGLE_PARAMETERS)
	$(ODIN) run $(SHADER_GENERATOR) -- --check --name compute \
		--package shader_parameters --shader-import ../shader \
		--reflection $(SHADER_OUT)/compute.refl.json \
		--output $(COMPUTE_PARAMETERS)

test-shader-generator: $(REFL_FILES)
	$(ODIN) test $(SHADER_GENERATOR)

$(SHADER_TEST_OUT)/%.vert.refl.json: $(SHADER_TEST_SRC)/%.slang
	@mkdir -p $(SHADER_TEST_OUT)
	$(SLANG) $< -entry vertexMain -target metal -reflection-json $@ \
		-o $(SHADER_TEST_OUT)/$*.vert.msl

$(SHADER_TEST_OUT)/%.vert.msl: $(SHADER_TEST_OUT)/%.vert.refl.json
	@test -f $@

$(SHADER_TEST_OUT)/%.frag.refl.json: $(SHADER_TEST_SRC)/%.slang
	@mkdir -p $(SHADER_TEST_OUT)
	$(SLANG) $< -entry pixelMain -target metal -reflection-json $@ \
		-o $(SHADER_TEST_OUT)/$*.frag.msl

$(SHADER_TEST_OUT)/%.frag.msl: $(SHADER_TEST_OUT)/%.frag.refl.json
	@test -f $@

$(SHADER_TEST_OUT)/%.vert.spv: $(SHADER_TEST_SRC)/%.slang
	@mkdir -p $(SHADER_TEST_OUT)
	$(SLANG) $< -entry vertexMain -target spirv -o $@

$(SHADER_TEST_OUT)/%.frag.spv: $(SHADER_TEST_SRC)/%.slang
	@mkdir -p $(SHADER_TEST_OUT)
	$(SLANG) $< -entry pixelMain -target spirv -o $@

$(SHADER_TEST_OUT)/%.compute.refl.json: $(SHADER_TEST_SRC)/%.slang
	@mkdir -p $(SHADER_TEST_OUT)
	$(SLANG) $< -entry computeMain -target metal -reflection-json $@ \
		-o $(SHADER_TEST_OUT)/$*.compute.msl

$(SHADER_TEST_OUT)/%.compute.msl: $(SHADER_TEST_OUT)/%.compute.refl.json
	@test -f $@

$(SHADER_TEST_OUT)/%.compute.spv: $(SHADER_TEST_SRC)/%.slang
	@mkdir -p $(SHADER_TEST_OUT)
	$(SLANG) $< -entry computeMain -target spirv -o $@

$(SHADER_TEST_DIR)/%_shader_parameters.odin: $(SHADER_GENERATOR_SRC) \
                                                  $(SHADER_TEST_OUT)/%.vert.refl.json \
                                                  $(SHADER_TEST_OUT)/%.frag.refl.json
	$(ODIN) run $(SHADER_GENERATOR) -- --name $* --package shader_tests \
		--shader-import .. --reflection $(SHADER_TEST_OUT)/$*.vert.refl.json \
		--reflection $(SHADER_TEST_OUT)/$*.frag.refl.json --output $@

$(SHADER_TEST_DIR)/$(SHADER_TEST_COMPUTE)_shader_parameters.odin: $(SHADER_GENERATOR_SRC) \
                                                                    $(SHADER_TEST_OUT)/$(SHADER_TEST_COMPUTE).compute.refl.json
	$(ODIN) run $(SHADER_GENERATOR) -- --name $(SHADER_TEST_COMPUTE) \
		--package shader_tests --shader-import .. \
		--reflection $(SHADER_TEST_OUT)/$(SHADER_TEST_COMPUTE).compute.refl.json \
		--output $@

shader-test-fixtures: $(SHADER_TEST_FILES) $(SHADER_TEST_REFL) $(SHADER_TEST_PARAMETERS)

test-shader-uniforms: shader-test-fixtures
	$(ODIN) test $(SHADER_TEST_DIR) \
		-define:ODIN_TEST_NAMES=shader_tests.shader_uniform_layout_is_reflected_independently

test-shader-vertex-buffers: shader-test-fixtures
	$(ODIN) test $(SHADER_TEST_DIR) \
		-define:ODIN_TEST_NAMES=shader_tests.shader_vertex_attributes_are_reflected_independently

test-shader-compute: shader-test-fixtures
	$(ODIN) run $(SHADER_TEST_DIR)/runtime -- compute

test-shader-graphics: shader-test-fixtures
	$(ODIN) run $(SHADER_TEST_DIR)/runtime -- graphics

test-shader-runtime: test-shader-uniforms test-shader-vertex-buffers test-shader-compute test-shader-graphics

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

test: shaders check-shader-parameters test-shader-generator test-shader-runtime
	$(ODIN) test $(SRC) -all-packages

test-optimized: shaders check-shader-parameters test-shader-generator test-shader-runtime
	$(ODIN) test $(SRC) -all-packages $(RELEASE_FLAGS)

clean:
	rm -f $(BIN) $(BIN_DEBUG) $(SHADER_FILES) $(REFL_FILES) $(SHADER_PARAMETER_FILES) \
		$(SHADER_TEST_FILES) $(SHADER_TEST_REFL) $(SHADER_TEST_PARAMETERS)
