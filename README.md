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

TLS: pass `#transport => SSLTransport` and `#transportOptions =>
#({#certfile, "cert.pem"}, {#keyfile, "key.pem"})`.

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
```

`PLAN.md` is the porting plan and records each phase's deviations from
Thousand Island; `AGENTS.md` is the guide for coding agents. Every class is
`typed` and the build fails on type warnings.

## License

Apache-2.0. Thousand Island is MIT-licensed; its design and tests are the
basis of this port.
