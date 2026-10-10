.PHONY: build run smoke

build:
	mkdir -p build
	kai build -o build/playground

run: build
	./build/playground

# Needs a server already running on the default port.
smoke:
	tests/smoke.sh
