.PHONY: release dev test clean

ARCHIVE := dist/RetroArch Core Saves.pak.zip
PACKAGE := RetroArch Core Saves.pak

release:
	mkdir -p dist
	rm -f "$(ARCHIVE)"
	git archive --worktree-attributes --format=zip \
		--output="$(ARCHIVE)" HEAD

dev:
	mkdir -p dist
	rm -f "$(ARCHIVE)"
	zip -q -r "$(notdir $(ARCHIVE))" . \
		-x "/.git" \
		-x "/.git/*" \
		-x "/bin/desktop" \
		-x "/bin/desktop/*" \
		-x "/bin/tests" \
		-x "/bin/tests/*" \
		-x "/__pycache__" \
		-x "/__pycache__/*" \
		-x "/bin/SHA256SUMS" \
		-x "/dist/*" \
		-x "/screenshots/*" \
		-x "/Makefile" \
		-x "/Findings.md" \
		-x "/.gitignore" \
		-x "/.gitattributes" \
		-x "/RetroArch Core Saves.pak.zip"

test:
	bin/tests/test-core-saves.sh

clean:
	rm -f "$(ARCHIVE)"
