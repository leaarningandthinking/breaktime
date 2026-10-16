APP     := BreakTime.app
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)

.PHONY: all build arm run dist release clean help

all: build

## build  : universal binary (Apple silicon + Intel)
build:
	./build.sh

## arm    : faster, Apple-silicon-only build
arm:
	./build.sh arm64

## run    : build, restart the app
run: build
	-pkill -f "$(APP)/Contents/MacOS/BreakTime" 2>/dev/null || true
	sleep 1
	open $(APP)

## dist   : build + package dist/BreakTime-<version>.zip
dist: build
	./scripts/make-dist.sh

## release: package, tag v<version>, push the tag (triggers the release workflow)
release: dist
	git tag -a v$(VERSION) -m "BreakTime v$(VERSION)"
	git push origin v$(VERSION)

## clean  : remove build products
clean:
	rm -rf $(APP) dist .build
	@echo "cleaned"

help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  /'
