APP      := dist/Perch.app
BIN      := .build/release
CONFIG   := release
# Local builds carry the git version (e.g. 0.5.0-4-g3566c79-dirty) so About /
# --version / Doctor identify the build; releases overwrite this with the tag
# in build-dmg.sh. Empty (no git / no repo) leaves the 0.0.0 dev-build marker.
GIT_VERSION := $(shell git describe --tags --always --dirty 2>/dev/null | sed 's/^v//')

.PHONY: build app dmg run test clean debug fuzz meta fitness verify hooks

build:
	swift build -c $(CONFIG)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN)/Perch $(APP)/Contents/MacOS/Perch
	cp $(BIN)/perch-bridge $(APP)/Contents/Resources/perch-bridge
	cp Support/Info.plist $(APP)/Contents/Info.plist
	if [ -n "$(GIT_VERSION)" ]; then \
		plutil -replace CFBundleShortVersionString -string "$(GIT_VERSION)" $(APP)/Contents/Info.plist; \
	fi
	cp Support/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	codesign --force -s - $(APP)/Contents/Resources/perch-bridge
	codesign --force -s - $(APP)
	@echo "Built $(APP)"

dmg: app
	scripts/build-dmg.sh

run: app
	open $(APP)

test: build
	$(BIN)/Perch --selftest

# Harness oracles for bug-bashing PerchCore (see docs / README).
# fuzz: crash+hang oracle over parse/scoring surface. meta: metamorphic
# relation oracle over RiskAssessor. Neither needs labelled data.
fuzz:
	scripts/fuzz.sh both $(or $(N),1000000)

meta:
	swift build -c $(CONFIG) --product PerchMeta
	$(BIN)/PerchMeta

# Executable invariants — CLAUDE.md's prose rules, mechanised. Pure source scan
# (no build), so it's the fast pre-commit / CI tripwire. See scripts/fitness.sh.
fitness:
	scripts/fitness.sh

verify: fitness test meta

# One-time per clone: point git at the tracked hook (git won't auto-run repo
# hooks on clone, by design). The hook runs `make fitness` before each commit.
hooks:
	git config core.hooksPath .githooks
	@echo "pre-commit hook active (.githooks) — runs scripts/fitness.sh"

debug:
	swift build

clean:
	rm -rf .build dist
