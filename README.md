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
With `UPGRADE_KAI=1` it first moves the toolchain to its latest release;
the compiler cache is rebuilt on every run, so it always matches.

## Isolation

A submitted program can call any C function through `extern "C"`, so
nothing here relies on the language to contain it:

- **bubblewrap** gives it no network, a read-only `/usr`, a private
  process tree and no way to create further user namespaces. The job
  directory is writable while compiling and read-only while running.
- **A cgroup per job** caps memory (256 MB to run, 1.5 GB to compile) and
  the number of processes (64 and 128). `clean` kills whatever is left.
- **The systemd unit** filters system calls for the service and all its
  children (no `bpf`, `io_uring`, `ptrace`, `userfaultfd`, keyrings…),
  drops every capability and mounts the system read-only.
- **AppArmor** lets only the playground's own copy of bubblewrap create
  user namespaces, and only the `playground` group can execute it.

The kernel is still shared with the host. A kernel exploit that gets
past the system call filter gets out; closing that takes gVisor or a
microVM.
Never expose a server running `none.sh`: a submitted program can call
any C function through `extern "C"`.
