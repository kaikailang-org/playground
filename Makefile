.PHONY: build run smoke test check

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

# The unit tests, then the smoke suite against a server of its own.
CHECK_PORT ?= 8291
check: test build
	tests/serve.sh $(CHECK_PORT)
