#!/bin/sh
# Launcher that isolates every child with bubblewrap: no network, a
# read-only system, its own process tree, and the job directory as the
# only place it may touch.
#   bwrap.sh <jobdir> build <cmd...>   job directory writable, toolchain visible
#   bwrap.sh <jobdir> run <cmd...>     job directory read-only
#   bwrap.sh <jobdir> clean            kill what is left of the job, remove jobdir
#   bwrap.sh <jobdir> warm <cmd...>    like build, but fills the compiler cache
#
# PLAYGROUND_KAI_HOME is the toolchain prefix (the directory holding
# bin/kai). PLAYGROUND_CACHE holds the compiler's cache of the standard
# library: builds read it and only `warm` writes it, so a submission
# cannot plant anything there. Without it every build starts cold.
#
# With PLAYGROUND_CGROUPS=1 each job also gets a cgroup of its own, with
# a cap on memory and on the number of processes. That needs the service
# to run in a delegated cgroup, inside a subgroup (see the systemd unit).
set -eu
dir=$1 mode=$2
shift 2
kai_home=${PLAYGROUND_KAI_HOME:-/opt/kaikai}
cache=${PLAYGROUND_CACHE:-/opt/kaikai-playground/cache}
bwrap=${PLAYGROUND_BWRAP:-bwrap}

BUILD_MEMORY=1610612736 BUILD_TASKS=128
RUN_MEMORY=268435456 RUN_TASKS=64

case "$dir" in
  */job-*) ;;
  *) echo "launcher: not a job directory: $dir" >&2; exit 2 ;;
esac

# The job's cgroup, a sibling of the one the server itself lives in.
job_cgroup() {
  own=$(sed -n 's/^0:://p' /proc/self/cgroup)
  echo "/sys/fs/cgroup${own%/*}/${dir##*/}"
}

# Move this process, and so everything it starts, under the job's limits.
confine() {
  [ "${PLAYGROUND_CGROUPS:-0}" = 1 ] || return 0
  cg=$(job_cgroup)
  echo "+memory +pids" > "${cg%/*}/cgroup.subtree_control"
  mkdir -p "$cg"
  echo "$1" > "$cg/memory.max"
  [ ! -e "$cg/memory.swap.max" ] || echo 0 > "$cg/memory.swap.max"
  echo 1 > "$cg/memory.oom.group"
  echo "$2" > "$cg/pids.max"
  echo $$ > "$cg/cgroup.procs"
}

release() {
  [ "${PLAYGROUND_CGROUPS:-0}" = 1 ] || return 0
  cg=$(job_cgroup)
  [ -d "$cg" ] || return 0
  echo 1 > "$cg/cgroup.kill"
  # The kernel takes a moment to reap what was just killed.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    rmdir "$cg" 2>/dev/null && return 0
    sleep 0.1
  done
  echo "launcher: could not remove $cg" >&2
}

isolate() {
  exec "$bwrap" \
    --unshare-all --unshare-user --disable-userns \
    --die-with-parent --cap-drop ALL \
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
    release
    exec rm -rf -- "$dir" ;;
  build)
    confine $BUILD_MEMORY $BUILD_TASKS
    ulimit -t 30
    toolchain --ro-bind-try "$@" ;;
  warm)
    toolchain --bind "$@" ;;
  run)
    confine $RUN_MEMORY $RUN_TASKS
    ulimit -t 10
    isolate --ro-bind "$dir" /job --chdir /job -- "$@" ;;
  *)
    echo "launcher: unknown mode: $mode" >&2; exit 2 ;;
esac
