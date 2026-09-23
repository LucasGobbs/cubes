ODIN      ?= odin
SRC       := ./src
BIN       := main
BIN_DEBUG := main_debug

RELEASE_FLAGS := -o:aggressive -microarch:native -no-bounds-check -disable-assert
DEBUG_FLAGS   := -debug -o:none

.PHONY: all build run run-optimized debug debug-optimized test test-optimized clean

all: build

build:
	$(ODIN) build $(SRC) -out:$(BIN) $(RELEASE_FLAGS)

run:
	$(ODIN) run $(SRC) -- $(ARGS)

run-optimized:
	$(ODIN) run $(SRC) $(RELEASE_FLAGS) -- $(ARGS)

debug:
	$(ODIN) build $(SRC) -out:$(BIN_DEBUG) $(DEBUG_FLAGS)

debug-optimized:
	$(ODIN) build $(SRC) -out:$(BIN_DEBUG) $(RELEASE_FLAGS) -debug

test:
	$(ODIN) test $(SRC)

test-optimized:
	$(ODIN) test $(SRC) $(RELEASE_FLAGS)

clean:
	rm -f $(BIN) $(BIN_DEBUG)
