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
The supervisor design those issues implement is **ADR 0135** (Supervisor
Instances and Start Arguments, accepted 2026-10-20); Phase 2 below is written
against it.

| Thousand Island needs | Beamtalk stdlib today | Issue |
|---|---|---|
| Children, child class and limits computed from `init(arg)`, and `self()` passed to children | class-side `class children` / `class childClass` / ..., with no args and no handle | BT-3963 (ADR 0135 §2: instance-side `childSpecs`, `strategy`, `childClass`, `maxChildren`, `childShutdown`, reading `self args`; lands first) |
| Several server instances per node, N acceptor and connection supervisors per server | `Supervisor`/`DynamicSupervisor` register one instance per class | BT-3962 (ADR 0135 §1, §3: `spawnWith:`, `spawnWith:as:`, `named:`, `supervisionSpec withArgs:` on supervisor classes, integer child ids; after BT-3963) |
| `max_children` on the connection supervisor | not supported | BT-3964 (per server via instance-side `maxChildren`, BT-3963) |
| `shutdown:` timeout for handler children (`shutdownTimeout`) | not supported | BT-3965 (per server via instance-side `childShutdown`, BT-3963; BT-3972 cancelled) |
| `which_children`, terminate/restart by id (`suspend`, `resume`, `connectionPids`) | lookup by class only | BT-3966 (`whichChildren`, `childWithId:`, `terminateChild:`/`restartChild:` by id, `DynamicSupervisor children`) |
| handler stops with a structured reason (`{shutdown, {handshake, R}}`) | `stop` / `kill` only | BT-3967 |
| `handleInfo:` / cast errors crash the actor (let-it-crash) | logged and swallowed | ADR 0134 (accepted), BT-3953 → BT-3958..3961 |
| raw error term on FFI-wrapped exceptions (`closed` vs `econnreset`) | only `message` string | BT-3954 |
| `handle_continue` (run before queued messages) | self-sends are direct calls; a self-message queues behind the mailbox | BT-3968 (`self continueWith:`; needed for the acceptor's first parent call, see Phase 2) |
| tuple literal expressions for inet proplists | `Tuple withAll:` | BT-3969 (ergonomics) |

The earlier alternative (supervisors in `native/*.erl` with a `native:` facade)
is dropped: it would have worked, but the point of the port is to make the
stdlib carry an OTP-shaped library.

Two Beamtalk facts that shape the code (from `docs/ADR/0043`, `0065`):

- **A loop that must yield between iterations (the acceptor) is driven by a
  self-*message*:** `Erlang erlang send: self pid msg: #accept` handled in
  `handleInfo:`, which re-sends after each `accept`. (`self foo!` is now a real
  cast to the actor's own mailbox too, so it would do the same; the spikes use
  the self-message.) Blocking inside `handleInfo:` is fine for the acceptor:
  it owns no other traffic, and the supervisor's exit signal kills it while
  blocked, exactly as Elixir's `Task` is killed. **This holds only if the
  acceptor does not override `terminate:`** (Phase 0 spike 3). Overriding it
  makes the actor trap exits; the supervisor's `shutdown` then queues behind
  the blocked `accept`, the supervisor waits the whole shutdown timeout, kills
  it, and `terminate:` never runs. A blocked acceptor also cannot answer sync
  calls, so nothing may call it.
- **Class-side socket code must run in the caller** (found in Phase 1). A
  class method of an open class, or one not declared `class sealed`, runs in
  the class's own process (ADR 0129), not the caller's. For a transport that
  breaks `controlling_process` and `file:sendfile` (`not_owner`: the caller
  owns the socket) and would serialise every blocking `accept`/`recv` behind
  one process. So `TCPTransport`, `SSLTransport`, `TransportOptions`, the
  test transports and any class-side helper that touches a socket or
  `self()` are `sealed Object subclass:` with `class sealed` methods. No
  diagnostic catches a transport that forgets (BT-4031).
- **Transport errors are bare reasons** (decided in Phase 2). Every
  `Result`-returning method of the `Transport` protocol, its
  implementations and `Socket`'s wrappers answers the raw Erlang reason on
  the error side (`#closed`, `#timeout`, `#econnreset`; a Tuple for some
  SSL alerts), as Thousand Island's `{:error, reason}` does. An FFI
  `{error, R}` arrives as an Exception (ADR 0076), so each implementation
  normalises it once at the boundary with `mapError: [:e | e reason]`
  (`TCPTransport bare:`); stubs answer `Result error: #not_secure`.
  Callers compare `r error` directly, never `r error reason`.
- **No `receive` in Beamtalk.** Thousand Island cancels its read timer *and*
  flushes a stale `:read_timeout` from the mailbox. Instead, every timer
  message carries a unique ref (`erlang:make_ref`) stored in state; a
  `read_timeout` whose ref is stale is ignored. No flush needed.

## Module map

Thousand Island → Catalina. One class per file, snake_case file names.

| Thousand Island (`lib/`) | LOC | Catalina | Where |
|---|---|---|---|
| `thousand_island.ex` | 376 | `src/catalina.bt` — facade: `start:`, `stop`, `listenerInfo`, `connectionPids`, `suspend`, `resume`, `status`, `info` | Beamtalk (class-side over `ServerSupervisor spawnWith:`) |
| `server.ex` | 80 | `src/server_supervisor.bt` (Phase 2) (`restForOne`; `childSpecs` from `self args`, passes `#server => self`) | Beamtalk (needs BT-3963, BT-3962) |
| `shutdown_listener.ex` | 44 | `src/shutdown_listener.bt` (Phase 2) | Beamtalk (`Actor` with `terminate:`) |
| `acceptor_pool_supervisor.ex` | 50 | `src/acceptor_pool_supervisor.bt` (Phase 2) (`oneForOne`, `numAcceptors` children with integer ids `1..n`) | Beamtalk (needs BT-3963, BT-3962) |
| `acceptor_supervisor.ex` | 59 | `src/acceptor_supervisor.bt` (`restForOne`, passes `#parent => self`) + `src/connection_supervisor.bt` (`DynamicSupervisor`; `childClass`, `maxChildren`, `childShutdown` from `self args`) | Beamtalk (needs BT-3963, BT-3962, BT-3964, BT-3965) |
| `acceptor.ex` | 172 | `src/acceptor.bt` (Phase 2) — Server; parent lookups in a `continueWith:` step, then accept loop via self-message in `handleInfo:` | Beamtalk (needs BT-3966, BT-3968) |
| `listener.ex` | 123 | `src/listener.bt` (Phase 2) — Actor owning the listen sockets | Beamtalk |
| `connection.ex` | 106 | `src/connection.bt` (Phase 2) — start child, retry on `max_children`, `controlling_process`, send ready message | Beamtalk |
| `handler.ex` | 709 | `src/handler.bt` — `Server` subclass; `src/handler_result.bt` (Phase 3) | Beamtalk |
| `handler_config.ex` | 39 | `src/handler_config.bt` (Phase 1) | Beamtalk |
| `server_config.ex` | 79 | `src/server_config.bt` (Phase 1) | Beamtalk |
| `socket.ex` | 273 | `src/socket.bt` (Phase 1) | Beamtalk |
| `transport.ex` | 271 | `src/transport.bt` (Protocol) + `src/transport_options.bt` (`resolveOptions:`) (Phase 1) | Beamtalk |
| `transports/tcp.ex` | 158 | `src/transports/tcptransport.bt` (Phase 1; the file name must match `TCPTransport`) | Beamtalk (FFI to `gen_tcp`/`inet`) |
| `transports/ssl.ex` | 211 | `src/transports/ssltransport.bt` (Phase 4) | Beamtalk (FFI to `ssl`) |
| `telemetry.ex` | 509 | `src/catalina_telemetry.bt` — spans + events (not `Telemetry`, which is the stdlib facade's name, BT-4025) | Beamtalk (stdlib `Telemetry`, BT-4025) |
| `logger.ex` | 151 | `src/logger.bt` (minimal) | Beamtalk, Phase 6 |
| `process_label.ex` | 52 | one call to `proc_lib:set_label/1` in Handler | Beamtalk |

Formerly planned native helpers, now Beamtalk:

- option map → inet proplist: a small `TransportOptions` class using tuple
  literals (`{#active, false}`, BT-3969, landed).
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
| `{:continue, st, {:continue, c}}` | `HandlerResult continue: st then: #selector` (a thin wrapper over `self continueWith:`, BT-3968) |
| `{:switch_transport, {mod, opts}, st}` | `HandlerResult switchTransport: SSLTransport options: opts state: st` |
| `{:close, st}` | `HandlerResult close: st` |
| `{:error, reason, st}` | `HandlerResult error: reason state: st` |

`Socket` (the value handed to callbacks): `send:`, `recv:`, `recv:timeout:`,
`sendfile:offset:length:`, `setopts:`, `getopts:`, `shutdown:`, `close`,
`peername`, `sockname`, `peercert`, `isSecure`, `getstat`,
`negotiatedProtocol`, `connectionInformation`, `telemetrySpan`, `readTimeout`.
The last two are read directly by Bandit, so they must be plain accessors.

Expected failures return `Result` (ADR 0060); misuse raises. `gen_tcp:send`
returning `ok` arrives as `Result ok: nil` (ADR 0076). On the error side,
transports answer the bare Erlang reason (`#closed`), as Thousand Island
does, so `handleError:` receives the raw reason too: see "Transport errors
are bare reasons" above. Raw FFI calls outside a transport still answer an
Exception (`r error reason`, BT-3954), which the checker mistypes as the
raw Symbol (BT-4023).

## Typing rule (BT-4038)

Every catalina class is `typed`, and so are the test fixtures. New code
must build with zero type warnings: `beamtalk.toml`'s `[diagnostics]`
makes `type`, `type-annotation` and `dnu` errors, and `just test` (which CI
runs) adds `--warnings-as-errors`. An `@expect` is allowed only where a
Beamtalk limitation forces it, with a comment and a Linear issue under
BT-3957.

Slots acquired exactly once by a lifecycle step and valid for that
resource's life are `late state: x :: T`: `Handler handlerOptions` and
`socket`, `Listener localInfo`, `Acceptor listenSocket`, `connections` and
`handlerConfig`, `ShutdownListener listener`. Reads that `unguarded-late-read`
flags (from `handleInfo:` or `terminate:`) sit inside a `(self hasField:
#x) ifTrue: [...]` guard. Slots that can become empty again or would be
wrong if stale stay `T | Nil = nil`: the handler's read-timer slots. Start
args are plain typed slots with no default (`state: config ::
ServerConfig`): they are supplied at spawn. User data where nil is a valid
value (`Handler userState`) is `Object`. Values cannot have `late` fields.

The workarounds in place:

- `Integer | #infinity` rather than the stdlib `Timeout` alias for fields
  with an Integer default (BT-4039).
- `(1 to: n) do:` into a List rather than `collect:`, whose block
  parameter is untyped over an Interval (BT-4040).
- `x :: T := ...` rather than `x :: T | Nil := ...` when narrowing a
  `childWithId:` result, which is rejected (BT-4042); the `isNil` check
  stays.
- `transport` fields are `Dynamic`: a class conforming to a protocol's
  class side has no type name. `HandlerResult transport` is `Object`
  because `Dynamic = nil` warns (BT-4032).

`Handler` being `typed` makes every handler subclass typed too, so a user's
handler (Buccaneer's included) must annotate its callbacks. A subclass
cannot narrow an inherited parameter type, so it narrows inside the method
(`text :: String := data`).

## Phases

Each phase ends green on `just ci` and with a commit. Tests mirror Thousand
Island's `test/` file-by-file; the Elixir suite is the spec.

### Phase 0: Spikes (half a day) — done (BT-4019)

All six hold, two with conditions that the later phases must keep. Results,
numbers and how to run them: [`spikes/README.md`](spikes/README.md).

- (2) holds only while the accepted socket is passive until the handler arms
  it after the ready message (`TransportOptions`' required `active false` is
  load-bearing).
- (3) holds only for an acceptor that does not override `terminate:` (see
  "Two Beamtalk facts" above). No `Task`-like worker is needed.
- (5) needs `telemetry` in `[native.dependencies]` (added), and every
  `(Erlang telemetry)` site warns until BT-4022 is fixed.
- (6) `handleInfo:` dispatch is ~0.4 µs; each inline FFI call is ~7-15 µs
  (BT-4021), so FFI calls, not `handleInfo:`, dominate per-packet cost.

The original list:

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

Outcome: the module map stands. (3) did not fail, so no `Task`-like worker
is needed. The rules the spikes added are folded into Phases 2, 3 and 5
below.

### Phase 1: Config, TCP transport, Socket (`config_test`, `socket_test` TCP half, `transport_options_test`) — done (BT-4026)

36 tests: `ServerConfigTest` 11 (the 7 of `config_test.exs` plus 4),
`TransportOptionsTest` 7, `SocketTest` 17, plus the scaffold's
`CatalinaTest`. Deviations from the plan below:

- `ServerConfig` is a `sealed typed Value` (an `Object` holds no fields) and
  its validating constructor is `fromOptions:`, because `Value new:` is
  sealed. It also rejects unknown options, as `struct!/2` does, because
  `new:` silently stores undeclared keys (BT-4030). Errors are plain `Error`
  with Thousand Island's messages, without the RuntimeError/ArgumentError
  split. Option names: `transport_module` → `transport`, `handler_module` →
  `handler`, `genserver_options` → `genServerOptions`, the rest camelCased.
- `HandlerConfig` lands here rather than in Phase 3: `Socket` is built from
  one, as `Socket.new/4` is.
- `Socket wrap: raw peername: p handlerConfig: hc span: s` is `Socket.new/4`.
  `peername` answers `Result ok:` with the address captured at accept time,
  overriding the field getter.
- The `Transport` protocol has the 18 required class methods.
  `handshake:timeout:` is optional, as in Elixir, and `Socket handshake`
  detects it with `respondsTo:`, so it is documented on the protocol rather
  than required by it.
- Transports are sealed with `class sealed` methods (see "Two Beamtalk facts"
  above). Two class-side constructors cannot be `class sealed` yet: `self
  new`/`new:` in a direct-called class method raises badarg (BT-4029), so
  `ServerConfig fromOptions:` stays an open class method and `Socket wrap:...`
  uses the keyword constructor.
- Transport errors were Exceptions for FFI failures and Symbols for stubs;
  Phase 2 made them all bare reasons (see "Transport errors are bare
  reasons" above).
- Tests: the server and `Handler` come in Phases 2-3, so `SocketTest` plays
  the handler itself (accepts on a raw listen socket and wraps the
  connection), and its telemetry cases move to Phase 5. The large-file
  `sendfile` case sends 32 MiB, not 256 MiB, from a fixture actor that owns
  the connection. `transport_options_test` cannot trace `gen_tcp:listen/2`
  without `receive`, so it checks `TCPTransport listenOptions:` (exactly
  what `listen:options:` passes) and listens for real.

The plan as written:

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

### Phase 2: Supervision tree, Listener, Acceptor, Connection (`listener_test`, `acceptor_test`, `connection_test`, `socket_reuse_test`) — done (BT-4027)

66 tests in all, 30 of them new: `ListenerTest` 10, `AcceptorTest` 5,
`ConnectionTest` 1, `SocketReuseTest` 5, `ServerTest` 9, plus one new
`SocketTest` case for bare transport errors. `ServerTest`
covers the tree's shape, two independent servers on one node (stopping
one leaves the other serving), named servers, start errors, and acceptors
ending normally when the listener stops. The tree, the hang rule and the
child lookups are as designed below. Deviations:

- **The listener starts through `withClassMethod: #startFor:`, not
  `withArgs:`.** A plain static actor child runs `initialize` after its
  start has returned, so a listener that cannot bind (`eaddrinuse`) would
  not fail the server's start. It would crash-loop until the server gave
  up, while `Catalina start:` had already answered `ok:`. A `withClassMethod:`
  factory runs in the supervisor and `spawnWith:` waits for `initialize`,
  which gives Thousand Island's `{:stop, reason}` from `init/1` (BT-4033).
- `Catalina start:` answers a `Result` (`ok:` the `ServerSupervisor`).
  `listenerInfo` and `connectionPids` are instance methods on
  `ServerSupervisor` (`srv listenerInfo`), and `connectionPids` answers the
  handler pids. `suspend`, `resume`, `status` and `info` stay in Phase 6.
- The handler is started with `startChild: #{#handlerOptions => opts}`, so
  a handler declares `state: handlerOptions`. Phase 3's `Handler` takes
  that over. `genServerOptions` is carried but unused (Beamtalk actors take
  no gen_server options). `ConnectionSupervisor` is `DynamicSupervisor(Server)`
  until `Handler` exists.
- `Listener acceptorInfo:` answers the socket alone. The listener span joins
  it in Phase 5, as do all telemetry events (the acceptor's `spawn_error`,
  `econnaborted`, `accept_error` and `emfile`). The Elixir tests' telemetry
  assertions move to Phase 5; the behaviour they accompany is tested here.
- Transport errors are now bare Erlang reasons everywhere (the new rule
  under "Two Beamtalk facts"), so the acceptor classifies `accept` errors
  by comparing `result error` directly, and Phase 1's tests compare errors
  rather than `error reason`.
- Tests use small stand-in handlers in `test/fixtures/` (`EchoHandler`,
  `WaitingHandler`, `FailInitHandler`) until `Handler` arrives. The
  `:ignore` case of the failing-handler test has no Beamtalk counterpart,
  so only the raising one is ported. The listener tests spawn a `Listener`
  rather than calling `init/1` and `handle_call/3` directly, and use a free
  port rather than a fixed 4004.
- `ServerConfig`/`HandlerConfig` `handler` is typed `Actor class | Nil`
  because `Dynamic = nil` warns (BT-4032).

The plan as written:

**Blocked by**, in order: **BT-3963** (instance-side supervisor
configuration reading `self args`), then **BT-3962** (`spawnWith:` /
`spawnWith:as:` on supervisor classes, `supervisionSpec withArgs:` for nested
supervisors, integer child ids), then **BT-3966** (`childWithId:`,
`whichChildren`, by-id `terminateChild:`/`restartChild:`,
`DynamicSupervisor children`). Plus **BT-3968** (`continueWith:`) for the
acceptor's first parent call, and BT-3964 / BT-3965 (`maxChildren`,
`childShutdown`), which BT-3963 makes per instance.

The design is ADR 0135's. Every supervisor is configured on the **instance
side**: `childSpecs`, `strategy`, `childClass`, `maxChildren`,
`childShutdown` are instance methods that the runtime calls inside the new
supervisor's own `init/1`, so `self args` is its start args (OTP's
`init(Arg)`) and `self` is its own handle (OTP's `self()` in `init/1`). No
class-side configuration, and no `supervise`: `supervise` is the idempotent
per-class singleton, and Catalina needs one tree per running server.

The tree, one per `Catalina start:`:

```
ServerSupervisor (restForOne)                  args: ServerConfig
├── #listener          Listener                               args: {config}
├── #acceptorPool      AcceptorPoolSupervisor (oneForOne)     args: {server, config}
│   └── i (1..numAcceptors)  AcceptorSupervisor (restForOne)  args: {id, server, config}
│       ├── #connections  ConnectionSupervisor (dynamic)      args: config
│       └── #acceptor     Acceptor                            args: {id, parent, server, config}
└── #shutdownListener  ShutdownListener                       args: {server}
```

**Server start.** `Catalina start:` builds a `ServerConfig` and calls
`ServerSupervisor spawnWith: config`: an anonymous, unlinked instance, so a
node (and a test suite) can run any number of servers. With a `#name` option
it calls `(ServerSupervisor spawnWith: config as: name) unwrap` instead, so
the server is visible by name to observer, remote shells and `sys:get_state`
(Thousand Island's `supervisor_options: [name: ...]`), and
`ServerSupervisor named: name` finds it. Names must come from a bounded set
(ADR 0079); never build one from runtime data. A taken name is
`Result error:` with kind `#name_registered`. `srv stop` stops one server and
leaves the others running.

The supervisors, starting from ADR 0135's Catalina example:

```beamtalk
Supervisor subclass: ServerSupervisor
  strategy => #restForOne
  childSpecs => #(
    (Listener supervisionSpec withId: #listener withRestart: #transient
       withArgs: #{#config => self args}),
    (AcceptorPoolSupervisor supervisionSpec withId: #acceptorPool
       withArgs: #{#server => self, #config => self args}),
    (ShutdownListener supervisionSpec withId: #shutdownListener withRestart: #permanent
       withArgs: #{#server => self}))

Supervisor subclass: AcceptorPoolSupervisor
  childSpecs =>
    ((1 to: (self args at: #config) numAcceptors) collect: [:i |
      AcceptorSupervisor supervisionSpec withId: i
        withArgs: #{#id => i, #server => (self args at: #server), #config => (self args at: #config)}]) asList

Supervisor subclass: AcceptorSupervisor
  strategy => #restForOne
  childSpecs => #(
    (ConnectionSupervisor supervisionSpec withId: #connections withArgs: (self args at: #config)),
    (Acceptor supervisionSpec withId: #acceptor withRestart: #transient
       withArgs: #{#id => (self args at: #id), #parent => self,
                   #server => (self args at: #server), #config => (self args at: #config)}))

DynamicSupervisor(Handler) subclass: ConnectionSupervisor
  childClass => self args handler
  maxChildren => self args numConnections
  childShutdown => self args shutdownTimeout
```

- **Acceptor pool.** `AcceptorSupervisor supervisionSpec withId: i
  withArgs: ...` with **integer** ids `1..numAcceptors` (Thousand Island uses
  `"acceptor-#{i}"`): integers do not touch the atom table and are what
  `whichChildren` reports (`#(1, 2, ...)`). Nested supervisors are anonymous,
  so 100 `AcceptorSupervisor`s under one pool, and several pools on one node,
  do not collide.
- **Per-server limits.** `ConnectionSupervisor` reads `childClass` (the
  user's handler), `maxChildren` (`numConnections`) and `childShutdown`
  (`shutdownTimeout`) from `self args`, so each server has its own limits.
  They are validated once in `init/1`; a bad value fails the server's start
  with `#supervisor_start_failed` and the validator's hint.
- **Restart policies** follow Thousand Island: `Listener` and `Acceptor` are
  `#transient` (an acceptor that sees `closed` exits normally and stays down;
  `restartChild:` can still bring it back in `resume`), nested supervisors
  default to `#permanent`. ADR 0135's example shows the acceptor as
  `#permanent`; `#transient` is the Thousand Island behaviour (`use Task,
  restart: :transient`).
- **Configuration methods never message `self`.** They run inside the
  supervisor's `init/1`: reading `self args` is fine, passing `self` as a
  value (`#parent => self`, `#server => self`) is the intended use, but
  `self count` or `self childWithId:` there fails the start at once
  (`calling_self` → `#supervisor_start_failed`).
- **Arg lifetime.** Args are replayed on every OTP restart, so they may hold
  only things that outlive the child: the `ServerConfig` and ancestor
  handles. Never a socket, a sibling's pid or a caller's pid.

**Parent handle and the hang rule.** `#parent => self` gives the acceptor its
`AcceptorSupervisor`, and `#server => self` (threaded down through the pool)
gives it the `ServerSupervisor`, replacing Thousand Island's
`{server_pid, self(), acceptor_id, config}`. The rule (ADR 0135): **never
synchronously call a supervisor from code that supervisor is waiting on.** A
supervisor waits on its own and its nested supervisors' configuration
methods, and on the `initialize` of `withName:` / `withClassMethod:` actor
children, during the initial start, every OTP restart and every
`startChild:`. So:

- No parent or server calls from any `childSpecs` / `childClass` / ...
  method, and the acceptor is not a `withName:` child.
- The acceptor makes its first parent call from a **`continueWith:` step**
  (BT-3968), not from `initialize` directly, **with an explicit timeout** on
  any actor call it makes there (`listener withTimeout: ...`), or tolerates a
  retry. A supervisor lookup made while the tree is still starting (100
  acceptor subtrees) waits until the ancestor has started its remaining
  children; under ADR 0134 a timeout raised there crashes the acceptor and,
  if restarted, loops.

```beamtalk
Server subclass: Acceptor
  state: id = nil
  state: parent = nil
  state: server = nil
  state: config = nil
  state: listenSocket = nil
  state: connections = nil

  initialize => self continueWith: #attach

  attach =>
    listener := (self.server childWithId: #listener) unwrap
    self.connections := (self.parent childWithId: #connections) unwrap
    self.listenSocket := (listener withTimeout: 15000) acceptorInfo: self.id
    Erlang erlang send: self pid msg: #accept

  handleInfo: msg =>
    msg match: [
      #accept -> self acceptOnce;   // accept, Connection start:, re-send #accept
      _ -> nil
    ]
```

**Child lookup (BT-3966).** By id, never by class (with 100 same-class
children, `which:` answers `#ambiguous_child`):

| Thousand Island | Catalina |
|---|---|
| `Server.listener_pid(server)` | `(server childWithId: #listener) unwrap` |
| `Server.acceptor_pool_supervisor_pid(server)` | `(server childWithId: #acceptorPool) unwrap` |
| `AcceptorSupervisor.connection_sup_pid(parent)` | `(parent childWithId: #connections) unwrap` |
| `AcceptorPoolSupervisor.acceptor_supervisor_pids(pool)` | `pool children` (running children, declaration order) |
| `DynamicSupervisor.which_children(conn_sup)` in `connection_pids/1` | `connSup children` (O(n) copy; bulk use only) |
| `Supervisor.terminate_child(sup, :acceptor)` / `restart_child` | `sup terminateChild: #acceptor` / `sup restartChild: #acceptor` |

`connectionPids` is `pool children flatMap: [:accSup | ((accSup
childWithId: #connections) unwrap) children]`, run at human timescales as in
Thousand Island.

**OTP mapping** (from ADR 0135, for reading `server.ex` /
`acceptor_*_supervisor.ex` side by side):

| Thousand Island / OTP | Catalina |
|---|---|
| `Supervisor.start_link(Server, config)` | `ServerSupervisor spawnWith: config` |
| `Supervisor.start_link(Server, config, name: n)` | `ServerSupervisor spawnWith: config as: #n` |
| `init(arg)` | the configuration methods, reading `self args` |
| `self()` in `init/1` | `self` in `childSpecs` |
| `Supervisor.child_spec({Mod, arg}, id: id)` | `Mod supervisionSpec withId: id withArgs: arg` |
| `Supervisor.init(children, strategy: :rest_for_one)` | `strategy => #restForOne`, `childSpecs => ...` |
| `{DynamicSupervisor, max_children: n}` + handler child spec `shutdown:` | `ConnectionSupervisor` with `childClass`, `maxChildren`, `childShutdown` |
| `which_children`, `terminate_child`, `restart_child` | `whichChildren` / `childWithId:`, `terminateChild:`, `restartChild:` |

The rest of the phase:

- `Listener`: opens `numListenSockets` sockets (sockets after the first bind to
  the actual port of the first, handling port 0); answers `listenerInfo` and
  `acceptorInfo: id` (round-robin socket `rem(id-1, n)+1`); closes sockets on
  partial failure; `#transient`.
- `Acceptor`: after `attach`, loops `transport accept:` → `Connection
  start:`. It must not override `terminate:` (spike 3), and no other process
  calls it synchronously; tests observe it through telemetry or the
  supervisor (`whichChildren`), not by calling it. Error classification exactly as `acceptor.ex`:
  `too_many_connections`/`spawn_error`/`controlling_process` → event + loop;
  `econnaborted`/`einval` → event + loop; the transient list (`enetdown`,
  `ehostunreach`, `etimedout`, ...) → `accept_error` + loop;
  `emfile`/`enfile` → event + 100 ms sleep + loop; `closed` → exit normal;
  anything else → raise.
- `Connection start:`: `connections startChild: ...` (the
  `ConnectionSupervisor`'s `childClass` is the handler, `#temporary`, and its
  `childShutdown` is the server's `shutdownTimeout`); on `#max_children` retry
  `maxConnectionsRetryCount` times with `maxConnectionsRetryWait`; then
  `controlling_process`; then send
  `{catalina_ready, RawSocket, HandlerConfig, AcceptorSpan, StartTime}`. On
  `controlling_process` failure close the socket and `terminateChild:`.
- `ShutdownListener`: traps exits (by overriding `terminate:`), and on
  shutdown stops the listener (`(server childWithId: #listener)`, looked up
  in a `continueWith:` step like the acceptor) so acceptors drain.
- `Catalina start:` facade (class-side; returns the `ServerSupervisor`
  instance from `spawnWith:`, or `spawnWith:as:` when a name is given).
- Tests start one server per test with `spawnWith:` (not `supervise`), so
  they need not be `serial`. They use the `FlakyTransport` /
  `OwnershipErrorTransport` fakes from the Elixir suite, written as Beamtalk
  classes implementing `Transport`.

### Phase 3: Handler (`handler_test`, 44 tests, the bulk of the work) — done (BT-4036)

`HandlerTest` has 36 tests: 34 of `handler_test.exs`'s 44 (some adapted, see
below) and 2 additions (`handleShutdown:` when the server stops; a
handler's own sync and cast methods beside its callbacks, which Buccaneer
needs). 102 tests in all. Not ported here:

- the 8 telemetry tests (10 cases, with the `:error`/`:throw`/`:exit`
  expansion): Phase 5;
- "it should allow upgrading the transport mid-connection" and "it should
  allow calling handle_continue when upgrading": they need `SSLTransport`,
  Phase 4.

Adapted:

- "complain loudly if a handle_info callback returns the wrong shaped
  state" has nothing to test: the socket and the user state are separate
  fields (`socket`, `userState`), not a tuple a callback could return
  wrongly. It checks instead that a handler keeps serving after a user
  message.
- "it should handle upgrade errors" upgrades TCP to TCP (Thousand Island
  upgrades SSL to TCP). It fails the same way, with `#unsupported_upgrade`.
- The two GenServer `:timeout` tests: Beamtalk has no idle timeout, so the
  handler sends itself bare `#timeout` and `#read_timeout`, which must not
  count as the read timer.
- Log assertions: fixtures (`RecordingHandler` subclasses) log events and
  the exit reason to Ets. "terminating ** (stop) :nope" versus silent
  becomes an exit reason of `#nope` versus `{shutdown, {silent_termination,
  nope}}`.
- Timing windows that bound "closes within" are wider than the Elixir
  suite's, and fixtures match `startsWith:`, because on a loaded machine
  two sends arrive as one packet.

Deviations:

- `handleInfo:` is `sealed` on `Handler`, and a subclass's own messages go
  to `handleUserInfo:`. A `{tcp, S, _}` for another socket goes there too.
  `handleContinuation: aResult` is the escape hatch (Thousand Island's
  `Handler.handle_continuation/2` called from `handle_info`).
- The read-timer state (`readTimer`, the ref tag, `readDeadline`,
  `timerDeadline`) lives in the handler, not in `Socket`. Those three
  `Socket` fields are gone; `Socket readTimeout` stays. The timer message
  is `{#catalina_read_timeout, ref}`.
- There is no `invokeCallback:` helper yet. A block handed to a helper
  method could not keep the field writes the callback makes (ADR 0133), so
  Phase 5 wraps the two callback calls in an inline `on:do:` that emits the
  `exception` event and re-raises.
- A raise in a callback crashes the handler (ADR 0134). `handleError:` then
  gets `{exception, stacktrace}`, as Elixir's `{error, stacktrace}`.
- `switchTransport:...timeout: ms` uses `ms` as the read timeout. Thousand
  Island passes it on as a GenServer timeout, which looks like a slip.
- `then: #selector` names a unary method of the handler, run through
  `continueWith:`. The handler's internal method is `continueReading:`
  because `continueWith:` is sealed on `Actor`.
- The process label is `{catalina_connection, {ip, port}}` (`proc_lib:set_label/1`).
- The Phase 2 stand-ins `EchoHandler` and `FailInitHandler` are now
  `Handler` subclasses, and `ConnectionSupervisor` is
  `DynamicSupervisor(Handler)`. `WaitingHandler` stays a raw `Server`,
  because `connection_test.exs`'s handler is a raw GenServer.

The plan as written:

- `Handler`: abstract `Server` subclass. `initialize` traps exits, state is
  `{socket, userState}`.
- `handleInfo:` is a `match:` whose arms each call a method
  (`{#tcp, _s, data} -> self onData: data;`); a `[ ... ]` arm body is a block
  value and does not run (BT-4024). It ends with `_ -> self handleUserInfo: msg`.
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
- Lazy read timer (proven by spike 4, `spikes/fixtures/read_timeout_server.bt`):
  `readDeadline`, `send_after` only when no timer is running
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

### Phase 4: SSL (`socket_test` SSL half, SSL cases in `server_test`) — done (BT-4045)

117 tests in all, 15 of them new.

`SecureSocketTest` (13) covers:
- the SSL half of `socket_test.exs`: send and receive, close, connection
  info with ALPN, `sendfile` (small and large), a stalled handshake closed
  after `handshakeTimeout`, and a handshake within it;
- the SSL cases of `server_test.exs`: a default option overridden, a
  required one not overridable, bare Erlang options (`inet6`), a missing
  certificate failing the start, and a client offering only unsupported
  ciphers (`handleError:` gets `{tls_alert, {insufficient_security, _}}`);
- a Catalina addition: a start without a key or certificate is an error.

`HandlerTest` gains the 2 SSL-upgrade tests deferred from Phase 3.

Not ported here, all to Phase 5:
- the telemetry assertions;
- `socket_test.exs`'s "exactly one connection stop event when the
  handshake fails", which is telemetry only;
- the start/ready event ordering in the two handshake-timeout tests.

`server_test.exs`'s pre-OTP-28.1 certificate case is not ported, because
CI runs OTP 28.5.

Deviations:

- **Test certificates are new.** Thousand Island's test CA expires in
  January 2027, so `test/fixtures/{ca,cert,key}.pem` is a fresh CA ("Catalina
  Test CA") and a server certificate for `localhost` and 127.0.0.1, both
  valid until 2126. The CA key is not kept. To regenerate them:

  ```sh
  openssl req -x509 -newkey rsa:2048 -nodes -keyout ca-key.pem -out ca.pem -days 36500 \
    -subj "/CN=Catalina Test CA" -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
  openssl req -newkey rsa:2048 -nodes -keyout key.pem -out cert.csr -subj "/CN=localhost"
  printf "subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" > ext.cnf
  openssl x509 -req -in cert.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out cert.pem -days 36500 -extfile ext.cnf
  ```
- `TransportResult bare:` (new, `src/transport_result.bt`) is the one place
  FFI errors become bare reasons, shared by both transports (it was
  `TCPTransport bare:`).
- `SSLTransport` starts the `ssl` application itself (`listen:options:`,
  `upgrade:options:`), where an Elixir release would list it in
  `extra_applications`. `ssl:handshake` can answer `{ok, Socket, Ext}`, a
  3-tuple the FFI boundary does not convert, so `SSLTransport handshaken:`
  normalises it.
- `Listener sockets` is now `late state: sockets :: List(Port | Tuple)`
  (a TCP listen socket is a Port, a TLS one an `sslsocket` record). The
  sockets are opened into a local list and assigned once; on failure they
  are closed inline, because a List of ports cannot be passed in a message,
  even to `self` (the sendability check).
- Test plumbing shared by `HandlerTest` and `SecureSocketTest` moved into
  `test/fixtures/handler_harness.bt`.
- `ReadOpt` logs the option it read rather than sending its `inspect`.
- The large-file TLS `sendfile` is 4 MiB (four chunks), not 256 MiB.

The plan as written:

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

- **Target the stdlib `Telemetry` facade (BT-4025)**, not `(Erlang
  telemetry)` FFI: `Telemetry execute: #(#catalina, #connection, #recv)
  measurements: #{...} metadata: #{...}` for events, `Telemetry attach:
  id to: event do: [:event :measurements :metadata | ...]` (and
  `attach:toAll:do:`, `detach:`) in the test helper. The facade calls a
  runtime module directly, so it avoids the per-call FFI cost (BT-4021) and
  the `unresolved_ffi` warnings (BT-4022).
- Catalina's span module is `CatalinaTelemetry` in
  `src/catalina_telemetry.bt`: a class named `Telemetry` would collide with
  the stdlib facade. Thousand Island's spans are its own struct (start event,
  `span_event`/`untimed_span_event`, stop with a duration), not
  `telemetry:span/3`, so they are built on `Telemetry execute:...`, not
  `Telemetry span:...`.
- **Interim, only if Phase 5 starts before BT-4025 lands:** the
  `(Erlang telemetry)` calls live in `src/catalina_telemetry.bt` only, each
  with `@expect unresolved_ffi`, behind the same methods, and the
  `[native.dependencies]` telemetry entry stays. When BT-4025 lands, swap
  the bodies for the facade and drop the dependency and the `@expect` lines;
  nothing outside that file changes.

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

- `suspend` (`terminateChild: #acceptor` on each of `pool children`, then
  `server terminateChild: #shutdownListener`, then `#listener`), `resume`
  (`restartChild:` in reverse; `#child_running` counts as success, as
  Thousand Island treats `:running`), `status` (`#suspended` when
  `server childWithId: #listener` answers `ok: nil`), `info`,
  `connectionPids`, `stop:` with wait. Needs BT-3966 (child control by id).
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
