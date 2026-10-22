# bd in Goose. `make` builds ./bd; `make test` runs the unit tests and the
# golden comparison against beads' Go types.

TOOLCHAIN_GOOSE := .toolchain/goose/build/goose
GOOSE ?= $(if $(wildcard $(TOOLCHAIN_GOOSE)),$(TOOLCHAIN_GOOSE),goose)

SOURCES := bd.goose $(wildcard beads/*.goose)
BUILD := build

.PHONY: all test unit golden golden-update toolchain clean FORCE

all: bd

bd: $(SOURCES) $(BUILD)/build_info.goose
	$(GOOSE) build -o $@ bd.goose

# The commit and branch bd reports, as Go's bd reads them from its build
# info. Rewritten only when they change, so bd is not rebuilt for nothing.
$(BUILD)/build_info.goose: FORCE
	@mkdir -p $(BUILD)
	@printf 'namespace build_info;\nlet COMMIT = "%s";\nlet BRANCH = "%s";\n' \
		"$$(git rev-parse HEAD 2>/dev/null)" \
		"$$(git symbolic-ref --short HEAD 2>/dev/null)" > $@.tmp
	@cmp -s $@.tmp $@ && rm $@.tmp || mv $@.tmp $@

FORCE:

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
