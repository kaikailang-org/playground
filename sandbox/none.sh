#!/bin/sh
# Launcher with no isolation, for development only.
#   none.sh <jobdir> build|run <cmd...>   run cmd inside jobdir
#   none.sh <jobdir> clean                remove jobdir
set -eu
dir=$1 mode=$2
shift 2
case "$dir" in
  */job-*) ;;
  *) echo "launcher: not a job directory: $dir" >&2; exit 2 ;;
esac
case "$mode" in
  clean) exec rm -rf -- "$dir" ;;
  build|run) cd "$dir" && exec "$@" 2>&1 ;;
  *) echo "launcher: unknown mode: $mode" >&2; exit 2 ;;
esac
