#!/bin/sh
# Launcher that isolates every child with bubblewrap: no network, a
# read-only system, its own process tree, and the job directory as the
# only place it may touch.
#   bwrap.sh <jobdir> build <cmd...>   job directory writable, toolchain visible
#   bwrap.sh <jobdir> run <cmd...>     job directory read-only
#   bwrap.sh <jobdir> clean            remove jobdir
#   bwrap.sh <jobdir> warm <cmd...>    like build, but fills the compiler cache
#
# PLAYGROUND_KAI_HOME is the toolchain prefix (the directory holding
# bin/kai). PLAYGROUND_CACHE holds the compiler's cache of the standard
# library: builds read it and only `warm` writes it, so a submission
# cannot plant anything there. Without it every build starts cold.
# Memory is not limited here; the service's cgroup does that.
set -eu
dir=$1 mode=$2
shift 2
kai_home=${PLAYGROUND_KAI_HOME:-/opt/kaikai}
cache=${PLAYGROUND_CACHE:-/opt/kaikai-playground/cache}

case "$dir" in
  */job-*) ;;
  *) echo "launcher: not a job directory: $dir" >&2; exit 2 ;;
esac

isolate() {
  exec bwrap \
    --unshare-all --die-with-parent --cap-drop ALL \
    --hostname playground \
    --clearenv \
    --setenv PATH "$kai_home/bin:/usr/bin:/bin" \
    --setenv HOME /tmp \
    --setenv KAIKAI_HOME "$kai_home" \
    --setenv KAI_THREADS 2 \
    --ro-bind /usr /usr \
    --symlink usr/bin /bin \
    --symlink usr/lib /lib \
    --symlink usr/lib64 /lib64 \
    --ro-bind-try /etc/alternatives /etc/alternatives \
    --ro-bind-try /etc/ld.so.cache /etc/ld.so.cache \
    --proc /proc --dev /dev \
    --size 16777216 --tmpfs /tmp \
    "$@" 2>&1
}

toolchain() {
  cache_bind=$1
  shift
  isolate --ro-bind "$kai_home" "$kai_home" \
    "$cache_bind" "$cache" /cache --setenv XDG_CACHE_HOME /cache \
    --bind "$dir" /job --chdir /job -- "$@"
}

case "$mode" in
  clean)
    exec rm -rf -- "$dir" ;;
  build)
    ulimit -t 30
    toolchain --ro-bind-try "$@" ;;
  warm)
    toolchain --bind "$@" ;;
  run)
    ulimit -t 10
    isolate --ro-bind "$dir" /job --chdir /job -- "$@" ;;
  *)
    echo "launcher: unknown mode: $mode" >&2; exit 2 ;;
esac
