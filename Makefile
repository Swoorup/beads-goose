# bd in Goose. `make` builds ./bd; `make test` runs the unit tests and the
# golden comparison against beads' Go types.

TOOLCHAIN_GOOSE := .toolchain/goose/build/goose
GOOSE ?= $(if $(wildcard $(TOOLCHAIN_GOOSE)),$(TOOLCHAIN_GOOSE),goose)

SOURCES := bd.goose $(wildcard beads/*.goose)
BUILD := build

.PHONY: all test unit golden golden-update toolchain clean

all: bd

bd: $(SOURCES)
	$(GOOSE) build -o $@ bd.goose

$(BUILD)/unit: tests/unit.goose tests/check.goose $(SOURCES)
	@mkdir -p $(BUILD)
	$(GOOSE) build -o $@ tests/unit.goose

$(BUILD)/golden: tests/golden.goose $(SOURCES)
	@mkdir -p $(BUILD)
	$(GOOSE) build -o $@ tests/golden.goose

test: unit golden

unit: $(BUILD)/unit
	$(BUILD)/unit

# The port's view of tests/golden/issues.jsonl against beads' own.
golden: $(BUILD)/golden
	$(BUILD)/golden < tests/golden/issues.jsonl | diff -u tests/golden/expected.txt -
	@echo "golden: $$(grep -c '^json' tests/golden/expected.txt) issues match beads' Go types"

# Regenerates tests/golden/expected.txt with beads' Go types (needs Go; set
# BEADS_DIR to use a local beads checkout).
golden-update:
	scripts/golden.sh

toolchain:
	scripts/install-goose.sh

clean:
	rm -rf bd $(BUILD)
