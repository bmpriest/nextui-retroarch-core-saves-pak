.PHONY: release dev test clean

ARCHIVE := ../RetroArch Core Saves.pak.zip
PACKAGE := RetroArch Core Saves.pak

release:
	rm -f "$(ARCHIVE)"
	git archive --worktree-attributes --format=zip --prefix="$(PACKAGE)/" \
		--output="$(ARCHIVE)" HEAD

dev:
	rm -f "$(ARCHIVE)"
	cd .. && zip -q -r "$(notdir $(ARCHIVE))" "$(PACKAGE)" \
		-x "$(PACKAGE)/.git" \
		-x "$(PACKAGE)/.git/*" \
		-x "$(PACKAGE)/bin/desktop" \
		-x "$(PACKAGE)/bin/desktop/*" \
		-x "$(PACKAGE)/bin/tests" \
		-x "$(PACKAGE)/bin/tests/*" \
		-x "$(PACKAGE)/__pycache__" \
		-x "$(PACKAGE)/__pycache__/*" \
		-x "$(PACKAGE)/bin/SHA256SUMS" \
		-x "$(PACKAGE)/Makefile" \
		-x "$(PACKAGE)/Findings.md" \
		-x "$(PACKAGE)/.gitignore" \
		-x "$(PACKAGE)/.gitattributes" \
		-x "$(PACKAGE)/RetroArch Core Saves.pak.zip"

test:
	bin/tests/test-core-saves.sh

clean:
	rm -f "$(ARCHIVE)"
