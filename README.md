# playground

The server behind the [kaikai](https://github.com/kaikailang-org/kaikai)
playground: paste a program, compile it, see what it prints. Written in
kaikai, on the standard library alone.

The shape follows the [Go Playground](https://go.dev/blog/playground): a
page posts source to `/api/compile` and gets back the compiler's errors
or a list of output events. The page lives in
[kaikai-site](https://github.com/kaikailang-org/kaikai-site).

## How it works

- `main.kai` — the HTTP server. One fiber per connection, plain HTTP on
  the loopback interface; a reverse proxy in front terminates TLS and
  rate-limits by address.
- `broker.kai` — two actors. The *gate* lets four jobs run at once and
  eight wait; past that a request gets `503`. The *cache* remembers
  finished responses by the SHA-256 of their source.
- `runner.kai` — one submission: write the source to a fresh job
  directory, `kai build`, run the binary. Each child runs in its own
  process group with a watchdog fiber that kills it at the deadline, and
  is also killed once it prints more than the output cap.
- `sandbox/` — the launcher every child goes through. `bwrap.sh`
  isolates it with bubblewrap (no network, read-only system, private
  process tree); `none.sh` does not, and is for development.

## API

| Call | Body | Answer |
|---|---|---|
| `POST /api/compile` | `{"body": source}` | `{"errors", "events": [{"kind", "message", "delay"}], "status", "reason"}` |
| `POST /api/fmt` | `{"body": source}` | `{"body", "error"}` |
| `GET /api/version` | | `{"version"}` |

`reason` is empty for a program that ran to the end, and otherwise one of
`timeout`, `output_limit`, `killed`, `build_timeout`, `build_killed`,
`internal`.

## Running it

```sh
make run            # listens on 127.0.0.1:8090, no isolation
make smoke          # in another shell
```

Settings come from the environment:

| Variable | Default |
|---|---|
| `PLAYGROUND_PORT` | `8090` |
| `PLAYGROUND_LAUNCHER` | `sandbox/none.sh` |
| `PLAYGROUND_KAI` | `kai` |
| `PLAYGROUND_WORKDIR` | `/tmp/kaikai-playground` |
| `PLAYGROUND_BUILD_SECS` | `10` |
| `PLAYGROUND_RUN_SECS` | `5` |
| `PLAYGROUND_MAX_OUTPUT` | `65536` |

`sudo sh deploy/setup.sh` installs or updates everything on a Debian or
Ubuntu host: bubblewrap, the toolchain, the service and the nginx location.
Never expose a server running `none.sh`: a submitted program can call
any C function through `extern "C"`.
