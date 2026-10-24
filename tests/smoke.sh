#!/bin/sh
# Exercises a running playground server: tests/smoke.sh [base-url]
set -u
base=${1:-http://127.0.0.1:8090}
fails=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pg-smoke.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

post() { curl -s -o "$tmp/out" -w '%{http_code}' -X POST "$base$1" --data-binary "$2"; }

expect() {
  name=$1 code=$2 want_code=$3 want_text=$4
  if [ "$code" = "$want_code" ] && grep -q -- "$want_text" "$tmp/out"; then
    echo "ok   $name"
  else
    echo "FAIL $name: status $code, body $(head -c 300 "$tmp/out")"
    fails=$((fails + 1))
  fi
}

program() { jq -Rs '{body: .}'; }

hello=$(printf 'fn main() : Unit / Console = {\n  println("hola")\n}\n' | program)
broken=$(printf 'fn main() : Unit / Console = {\n  println(nope)\n}\n' | program)
spin=$(printf 'fn spin(n: Int) : Int = spin(n + 1)\n\nfn main() : Int = spin(0)\n' | program)
flood=$(printf 'fn flood(n: Int) : Unit / Console = {\n  println("lorem ipsum dolor sit amet")\n  flood(n + 1)\n}\n\nfn main() : Unit / Console = flood(0)\n' | program)
exit3=$(printf 'fn main() : Int = 3\n' | program)

expect "runs a program"        "$(post /api/compile "$hello")"  200 '"message":"hola\\n"'
expect "reports compile errors" "$(post /api/compile "$broken")" 200 'main.kai:2:11'
expect "reports the exit code" "$(post /api/compile "$exit3")"  200 '"status":3'
expect "stops a runaway loop"  "$(post /api/compile "$spin")"   200 '"reason":"timeout"'
expect "caps the output"       "$(post /api/compile "$flood")"  200 '"reason":"output_limit"'
expect "formats"               "$(post /api/fmt "$hello")"      200 '"error":""'
expect "rejects non-JSON"      "$(post /api/compile 'nope')"    400 'not JSON'
big=$(head -c 70000 /dev/zero | tr '\0' '#' | program)
expect "rejects large sources" "$(post /api/compile "$big")"    413 'too large'

# More simultaneous slow jobs than workers plus waiting room: some must
# be turned away, and the rest must still finish. Each job prints the
# pid of this run, so a cached answer never stands in for a real one.
i=0
while [ $i -lt 16 ]; do
  slow=$(printf 'import time\n\nfn main() : Unit / Console + Clock = {\n  sleep(seconds(2))\n  println("job %s")\n}\n' "$i-$$" | program)
  curl -s -o /dev/null -w '%{http_code}\n' -X POST "$base/api/compile" --data-binary "$slow" &
  i=$((i + 1))
done > "$tmp/codes"
wait
served=$(grep -c 200 "$tmp/codes")
turned=$(grep -c 503 "$tmp/codes")
if [ "$served" -ge 4 ] && [ "$turned" -ge 1 ] && [ $((served + turned)) -eq 16 ]; then
  echo "ok   sheds load ($served served, $turned turned away)"
else
  echo "FAIL sheds load: $served served, $turned turned away"
  fails=$((fails + 1))
fi

# Past 64 open connections a new one is closed unanswered, and the
# server takes connections again once those close.
hostport=${base#*://}
hostport=${hostport%%/*}
limit=$(perl -MIO::Socket::INET -e '
  my ($host, $port) = @ARGV;
  sub conn { IO::Socket::INET->new(PeerAddr => $host, PeerPort => $port) or die "connect: $!\n" }
  sub ask {
    my $c = conn();
    print $c "GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n";
    my $got = eval {
      local $SIG{ALRM} = sub { die "hung\n" };
      alarm 5;
      local $/;
      my $r = <$c>;
      alarm 0;
      defined $r ? $r : "";
    };
    return "hung" unless defined $got;
    return $got =~ m{^HTTP/1\.1 200} ? "served" : $got eq "" ? "closed" : "other";
  }
  my @idle = map { conn() } 1 .. 64;
  select(undef, undef, undef, 0.5);
  my $over = ask();
  close $_ for @idle;
  select(undef, undef, undef, 0.5);
  print "$over ", ask(), "\n";
' "${hostport%:*}" "${hostport##*:}" 2>&1)
if [ "$limit" = "closed served" ]; then
  echo "ok   limits connections"
else
  echo "FAIL limits connections: $limit"
  fails=$((fails + 1))
fi

expect "still alive"           "$(post /api/compile "$hello")"  200 '"message":"hola\\n"'
exit $fails
