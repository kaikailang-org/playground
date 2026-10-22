#!/bin/sh
# Builds the compiler cache that sandboxed builds read. Run it as root.
#
#   warm.sh          build a new cache and put it in place
#   warm.sh check    time a build against the cache in place, and build a
#                    new one only when that is slow or fails
#
# Builds cannot write the cache, so once it stops holding what the
# compiler wants, every build starts cold and runs into the build time
# limit. Filling the old cache again is not enough: a cached binary for
# the probe program spares the compiler the work that would put the
# missing pieces back. So the new cache starts empty, next to the old
# one, and replaces it only once a build against it is fast.
set -eu

app=${PLAYGROUND_APP:-/opt/kaikai-playground}
kai_home=${PLAYGROUND_KAI_HOME:-/opt/kaikai}
# A build against a good cache takes well under a second; a cold one, over ten.
slow=3

with_cache() {
  cache=$1
  shift
  runuser -u playground -- env PLAYGROUND_KAI_HOME="$kai_home" PLAYGROUND_BWRAP="$app/bin/bwrap" \
    PLAYGROUND_CACHE="$cache" "$app/sandbox/bwrap.sh" "$job" "$@"
}

job=$(mktemp -d /tmp/job-XXXXXX)
fresh=$app/cache.new
trap 'rm -rf "$job" "$fresh"' EXIT
chown playground "$job"
# Importing the modules a playground program is likely to use puts them
# in the cache too.
cat > "$job/main.kai" <<'KAI'
import time
import loop
import spawn
import collections.map as cmap
import encoding.json

fn main() {
  println("sandbox ok")
}
KAI
chown playground "$job/main.kai"

# Seconds a read-only build against the given cache takes, or 999 when it fails.
build_time() {
  started=$(date +%s)
  if with_cache "$1" build kai build main.kai -o prog >/dev/null 2>&1; then
    echo $(( $(date +%s) - started ))
  else
    echo 999
  fi
}

if [ "${1:-}" = check ]; then
  # The compiler takes an entry over an hour old as missing unless it can
  # touch it, and builds cannot; keeping every entry young avoids that.
  find "$app/cache" -exec touch -h {} +
  took=$(build_time "$app/cache")
  [ "$took" -ge "$slow" ] || exit 0
  echo "build against the cache took ${took}s; building a new one"
fi

rm -rf "$fresh"
mkdir -m 755 "$fresh"
chown playground "$fresh"
with_cache "$fresh" warm kai build main.kai -o prog >/dev/null 2>&1
took=$(build_time "$fresh")
echo "build against the new cache: ${took}s"
[ "$took" -lt "$slow" ] || { echo "the new cache does not help; keeping the old one" >&2; exit 1; }
rm -rf "$app/cache.old"
[ ! -d "$app/cache" ] || mv "$app/cache" "$app/cache.old"
mv "$fresh" "$app/cache"
rm -rf "$app/cache.old"
with_cache "$app/cache" run ./prog
