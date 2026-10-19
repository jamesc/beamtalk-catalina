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
- Only dependency: `telemetry` (hex, via `[native.dependencies]`).

## Non-goals (for 1.0)

- Elixir-only niceties: `ProcessLabel` beyond a one-liner, Logger attach helpers
  with Elixir log levels (do a minimal `Catalina Logger` later).
- Protocol parsing of any kind; that is Buccaneer's job.

## The key design decision: how much lives in Erlang

Beamtalk's stdlib supervisors cannot express Thousand Island's tree as-is:

| Thousand Island needs | Beamtalk stdlib today |
|---|---|
| Several server instances per node, each with its own tree | `Supervisor` registers one instance per class (`beamtalk_supervisor.erl:123`) |
| N connection `DynamicSupervisor`s per server, one per acceptor | one instance per class, same reason |
| `max_children` on the connection supervisor | not supported |
| per-child `shutdown:` timeout (`shutdownTimeout` for handlers) | not supported |
| `which_children` for `connectionPids`, `suspend`, `resume` | not supported |
| handler stops with a structured reason (`{shutdown, {handshake, R}}`) | `Actor` has `stop` and `kill` only; no stop-with-reason |
| `handleInfo:` crash = process crash (let-it-crash, `:exception` telemetry) | `handleInfo:` errors are logged and swallowed |

Two ways through:

**A. Native Erlang for the supervision tree, Beamtalk for everything else.**
`native/catalina_server_sup.erl`, `catalina_acceptor_pool_sup.erl`,
`catalina_acceptor_sup.erl` are ~150 lines of declarative OTP. The
`Catalina` facade is a `native:` Actor (ADR 0056) so a user's Beamtalk
`Supervisor` can still supervise a server. Listener, Acceptor, Handler, Socket,
Transports, Config and Telemetry are all Beamtalk.

**B. Extend the stdlib first** (unnamed/multi-instance supervisors,
`maxChildren`, per-child shutdown, `whichChildren`, `stopWith: reason`), then
write the tree in Beamtalk.

**Recommendation: A, with the stdlib gaps filed as Beamtalk issues** (list at
the end). The supervisors are the least interesting code to port and the most
standard; writing them in Erlang unblocks the port immediately and keeps a
clear migration path: once the stdlib grows those features, each `.erl` file
becomes a `.bt` file with no API change. The handler stop-reason gap is handled
either way by a tiny native helper (`catalina_handler:stop/2` calling
`gen_server:stop` or `exit/2` with the structured reason) until `Actor` grows
`stopWith:`.

If you would rather dogfood the stdlib (option B), only Phase 2 changes; Phases
1, 3-6 are unaffected.

## Module map

Thousand Island → Catalina. One class per file, snake_case file names.

| Thousand Island (`lib/`) | LOC | Catalina | Where |
|---|---|---|---|
| `thousand_island.ex` | 376 | `src/catalina.bt` — facade: `start:`, `stop`, `listenerInfo`, `connectionPids`, `suspend`, `resume`, `status`, `info` | Beamtalk (`native:` Actor) |
| `server.ex` | 80 | `native/catalina_server_sup.erl` | Erlang |
| `shutdown_listener.ex` | 44 | `src/shutdown_listener.bt` | Beamtalk (`Actor` with `terminate:`) |
| `acceptor_pool_supervisor.ex` | 50 | `native/catalina_acceptor_pool_sup.erl` | Erlang |
| `acceptor_supervisor.ex` | 59 | `native/catalina_acceptor_sup.erl` (+ `simple_one_for_one` connection sup with `max_children`) | Erlang |
| `acceptor.ex` | 172 | `src/acceptor.bt` — Actor; accept loop via self-cast | Beamtalk |
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

Native helpers beyond the supervisors (small, all prefixed `catalina_`):

- `catalina_opts.erl`: option map → inet proplist. Beamtalk has no tuple
  literal expression, so `#(#binary, {active, false}, ...)` is awkward to build
  in `.bt`; do it once in Erlang.
- `catalina_handler.erl`: `stop/2` with structured reason; `flush/1` to drain a
  stale `read_timeout` message from the mailbox (needs `receive ... after 0`,
  which Beamtalk cannot express).
- `catalina_sendfile.erl`: the SSL `pread`/`send` 1 MiB chunk loop.

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
3. An Actor can run a blocking accept loop by self-casting
   (`acceptLoop!`) and still be shut down by its supervisor when the listen
   socket closes (accept returns `{error, closed}`).
4. `gen_server:stop(Pid, {shutdown, {handshake, R}}, Timeout)` from a native
   helper reaches `terminate: reason` with the compound reason intact.
5. `(Erlang telemetry) execute:with:with:` works with the hex dep declared.
6. Rough cost of the `handleInfo:` round trip per packet (`docs/performance.md`
   says ~1-3 µs per send; measure an echo of 10k small packets).

Outcome: confirm or amend the module map, and decide A vs B if the acceptor
loop (3) turns out not to be expressible in Beamtalk.

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

- Native: `catalina_server_sup` (`rest_for_one`: listener, acceptor pool,
  shutdown listener), `catalina_acceptor_pool_sup` (`one_for_one`,
  `1..numAcceptors`, ids `acceptor-N`), `catalina_acceptor_sup`
  (`rest_for_one`: connection sup with `max_children`, then acceptor).
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
- `Catalina start:` facade (`native:` Actor over `catalina_server_sup`).
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
  `:exception`, and re-raises; because the stdlib swallows `handleInfo:`
  errors, the re-raise becomes an explicit `catalina_handler:stop` with the
  error as reason so the process really dies (let-it-crash parity).
- Continuation handling as in `handle_continuation/2` including the
  `switch_transport` path (note the Elixir quirk that passes an integer
  timeout as a GenServer timeout; decide whether to reproduce or fix, and
  document).
- Lazy read timer: `readDeadline`, `send_after` only when no timer is running
  or the new deadline is earlier; on fire re-arm for the remainder or time out;
  cancel flushes a stale `read_timeout` message (`catalina_handler:flush/1`);
  `#infinity` cancels.
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
  `ssl:handshake(Sock, Opts)`; `sendfile` via `catalina_sendfile`.
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
  events for a given handler to the test process (likely `native/test` or a
  small `.erl` under `test/`).

### Phase 6: Server operations and polish (`server_test`, 23 tests)

- `suspend` (terminate each `acceptor` child, then `shutdown_listener`, then
  `listener`), `resume` (reverse), `status` (`#suspended` when no listener),
  `info`, `connectionPids`, `stop:` with wait.
- Draining: `shutdownTimeout` per handler child; `handleShutdown:` on
  `shutdown`; brutal kill on overrun.
- `numListenSockets` > 1 with `reuseport`/`reuseport_lb`; Unix domain sockets
  (`{local, path}`, nodelay suppressed).
- Minimal `Logger` (attach a telemetry handler at `#error`/`#info`/`#debug`/`#trace`).
- README (Installation / Usage / Classes / Development, as in beamtalk-http),
  AGENTS.md updated with the Erlang/Beamtalk split and the Thousand Island
  cross-reference, `///` docs with examples on every public class.

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
split: Phase 0-1 one day, Phase 2 two days, Phase 3 three days, Phase 4-5 two
days, Phase 6-7 one to two days.

## Beamtalk gaps surfaced by this port

Worth filing as issues against `beamtalk` whether or not option B is chosen:

1. **Multi-instance supervisors.** `Supervisor` and `DynamicSupervisor`
   register one instance per class; a library cannot create N of them.
2. **`DynamicSupervisor maxChildren`**, per-child **shutdown timeout** in
   `SupervisionSpec`, and **`whichChildren`** / child lookup by id.
3. **`Actor stopWith: reason`** (structured exit reason reaching `terminate:`).
4. **Opt-in let-it-crash for `handleInfo:`** (errors are currently logged and
   swallowed, so a buggy handler never restarts).
5. **`handle_continue` equivalent** (self-cast works but reorders behind
   already-queued messages).
6. **Tuple literal expression syntax** (`{active, once}`) for inet-style
   proplists; today it needs `Tuple withAll:`.
7. **Binary pattern matching** (BT-663): not needed here, blocking for
   Buccaneer's HTTP/1 parser.
8. **Nightly built on OTP 28 doesn't load on OTP 27** while docs and
   `otp-support.toml` claim 27 is supported (found earlier today via the
   `beamtalk new` CI template).

## References

- Thousand Island source map and Bandit's dependency surface: research notes
  from 2026-10-19 (summarised in the module map above).
- Beamtalk ADRs: 0043 (deadlocks), 0056 (native actors), 0060/0101 (errors),
  0065 (Server/handleInfo), 0068/0127 (protocols/traits), 0072 (native dir),
  0075 (stubs), 0076 (FFI coercion).
- `docs/beamtalk-native-erlang.md`, `docs/performance.md`,
  `docs/known-limitations.md`.
