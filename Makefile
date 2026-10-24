.PHONY: build run smoke test

build:
	mkdir -p build
	kai build -o build/playground

run: build
	./build/playground

test:
	mkdir -p build
	kai test .

# Needs a server already running on the default port.
smoke:
	tests/smoke.sh
