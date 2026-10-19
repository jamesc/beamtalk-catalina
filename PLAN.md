# Catalina porting plan

Catalina is a port of [Thousand Island](https://github.com/mtrudel/thousand_island)
(v1.6.0) to Beamtalk: a pure socket server with pluggable transports (TCP, SSL),
an acceptor pool, per-connection handler processes, and telemetry.
[Buccaneer](https://github.com/jamesc/beamtalk-buccaneer) (the Bandit port) is
its first consumer, so the parts Bandit relies on are treated as the stable
surface.

## Goals

- Same process model and semantics as Thousand Island: a `rest_for_one` server
  tree, N acceptors each owning a connection supervisor, `active: :once`
  handlers, lazy read deadlines, graceful draining.
- Same option names and defaults (`numAcceptors`, `numConnections`,
  `readTimeout`, ...), so Buccaneer can validate options the way Bandit does.
- Idiomatic Beamtalk at the surface: a `Handler` you subclass, `Result` for
  expected failures, camelCase selectors.
- **Pure Beamtalk, supervisors included.** No `native/*.erl`. The only
  dependency is `telemetry` (hex, via `[native.dependencies]`).

## Non-goals (for 1.0)

- Elixir-only niceties: `ProcessLabel` beyond a one-liner, Logger attach helpers
  with Elixir log levels (do a minimal `Catalina Logger` later).
- Protocol parsing of any kind; that is Buccaneer's job.

## Decision: everything in Beamtalk (2026-10-19)

Beamtalk's stdlib supervisors cannot express Thousand Island's tree today, so
the port is written against stdlib work tracked in **Linear epic BT-3957**.
Phase 1 can start now; Phase 2 is blocked until the supervisor issues land.

| Thousand Island needs | Beamtalk stdlib today | Issue |
|---|---|---|
| Several server instances per node, N connection supervisors per server | `Supervisor`/`DynamicSupervisor` register one instance per class | BT-3962 |
| Children, child class and args decided from `start:` options | `class children` / `class childClass` are static | BT-3963 (blocked by 3962) |
| `max_children` on the connection supervisor | not supported | BT-3964 |
| per-child `shutdown:` timeout (`shutdownTimeout` for handlers) | not supported | BT-3965 |
| `which_children`, terminate/restart by id (`suspend`, `resume`, `connectionPids`) | lookup by class only | BT-3966 |
| handler stops with a structured reason (`{shutdown, {handshake, R}}`) | `stop` / `kill` only | BT-3967 |
| `handleInfo:` / cast errors crash the actor (let-it-crash) | logged and swallowed | ADR 0134 (accepted), BT-3953 → BT-3958..3961 |
| raw error term on FFI-wrapped exceptions (`closed` vs `econnreset`) | only `message` string | BT-3954 |
| `handle_continue` (run before queued messages) | self-sends are direct calls; a self-message queues behind the mailbox | BT-3968 (nice to have) |
| tuple literal expressions for inet proplists | `Tuple withAll:` | BT-3969 (ergonomics) |

The earlier alternative (supervisors in `native/*.erl` with a `native:` facade)
is dropped: it would have worked, but the point of the port is to make the
stdlib carry an OTP-shaped library.

Two Beamtalk facts that shape the code (from `docs/ADR/0043`, `0065`):

- **`self foo!` is a direct call, not a cast.** A loop that must yield between
  iterations (the acceptor) is driven by a self-*message*:
  `Erlang erlang send: self pid msg: #accept` handled in `handleInfo:`, which
  re-sends after each `accept`. Blocking inside `handleInfo:` is fine for the
  acceptor: it owns no other traffic, and the supervisor's exit signal kills
  it while blocked, exactly as Elixir's `Task` is killed.
- **No `receive` in Beamtalk.** Thousand Island cancels its read timer *and*
  flushes a stale `:read_timeout` from the mailbox. Instead, every timer
  message carries a unique ref (`erlang:make_ref`) stored in state; a
  `read_timeout` whose ref is stale is ignored. No flush needed.

## Module map

Thousand Island → Catalina. One class per file, snake_case file names.

| Thousand Island (`lib/`) | LOC | Catalina | Where |
|---|---|---|---|
| `thousand_island.ex` | 376 | `src/catalina.bt` — facade: `start:`, `stop`, `listenerInfo`, `connectionPids`, `suspend`, `resume`, `status`, `info` | Beamtalk (class-side over `ServerSupervisor`) |
| `server.ex` | 80 | `src/server_supervisor.bt` (`restForOne`) | Beamtalk (needs BT-3962/3963) |
| `shutdown_listener.ex` | 44 | `src/shutdown_listener.bt` | Beamtalk (`Actor` with `terminate:`) |
| `acceptor_pool_supervisor.ex` | 50 | `src/acceptor_pool_supervisor.bt` (`oneForOne`, N parameterised children) | Beamtalk (needs BT-3962/3963) |
| `acceptor_supervisor.ex` | 59 | `src/acceptor_supervisor.bt` (`restForOne`) + `src/connection_supervisor.bt` (`DynamicSupervisor`, `maxChildren`) | Beamtalk (needs BT-3962/3963/3964/3965) |
| `acceptor.ex` | 172 | `src/acceptor.bt` — Server; accept loop via self-message in `handleInfo:` | Beamtalk |
| `listener.ex` | 123 | `src/listener.bt` — Actor owning the listen sockets | Beamtalk |
| `connection.ex` | 106 | `src/connection.bt` — start child, retry on `max_children`, `controlling_process`, send ready message | Beamtalk |
| `handler.ex` | 709 | `src/handler.bt` — abstract `Server` subclass; `src/handler_result.bt` | Beamtalk |
| `handler_config.ex` | 39 | `src/handler_config.bt` | Beamtalk |
| `server_config.ex` | 79 | `src/server_config.bt` | Beamtalk |
| `socket.ex` | 273 | `src/socket.bt` | Beamtalk |
| `transport.ex` | 271 | `src/transport.bt` (Protocol) + `src/transport_options.bt` (`resolveOptions:`) | Beamtalk |
| `transports/tcp.ex` | 158 | `src/transports/tcp_transport.bt` | Beamtalk (FFI to `gen_tcp`/`inet`) |
| `transports/ssl.ex` | 211 | `src/transports/ssl_transport.bt` | Beamtalk (FFI to `ssl`) |
| `telemetry.ex` | 509 | `src/telemetry.bt` — spans + events | Beamtalk (FFI to `telemetry`) |
| `logger.ex` | 151 | `src/logger.bt` (minimal) | Beamtalk, Phase 6 |
| `process_label.ex` | 52 | one call to `proc_lib:set_label/1` in Handler | Beamtalk |

Formerly planned native helpers, now Beamtalk:

- option map → inet proplist: a small `TransportOptions` class using
  `Tuple withAll:` until BT-3969 lands.
- stop with structured reason: `self stopWith:` (BT-3967).
- stale `read_timeout` flush: unnecessary with the ref-tagged timer idiom above.
- SSL `sendfile`: the `file:pread` / `ssl:send` 1 MiB loop is a plain
  `whileTrue:` over FFI calls in `SSLTransport`.

## Public API sketch

```beamtalk
// Starting a server
srv := Catalina start: #{
  #port => 4000,
  #handler => EchoHandler,
  #handlerOptions => nil,
  #numAcceptors => 10 }
srv listenerInfo   // => Result ok: {ip, port}
srv stop           // Supervisor.stop(pid, :normal, 15_000)

// A handler. GenServer state is always {socket, userState}, as in Thousand Island.
Catalina Handler subclass: EchoHandler
  handleData: data socket: sock state: st =>
    sock send: data
    HandlerResult continue: st

  handleClose: sock state: st => nil
```

Handler callbacks (all optional, all defaulted):

| Thousand Island | Catalina |
|---|---|
| `handle_connection(socket, state)` | `handleConnection: sock state: st` |
| `handle_data(data, socket, state)` | `handleData: data socket: sock state: st` |
| `handle_close(socket, state)` | `handleClose: sock state: st` |
| `handle_error(reason, socket, state)` | `handleError: reason socket: sock state: st` |
| `handle_shutdown(socket, state)` | `handleShutdown: sock state: st` |
| `handle_timeout(socket, state)` | `handleTimeout: sock state: st` |

`HandlerResult` constructors map one-to-one onto the continuation tuples
Bandit depends on:

| Thousand Island | Catalina |
|---|---|
| `{:continue, st}` | `HandlerResult continue: st` |
| `{:continue, st, timeout}` | `HandlerResult continue: st timeout: ms` |
| `{:continue, st, {:persistent, t}}` | `HandlerResult continue: st persistentTimeout: ms` |
| `{:continue, st, {:continue, c}}` | `HandlerResult continue: st then: #selector` (self-cast; Beamtalk has no `handle_continue`) |
| `{:switch_transport, {mod, opts}, st}` | `HandlerResult switchTransport: SSLTransport options: opts state: st` |
| `{:close, st}` | `HandlerResult close: st` |
| `{:error, reason, st}` | `HandlerResult error: reason state: st` |

`Socket` (the value handed to callbacks): `send:`, `recv:`, `recv:timeout:`,
`sendfile:offset:length:`, `setopts:`, `getopts:`, `shutdown:`, `close`,
`peername`, `sockname`, `peercert`, `isSecure`, `getstat`,
`negotiatedProtocol`, `connectionInformation`, `telemetrySpan`, `readTimeout`.
The last two are read directly by Bandit, so they must be plain accessors.

Expected failures return `Result` (ADR 0060); misuse raises. Note ADR 0076
coercion: `gen_tcp:send` returning `ok` arrives as `Result ok: nil`, and
`{error, closed}` arrives as a `Result error:` wrapping an Exception, so
`handleError:` receives an Exception (kind `#runtime_error`, message
`"closed"`) rather than the raw atom. Document this difference.

## Phases

Each phase ends green on `just ci` and with a commit. Tests mirror Thousand
Island's `test/` file-by-file; the Elixir suite is the spec.

### Phase 0: Spikes (half a day)

Throwaway `.bt` files proving the shaky assumptions before building on them:

1. A `Server` subclass can own a `gen_tcp` socket set `{active, once}`,
   receive `{tcp, S, Data}` in `handleInfo:`, and re-arm. (Expected: yes.)
2. `controlling_process` from an acceptor Actor to a handler Actor's `pid`
   works and the ready message arrives before the first `{tcp, ...}`.
3. A `Server` can run a blocking accept loop driven by a self-message
   (`handleInfo: #accept` → `accept` → re-send `#accept`) and still be shut
   down by its supervisor when the listen socket closes (accept returns
   `{error, closed}`), and when killed mid-accept.
4. A ref-tagged `read_timeout` timer: stale refs are ignored, newer deadline
   re-arms, `#infinity` cancels — no mailbox flush needed.
5. `(Erlang telemetry) execute:with:with:` works with the hex dep declared.
6. Rough cost of the `handleInfo:` round trip per packet (`docs/performance.md`
   says ~1-3 µs per send; measure an echo of 10k small packets).

Outcome: confirm or amend the module map. If (3) fails, that is a new
stdlib issue under BT-3957 (a `Task`-like transient worker), not a reason to
drop back to Erlang.

### Phase 1: Config, TCP transport, Socket (`config_test`, `socket_test` TCP half, `transport_options_test`)

- `ServerConfig`: typed Object with the 16 options and their defaults; `new:`
  validates `handler` present, `numListenSockets <= numAcceptors`, `reuseport`
  present when `numListenSockets > 1`.
- `Transport` Protocol with the 18 callbacks (`listen:options:`, `accept:`,
  `handshake:`, `upgrade:options:`, `controllingProcess:pid:`, `recv:length:timeout:`,
  `send:data:`, `sendfile:...`, `getopts:`, `setopts:`, `shutdown:how:`, `close:`,
  `sockname:`, `peername:`, `peercert:`, `isSecure`, `getstat:`,
  `negotiatedProtocol:`, `connectionInformation:`).
- `TransportOptions resolveOptions:`: required (`binary`, `active false`) >
  user > defaults (`backlog 1024`, `send_timeout 30000`,
  `send_timeout_close true`, `reuseaddr true`, `nodelay true` unless
  `{local, _}`), deduplicated by key, in that precedence order.
- `TCPTransport`: class-side FFI to `gen_tcp` and `inet`; `inet_backend` sorted
  first in `listen`; `sendfile` via `file:open` + `file:sendfile/5`; stubs for
  secure-only calls (`Result error: #not_secure`).
- `Socket`: fields `socket`, `transport`, `readTimeout`, `handshakeTimeout`,
  `peername`, `silentTerminateOnError`, `span`, `readTimer`, `readDeadline`,
  `timerDeadline`. Telemetry calls stubbed until Phase 5.
- Tests spin up a raw `gen_tcp` listener on port 0 (like
  `beamtalk-http/test/httpserver_test.bt`) and exercise Socket against it.

### Phase 2: Supervision tree, Listener, Acceptor, Connection (`listener_test`, `acceptor_test`, `connection_test`, `socket_reuse_test`)

**Blocked by BT-3962, BT-3963, BT-3964, BT-3965** (multi-instance and
start-time-configured supervisors, `maxChildren`, per-child shutdown).

- `ServerSupervisor` (`restForOne`: listener, acceptor pool, shutdown
  listener), `AcceptorPoolSupervisor` (`oneForOne`, `1..numAcceptors`
  parameterised children with ids `acceptor-N`), `AcceptorSupervisor`
  (`restForOne`: `ConnectionSupervisor` with `maxChildren`, then acceptor).
  All take the `ServerConfig` as start args.
- `Listener`: opens `numListenSockets` sockets (sockets after the first bind to
  the actual port of the first, handling port 0); answers `listenerInfo` and
  `acceptorInfo: id` (round-robin socket `rem(id-1, n)+1`); closes sockets on
  partial failure; `restart: #transient`.
- `Acceptor`: looks up listener and sibling connection sup, loops
  `transport accept:` → `Connection start:`. Error classification exactly as
  `acceptor.ex`: `too_many_connections`/`spawn_error`/`controlling_process` →
  event + loop; `econnaborted`/`einval` → event + loop; the transient list
  (`enetdown`, `ehostunreach`, `etimedout`, ...) → `accept_error` + loop;
  `emfile`/`enfile` → event + 100 ms sleep + loop; `closed` → exit normal;
  anything else → raise.
- `Connection start:`: `startChild` with the handler's child spec
  (`shutdown: shutdownTimeout`, `restart: #temporary`); on `max_children`
  retry `maxConnectionsRetryCount` times with `maxConnectionsRetryWait`; then
  `controlling_process`; then send
  `{catalina_ready, RawSocket, HandlerConfig, AcceptorSpan, StartTime}`. On
  `controlling_process` failure close the socket and `terminateChild`.
- `ShutdownListener`: traps exits (by overriding `terminate:`), and on
  shutdown calls `Listener stop` so acceptors drain.
- `Catalina start:` facade (class-side; returns the `ServerSupervisor`
  instance).
- Tests use the `FlakyTransport` / `OwnershipErrorTransport` fakes from the
  Elixir suite, written as Beamtalk classes implementing `Transport`.

### Phase 3: Handler (`handler_test`, 44 tests, the bulk of the work)

- `Handler`: abstract `Server` subclass. `initialize` traps exits, state is
  `{socket, userState}`.
- `handleInfo:` clauses: `{catalina_ready, ...}` (peername → label → span →
  `Socket new` → handshake → `:ready` event → `handleConnection:`), `{tcp|ssl,
  S, Data}`, `{tcp_closed|ssl_closed, S}`, `{tcp_error|ssl_error, S, R}`,
  `read_timeout`, then user `handleInfo:` via a `handleUserInfo:` hook.
- Every user callback runs through `invokeCallback:` which catches, emits
  `:exception`, and re-raises. With ADR 0134 (BT-3958) the re-raise crashes
  the handler the way it does in Elixir; until it lands, re-raise via
  `self stopWith: error` (BT-3967).
- Continuation handling as in `handle_continuation/2` including the
  `switch_transport` path (note the Elixir quirk that passes an integer
  timeout as a GenServer timeout; decide whether to reproduce or fix, and
  document).
- Lazy read timer: `readDeadline`, `send_after` only when no timer is running
  or the new deadline is earlier; on fire re-arm for the remainder or time out;
  timer messages are ref-tagged so a stale one is ignored instead of flushed;
  `#infinity` cancels. Stops use `self stopWith:` (BT-3967) with the same
  reasons as `handler.ex`.
- `terminate:` routing exactly as in `handler.ex`: `premature_conn_closing` →
  no-op; `read_timeout` → `handleTimeout:`; `shutdown` → `handleShutdown:`;
  `{shutdown, {handshake|silent_termination|upgrade, R}}` → `handleError:`;
  other `{shutdown, R}` → `handleClose:`; anything else → `handleError:`.
  Then `doSocketClose` (getstat counters → span stop → close).
- Buccaneer needs `handleCall:`/`handleCast:`/`handleInfo:` forwarding from a
  delegating handler, so make sure user `Server` sync/async methods coexist
  with Catalina's own clauses.

### Phase 4: SSL (`socket_test` SSL half, SSL cases in `server_test`)

- `SSLTransport`: `listen` validates a key option and a cert option, calls
  `ssl:listen`; `accept` = `ssl:transport_accept`; `handshake:timeout:` =
  `ssl:handshake/2` normalising `{ok, S, _Ext}`; `upgrade` =
  `ssl:handshake(Sock, Opts)`; `sendfile` as a `file:pread` / `ssl:send`
  loop in Beamtalk.
- Handshake runs in the handler process bounded by `handshakeTimeout`;
  failure stops with `{shutdown, {handshake, R}}`.
- Fixtures: copy `test/support/{ca,cert,key}.pem` and `sendfile` into
  `test/fixtures/`.

### Phase 5: Telemetry (`telemetry_test`, telemetry assertions across suites)

- Spans `listener`, `acceptor`, `connection` with `monotonic_time`,
  `system_time`, `telemetry_span_context`, `parent_telemetry_span_context`,
  `duration`, `handler` metadata.
- Event names under `[catalina, ...]` with the same suffixes as Thousand Island
  (`start`, `stop`, `exception`, `ready`, `async_recv`, `recv`, `recv_error`,
  `send`, `send_error`, `sendfile`, `sendfile_error`, `socket_shutdown`,
  `spawn_error`, `econnaborted`, `accept_error`, `emfile`).
- `stop` on connection carries `send_oct`/`send_cnt`/`recv_oct`/`recv_cnt`;
  `exception` carries `kind`/`reason`/`stacktrace`; process-dictionary marker to
  avoid a second `stop` after `exception`.
- A test helper equivalent to `support/telemetry_helpers.ex` that forwards
  events for a given handler to the test process: `telemetry:attach` with a
  Beamtalk block as the handler fun (blocks are plain funs across the FFI).

### Phase 6: Server operations and polish (`server_test`, 23 tests)

- `suspend` (terminate each `acceptor` child, then `shutdown_listener`, then
  `listener`), `resume` (reverse), `status` (`#suspended` when no listener),
  `info`, `connectionPids`, `stop:` with wait. Needs BT-3966 (child control
  by id).
- Draining: `shutdownTimeout` per handler child; `handleShutdown:` on
  `shutdown`; brutal kill on overrun.
- `numListenSockets` > 1 with `reuseport`/`reuseport_lb`; Unix domain sockets
  (`{local, path}`, nodelay suppressed).
- Minimal `Logger` (attach a telemetry handler at `#error`/`#info`/`#debug`/`#trace`).
- README (Installation / Usage / Classes / Development, as in beamtalk-http),
  AGENTS.md updated with the Thousand Island cross-reference, `///` docs with examples on every public class.

### Phase 7: Buccaneer alignment

Confirm the surface Bandit reads is present and stable before Buccaneer starts:
`HandlerResult` constructors (`continue:`, `continue:persistentTimeout:`,
`close:`, `error:state:`), the `{socket, userState}` state shape, `Socket
readTimeout` and `Socket telemetrySpan telemetrySpanContext`, option names
matching `ServerConfig`, `Catalina listenerInfo`, and `handleCall:`/`handleCast:`
forwarding from a delegating handler. Tag `v0.1.0`.

## Size and effort

Thousand Island is ~3,500 lines of library and ~3,000 lines of tests. Expect
the Beamtalk port to come in a little larger because of FFI plumbing. Rough
split for the port itself: Phase 0-1 one day, Phase 2 two days, Phase 3 three
days, Phase 4-5 two days, Phase 6-7 one to two days — plus the stdlib work in
BT-3957, which gates Phase 2 onwards.

## Beamtalk work this port depends on

All tracked under **epic BT-3957**; see the table in the Decision section.
The two outside the stdlib: BT-3955 (`beamtalk new` CI template pinned OTP 27
while nightlies need 28; fixed in PR jamesc/beamtalk#4428) and its follow-up,
that `otp-support.toml` still claims OTP 27 is supported.

## References

- Thousand Island source map and Bandit's dependency surface: research notes
  from 2026-10-19 (summarised in the module map above).
- Beamtalk ADRs: 0043 (deadlocks), 0056 (native actors), 0060/0101 (errors),
  0065 (Server/handleInfo), 0068/0127 (protocols/traits), 0072 (native dir),
  0075 (stubs), 0076 (FFI coercion).
- `docs/beamtalk-native-erlang.md`, `docs/performance.md`,
  `docs/known-limitations.md`.
