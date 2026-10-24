#!/bin/sh
# Starts ./build/playground on a port of its own, runs tests/smoke.sh
# against it and stops it: tests/serve.sh [port]
#
# The work directory does not exist beforehand: the server must make it.
set -u
port=${1:-8291}
root=$(mktemp -d "${TMPDIR:-/tmp}/playground-serve.XXXXXX") || exit 1
PLAYGROUND_WORKDIR=$root/work/jobs PLAYGROUND_PORT=$port ./build/playground >"$root/log" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; wait $srv 2>/dev/null; rm -rf "$root"' EXIT
i=0
until curl -s -o /dev/null "http://127.0.0.1:$port/healthz"; do
  i=$((i + 1))
  if [ $i -gt 50 ] || ! kill -0 $srv 2>/dev/null; then
    echo "FAIL the server did not start: $(cat "$root/log")"
    exit 1
  fi
  sleep 0.2
done
tests/smoke.sh "http://127.0.0.1:$port"
