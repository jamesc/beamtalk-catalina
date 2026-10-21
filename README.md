# catalina

A socket server for [Beamtalk](https://www.beamtalk.dev): an acceptor pool
that hands each connection to its own handler process. It is a port of
Elixir's [Thousand Island](https://github.com/mtrudel/thousand_island), with
the same process model, options and defaults, written in Beamtalk
throughout (supervisors included).
[Buccaneer](https://github.com/jamesc/beamtalk-buccaneer), the Bandit port,
builds on it.

## Installation

```bash
beamtalk deps add catalina --git https://github.com/jamesc/beamtalk-catalina
```

It needs OTP 28 and a Beamtalk build that includes the stdlib work tracked in
BT-3957 (CI uses the `edge` build).

## Usage

Subclass `Handler` and override the callbacks you need. Each answers a
`HandlerResult`:

```beamtalk
Handler subclass: EchoHandler
  handleData: data :: Object socket: sock :: Socket state: st :: Object -> HandlerResult =>
    sock send: data
    HandlerResult continue: st
```

Start a server with the `ServerConfig` options:

```beamtalk
srv := (Catalina start: #{#port => 4000, #handler => EchoHandler}) unwrap
srv listenerInfo     // => Result ok: {{0, 0, 0, 0}, 4000}
srv info             // => #{#status => #running, #localInfo => ..., #activeConnections => 0}
srv suspend          // stop accepting; existing connections carry on
srv resume
srv stop: 15000      // stop, waiting up to 15 s for connections to finish
```

TLS: pass `#transport => SSLTransport` and the `ssl` options in
`transportOptions`:

```beamtalk
srv := (Catalina start: #{
  #port => 4443,
  #handler => EchoHandler,
  #transport => SSLTransport,
  #transportOptions => #{#certfile => "cert.pem", #keyfile => "key.pem"}
}) unwrap
```

## Public API

This is the stable surface: what Buccaneer (the Bandit port) and other
users may rely on. `SurfaceTest` exercises it the way Bandit uses Thousand
Island. Anything not listed is internal.

**Starting and running a server** (`Catalina`, `ServerSupervisor`):

- `Catalina start: options -> Result(ServerSupervisor, Error)`.
- `srv listenerInfo -> Result({ip, port})`, `connectionPids`, `status`
  (`#running`/`#suspended`), `info` (`#status`, `#localInfo`,
  `#activeConnections`), `suspend`, `resume`, `stop`, `stop: ms`.

**Options** (`ServerConfig`): Thousand Island's, in camelCase.
`ServerConfig optionNames` lists them (Bandit's
`ServerConfig.__struct__()`): `port`, `transport`, `transportOptions`,
`handler`, `handlerOptions`, `genServerOptions`, `supervisorOptions`,
`numAcceptors`, `numListenSockets`, `numConnections`,
`maxConnectionsRetryCount`, `maxConnectionsRetryWait`, `readTimeout`,
`handshakeTimeout`, `shutdownTimeout`, `silentTerminateOnError`.

`transportOptions` and `supervisorOptions` take a Dictionary
(`#{#reuseport => true}`), where Thousand Island takes a keyword list.
`#key => value` becomes the Erlang option `{key, value}`. The atom-only
listen options `binary`, `list`, `inet`, `inet6` and `local` take `true`
(the bare atom) or `false` (left out). A key that is not a Symbol, or an
atom-only option that is not `true` or `false`, is an error. A List is
passed through as a raw Erlang proplist (`#(#inet6, {#reuseport, true})`),
for when the order of the options matters or an option has no Dictionary
form. Either way, `config transportOptions` answers the proplist.

**Handlers** (`Handler`, a `typed` `Server`; subclasses annotate their
callbacks):

- Callbacks: `handleConnection:state:`, `handleData:socket:state:`,
  `handleClose:state:`, `handleError:socket:state:`,
  `handleShutdown:state:`, `handleTimeout:state:`, `handleUserInfo:`.
- State: `socket` and `userState` (Thousand Island's `{socket, state}`);
  the first `userState` is `handlerOptions`.
- `handleContinuation: aHandlerResult` re-arms from `handleUserInfo:` or
  any other method.
- A handler's own sync methods and casts (`!`) work beside the callbacks,
  and `doesNotUnderstand:args:` forwards unknown ones, so a delegating
  handler (Bandit's `DelegatingHandler`) needs nothing more.

**`HandlerResult`**: `continue:`, `continue:timeout:`,
`continue:persistentTimeout:`, `continue:then:`, `close:`, `error:state:`,
`switchTransport:options:state:` (and its `timeout:`, `persistentTimeout:`
and `then:` forms).

**`Socket`**: `send:`, `recv`, `recv:`, `recv:timeout:`,
`sendfile:offset:length:`, `setopts:`, `getopts:`, `shutdown:`, `close`,
`peername`, `sockname`, `peercert`, `isSecure`, `getstat`,
`negotiatedProtocol`, `connectionInformation`, `readTimeout`,
`telemetrySpan`. Errors are bare Erlang reasons (`Result error: #closed`).

**Transports**: `TCPTransport`, `SSLTransport`, and the `Transport`
protocol for your own (sealed, with `class sealed` methods).

**Telemetry**: `telemetry` events `[catalina, listener|acceptor|connection,
...]`, with Thousand Island's names, measurements and metadata (see
`CatalinaTelemetry`). Attach with the stdlib `Telemetry attach:to:do:`, or
`CatalinaLogger attach: #error`/`#info`/`#debug`/`#trace` to log them.
`Socket telemetrySpan` is the connection's `CatalinaTelemetry` span, and
its `telemetrySpanContext` parents your own spans.

Not there yet: a handler cannot handle a linked process's abnormal exit
itself (BT-4052).

## Classes

| Class | Role | Thousand Island |
|---|---|---|
| `Catalina` | `start:` | `ThousandIsland` |
| `ServerConfig` | the options and their defaults | `ServerConfig` |
| `ServerSupervisor` | one server: `listenerInfo`, `connectionPids`, `status`, `info`, `suspend`, `resume`, `stop:` | `Server` and the `ThousandIsland` functions |
| `Handler`, `HandlerResult` | the per-connection process and its callbacks' answers | `Handler` |
| `Socket` | a connection as a handler sees it | `Socket` |
| `Transport`, `TCPTransport`, `SSLTransport` | the transports | `Transport`, `Transports.TCP`, `Transports.SSL` |
| `TransportOptions`, `TransportResult` | listen options; bare error reasons | `Transport.resolve_options/1` |
| `CatalinaTelemetry`, `CatalinaLogger` | telemetry spans and events; logging them | `Telemetry`, `Logger` |
| `Listener`, `Acceptor`, `Connection`, the supervisors | the server's internals | as named |

## Development

```bash
just build    # compile
just test     # BUnit tests (fails on any warning)
just lint
just fmt      # check formatting (just fmt-fix to apply)
just ci       # all of the above, as CI runs them
just spikes   # the Phase 0 spikes (loopback sockets and timing)
just bench    # Catalina vs Thousand Island (see below)
just stress   # correctness under load and failure (see below)
```

`PLAN.md` is the porting plan and records each phase's deviations from
Thousand Island; `AGENTS.md` is the guide for coding agents. Every class is
`typed` and the build fails on type warnings.

## Benchmarks and stress tests

Two harnesses check Catalina under load. Neither is part of `just test`.

```bash
just bench                  # Catalina vs Thousand Island, 5 interleaved rounds
just bench --rounds 7 --duration 10000 --only echo_c100_64B,accept_tcp
just stress                 # the stress tests, with a 30-minute soak
just stress --smoke         # smaller sizes and a 1-minute soak (as CI runs it)
just stress --only fuzz,chaos --impl catalina
```

They need Elixir 1.18 or later (`bench/thousand_island/.tool-versions`
pins 1.20.1 on OTP 28.5) and `beamtalk` on the `PATH`. `bench/run.sh`
builds everything first: the Catalina peer package (`bench/catalina_node`,
the echo handlers), the [Thousand Island](https://hex.pm/packages/thousand_island)
1.6.0 baseline (`bench/thousand_island`, a mix project with the
equivalent handlers) and the Erlang harness, into `_build/bench`.

Each server runs in its own peer VM, started with OTP's `peer` and driven
over its control channel. The load generator runs in a third VM: a pool of
client processes counting into shared `counters`, with a log-scale latency
histogram. Both servers use the same configuration (echo handler, 100
acceptors, the transports' default options and buffer sizes, the same
certificate for TLS).

**`just bench`** measures echo throughput and round-trip latency
(p50/p99/p99.9) at 1, 10, 100 and 1,000 connections with 64 B and 64 KiB
payloads; the accept rate under connection churn (connect, one echo, close);
TLS handshakes per second and TLS echo at 100 connections; and bytes and
processes per idle connection with 10,000 idle connections. Every round
measures each row on Catalina and on Thousand Island back to back,
alternating which goes first, so machine load hits both alike. The report
gives the medians, every round's value, and the Catalina ÷ Thousand Island
ratio, with the machine, versions and load averages. It is written to
`_build/bench/report-*.md`, with the raw measurements in
`_build/bench/raw-*.jsonl`. The client closes connections with a reset
(linger 0), so churn does not run out of ephemeral ports to `TIME_WAIT`.
`bench/RESULTS.md` holds the release measurements.

`bench/run.sh bench_profile --impl catalina --row echo_c10_64KiB` profiles one
row: it runs the load from the harness VM while the server node records call
time (or `--type call_count`) for every function, and prints the top functions
and modules. It reads the breakpoints directly rather than through `tprof` or
`eprof`, which crash on Beamtalk modules (they export no `module_info/1`).

**`just stress`** (`test/stress/`) runs each test against Catalina and,
where the expectation is "as Thousand Island does", against Thousand Island
with the same assertions:

| Test | Checks |
|---|---|
| `fuzz_tcp`, `fuzz_tls` | random payloads from 0 to 1 MiB in random fragments over many connections come back byte for byte |
| `leak_churn` | after 10,000 churn cycles (clean closes, resets, no data, mid-echo) process, port and ETS counts and the connection supervisors' children return to the baseline |
| `leak_server_lifecycle` | starting and stopping TCP and TLS servers with live connections leaves nothing behind |
| `limits_*` | at `numConnections` a connection waits out the retries and is closed unserved, is served if a slot frees in time, and the server recovers |
| `timeout_*`, `half_close` | idle and slow-trickling connections close at `readTimeout` (bytes more often than that keep a connection open, as in Thousand Island); many slow-loris connections at once; half-close |
| `chaos_*` | under load, random acceptors and handlers are killed: the server keeps serving, no bytes are corrupted, supervisors restart within their intensity, nothing leaks |
| `lifecycle_*` | `suspend`/`resume` under load; `stop:` lets in-flight callbacks finish within `shutdownTimeout` and kills them past it |
| `soak_mixed_load` | 30 minutes of mixed TCP and TLS load: no growth in process count or memory, and back to the baseline afterwards |

Server logs go to `_build/stress/`.

## License

Apache-2.0. Thousand Island is MIT-licensed; its design and tests are the
basis of this port.
