.PHONY: release dev test clean sync-mounts

ARCHIVE := dist/RetroArch Core Saves.pak.zip
PACKAGE := RetroArch Core Saves.pak
MOUNT_MANAGER := ../mount-manager

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
	sh bin/tests/test-core-saves.sh
	sh bin/tests/test-core-saves-mounts.sh

# bin/mounts is a copy of ../mount-manager, the source shared with Profiles.pak.
sync-mounts:
	mkdir -p bin/mounts
	cp $(MOUNT_MANAGER)/mountctl.sh $(MOUNT_MANAGER)/layers/20-core-saves.sh bin/mounts/
	chmod 0755 bin/mounts/*.sh

clean:
	rm -f "$(ARCHIVE)"
