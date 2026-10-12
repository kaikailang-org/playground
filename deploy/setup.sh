#!/bin/sh
# Installs or updates the playground on a Debian/Ubuntu host. Run it as
# root from a checkout of this repository:
#
#   sudo sh deploy/setup.sh [site-config]
#
# site-config is the nginx file whose server block should serve /api/
# (default: /etc/nginx/sites-enabled/kaikai-lang.org). Safe to run again.
#
# UPGRADE_KAI=1 also moves the toolchain to its latest release first.
set -eu

site=${1:-/etc/nginx/sites-enabled/kaikai-lang.org}
src=$(cd "$(dirname "$0")/.." && pwd)
kai_home=/opt/kaikai
app=/opt/kaikai-playground

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

echo "==> bubblewrap"
command -v bwrap >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -q bubblewrap

echo "==> kaikai toolchain in $kai_home"
if [ ! -x "$kai_home/bin/kai" ]; then
  mkdir -p "$kai_home"
  scratch=$(mktemp -d)
  # A throwaway HOME keeps the installer from editing root's shell profile.
  curl -fsSL https://raw.githubusercontent.com/kaikailang-org/kaikai/main/install.sh |
    HOME="$scratch" SHELL=/bin/sh KAIKAI_HOME="$kai_home" sh
  rm -rf "$scratch"
fi
if [ "${UPGRADE_KAI:-0}" = 1 ]; then
  scratch=$(mktemp -d)
  HOME="$scratch" KAIKAI_HOME="$kai_home" "$kai_home/bin/kai" upgrade
  rm -rf "$scratch"
fi
"$kai_home/bin/kai" --version

echo "==> service user"
id playground >/dev/null 2>&1 ||
  useradd --system --home-dir "$app" --shell /usr/sbin/nologin playground

echo "==> private copy of bubblewrap"
# Only this copy is allowed to create user namespaces, and only the
# playground group may run it, so the rest of the host keeps Ubuntu's
# restriction on /usr/bin/bwrap.
mkdir -p "$app/bin"
install -o root -g playground -m 750 "$(command -v bwrap)" "$app/bin/bwrap"
if [ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = 1 ]; then
  install -m 644 "$src/deploy/apparmor-bwrap" /etc/apparmor.d/kaikai-playground-bwrap
  apparmor_parser -r /etc/apparmor.d/kaikai-playground-bwrap
fi
# Earlier versions of this script opened /usr/bin/bwrap to everyone.
if grep -qs 'lets bubblewrap create its sandbox' /etc/apparmor.d/bwrap; then
  apparmor_parser -R /etc/apparmor.d/bwrap || true
  rm -f /etc/apparmor.d/bwrap
fi

echo "==> build"
# Imports resolve through the directory name, so it must be the package's.
scratch=$(mktemp -d)
build=$scratch/playground
mkdir "$build"
cp -R "$src/." "$build/"
rm -rf "$build/build" "$build/.kai-cache"
(cd "$build" && mkdir -p build && PATH="$kai_home/bin:$PATH" kai build -o build/playground)
mkdir -p "$app/sandbox"
install -m 755 "$build/build/playground" "$app/playground.new"
mv "$app/playground.new" "$app/playground"
install -m 755 "$src/sandbox/bwrap.sh" "$app/sandbox/bwrap.sh"
rm -rf "$scratch"

echo "==> compiler cache and sandbox check"
# Rebuilt from scratch so it always matches the installed toolchain.
rm -rf "$app/cache"
mkdir -p "$app/cache"
chown playground "$app/cache"
job=$(mktemp -d /tmp/job-XXXXXX)
chown playground "$job"
# Importing the modules a playground program is likely to use puts them
# in the cache too.
cat > "$job/main.kai" <<'KAI'
import time
import loop
import spawn
import actor
import collections.map as cmap
import encoding.json

fn main() {
  println("sandbox ok")
}
KAI
chown playground "$job/main.kai"
as_playground() {
  runuser -u playground -- env PLAYGROUND_KAI_HOME="$kai_home" PLAYGROUND_BWRAP="$app/bin/bwrap" "$@"
}
as_playground "$app/sandbox/bwrap.sh" "$job" warm kai build main.kai -o prog
started=$(date +%s)
as_playground "$app/sandbox/bwrap.sh" "$job" build kai build main.kai -o prog
echo "warm build: $(( $(date +%s) - started ))s"
as_playground "$app/sandbox/bwrap.sh" "$job" run ./prog
rm -rf "$job"

echo "==> systemd"
install -m 644 "$src/deploy/playground.service" /etc/systemd/system/kaikai-playground.service
systemctl daemon-reload
systemctl enable -q kaikai-playground
systemctl restart kaikai-playground
sleep 1
curl -fsS http://127.0.0.1:8090/api/version; echo
# The same path a visitor takes, through the service's own limits.
curl -fsS -X POST http://127.0.0.1:8090/api/compile \
  -d '{"body":"fn main() {\n  println(\"service ok\")\n}\n"}' | grep -q 'service ok' ||
  { echo "the service cannot run a program; see journalctl -u kaikai-playground" >&2; exit 1; }
echo "service ok"

echo "==> nginx"
install -m 644 "$src/deploy/nginx-zones.conf" /etc/nginx/conf.d/kaikai-playground.conf
install -m 644 "$src/deploy/nginx-location.conf" /etc/nginx/snippets/kaikai-playground.conf
real=$(readlink -f "$site")
if ! grep -q 'snippets/kaikai-playground.conf' "$real"; then
  cp "$real" "/root/$(basename "$real").before-playground"
  # Into the TLS server block, right before its `location /`.
  sed -i '0,/^    location \/ {/s||    include snippets/kaikai-playground.conf;\n\n&|' "$real"
  grep -q 'snippets/kaikai-playground.conf' "$real" ||
    { echo "could not place the include in $real; add it by hand" >&2; exit 1; }
fi
if nginx -t; then
  systemctl reload nginx
else
  echo "nginx rejected the configuration; restoring $real" >&2
  [ -e "/root/$(basename "$real").before-playground" ] &&
    cp "/root/$(basename "$real").before-playground" "$real"
  rm -f /etc/nginx/conf.d/kaikai-playground.conf
  exit 1
fi
echo "done"
