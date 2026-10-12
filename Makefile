# Ol1nPlay — bit-perfect ASIO player. See BUILD.md for prerequisites.

ENGINE_DIR := engine
BIN        := $(ENGINE_DIR)/bin
VERSION    ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS    := -s -w -X github.com/ol1n/ol1nplay/engine/api.Version=$(VERSION)
MINGW      ?= x86_64-w64-mingw32-gcc

.PHONY: all engine engine-windows test test-race vet lint apps shared desktop remote \
        fixtures clean dist-windows check-ffmpeg-win

all: engine

## ---- engine (Go) -------------------------------------------------------

engine:                     ## native engine binary (macOS/Linux dev builds)
	cd $(ENGINE_DIR) && go build -ldflags "$(LDFLAGS)" -o bin/ol1nplay-engine ./cmd/engine

check-ffmpeg-win:
	@test -d $(ENGINE_DIR)/ffmpeg-win/include || { echo "engine/ffmpeg-win/{include,lib,bin} missing — see BUILD.md"; exit 1; }

engine-windows: check-ffmpeg-win   ## cross-compile ol1nplay-engine.exe (needs mingw-w64 + ffmpeg-win)
	cd $(ENGINE_DIR) && CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC=$(MINGW) \
	  go build -ldflags "$(LDFLAGS)" -o bin/ol1nplay-engine.exe ./cmd/engine

test:                       ## engine unit + integration tests (null backend)
	cd $(ENGINE_DIR) && go test ./...

test-race:
	cd $(ENGINE_DIR) && go test -race ./...

vet:                        ## vet native and for GOOS=windows
	cd $(ENGINE_DIR) && go vet ./... && \
	  CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC=$(MINGW) go vet ./asio ./wasapi ./sysmode ./mediakeys ./winrt ./sink/... ./ringbuf ./memlock

lint: vet
	cd $(ENGINE_DIR) && test -z "$$(gofmt -l .)" || { gofmt -l .; exit 1; }

fixtures:                   ## regenerate engine/testdata (needs ffmpeg CLI)
	cd $(ENGINE_DIR)/testdata && ./gen.sh

## ---- Flutter -------------------------------------------------------------

shared:
	cd shared && flutter pub get && flutter analyze && flutter test

desktop:
	cd app_desktop && flutter pub get && flutter analyze && flutter test

remote:
	cd app_remote && flutter pub get && flutter analyze && flutter test

apps: shared desktop remote

## ---- distribution ---------------------------------------------------------

# Windows bundle: engine exe + FFmpeg DLLs next to the Flutter build.
dist-windows: engine-windows
	mkdir -p dist/windows/engine
	cp $(BIN)/ol1nplay-engine.exe dist/windows/engine/
	cp $(ENGINE_DIR)/ffmpeg-win/bin/avcodec-*.dll $(ENGINE_DIR)/ffmpeg-win/bin/avformat-*.dll \
	   $(ENGINE_DIR)/ffmpeg-win/bin/avutil-*.dll $(ENGINE_DIR)/ffmpeg-win/bin/swresample-*.dll dist/windows/engine/
	# MinGW builds import the pthread runtime; without it the engine does not start.
	cp "$$(find -L "$$(dirname "$$(realpath "$$(command -v $(MINGW))")")/.." -name libwinpthread-1.dll | head -1)" dist/windows/engine/
	cp $(ENGINE_DIR)/ffmpeg-win/LICENSE.txt dist/windows/engine/FFMPEG-LICENSE.txt 2>/dev/null || true
	@echo "now: cd app_desktop && flutter build windows && copy build/windows/x64/runner/Release/* to dist/windows/"

clean:
	rm -rf $(BIN) dist

help:
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-18s %s\n", $$1, $$2}'
