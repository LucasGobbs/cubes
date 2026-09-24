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

RELEASE_FLAGS := -o:aggressive -microarch:native -no-bounds-check -disable-assert
DEBUG_FLAGS   := -debug -o:none

.PHONY: all build run run-optimized debug debug-optimized test test-optimized shaders compute clean

all: build

shaders: $(SHADER_FILES)

$(SHADER_OUT)/triangle.vert.msl: $(SHADER_SRC)
	@mkdir -p $(SHADER_OUT)
	$(SLANG) $(SHADER_SRC) -entry vertexMain -target metal -o $@

$(SHADER_OUT)/triangle.frag.msl: $(SHADER_SRC)
	@mkdir -p $(SHADER_OUT)
	$(SLANG) $(SHADER_SRC) -entry pixelMain -target metal -o $@

$(SHADER_OUT)/triangle.vert.spv: $(SHADER_SRC)
	@mkdir -p $(SHADER_OUT)
	$(SLANG) $(SHADER_SRC) -entry vertexMain -target spirv -o $@

$(SHADER_OUT)/triangle.frag.spv: $(SHADER_SRC)
	@mkdir -p $(SHADER_OUT)
	$(SLANG) $(SHADER_SRC) -entry pixelMain -target spirv -o $@

$(SHADER_OUT)/compute.msl: shaders/compute.slang
	@mkdir -p $(SHADER_OUT)
	$(SLANG) shaders/compute.slang -entry computeMain -target metal -o $@

$(SHADER_OUT)/compute.spv: shaders/compute.slang
	@mkdir -p $(SHADER_OUT)
	$(SLANG) shaders/compute.slang -entry computeMain -target spirv -o $@

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

test: shaders
	$(ODIN) test $(SRC)

test-optimized: shaders
	$(ODIN) test $(SRC) $(RELEASE_FLAGS)

clean:
	rm -f $(BIN) $(BIN_DEBUG) $(SHADER_FILES)
