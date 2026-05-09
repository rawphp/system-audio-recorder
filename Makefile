PROJECT  := SystemAudioToMP3
SCHEME   := SystemAudioToMP3
XCODEPROJ := $(PROJECT).xcodeproj
DEST     := platform=macOS

.DEFAULT_GOAL := build

.PHONY: help all generate build run debug release test clean reset

help:
	@echo "Targets:"
	@echo "  make build      — generate + xcodebuild Debug (default)"
	@echo "  make run        — build, then launch the .app"
	@echo "  make test       — run all unit + integration tests"
	@echo "  make release    — xcodebuild Release"
	@echo "  make generate   — regenerate $(XCODEPROJ) from project.yml"
	@echo "  make clean      — xcodebuild clean"
	@echo "  make reset      — clean + delete DerivedData + regenerate"

all: build

generate:
	xcodegen generate

build: generate
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Debug -destination '$(DEST)' build

debug: build

release: generate
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Release -destination '$(DEST)' build

test: generate
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -destination '$(DEST)' test

run: build
	@APP_PATH=$$(xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Debug -destination '$(DEST)' -showBuildSettings build 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$$2} /WRAPPER_NAME/{w=$$2} END{print d "/" w}'); \
	echo "Launching $$APP_PATH"; \
	open "$$APP_PATH"

clean:
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) clean

reset: clean
	rm -rf ~/Library/Developer/Xcode/DerivedData/$(PROJECT)-*
	$(MAKE) generate
