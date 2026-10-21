# Phase 0 spikes

Throwaway checks of the assumptions in [PLAN.md](../PLAN.md) § Phase 0
(BT-4019). Each spike is a BUnit test, and the classes the tests drive are in
`fixtures/`. None of it is library code; Phases 1-3 rewrite all of it.

```bash
just spikes                       # all spikes, one test class at a time, then the bench numbers
beamtalk test spikes/accept_loop_spike_test.bt   # one spike
```

The spikes are kept out of `just test` because they use loopback sockets and
wall-clock timing. CI runs `just spikes` as a non-blocking step
(`continue-on-error`) and prints the spike 6 numbers into the log.

CI installs the beamtalk `edge` build, which tracks main per merge, so the
spikes run against the same stdlib (BT-3966's `terminateChild:`/
`whichChildren` by id included) as local builds from main.

Toolchain: beamtalk 0.4.0 built from main at BT-3958, OTP 28.

## Results

| # | Assumption | Result | Spike |
|---|---|---|---|
| 1 | A `Server` owns a `gen_tcp` socket in `{active, once}`, gets `{tcp, S, Data}` in `handleInfo:` and re-arms | **Holds.** One message per arm; the socket drops to `{active, false}` until `setopts` re-arms it. `{tcp_closed, S}` arrives the same way and `stopWith: {#shutdown, #peer_closed}` reaches `terminate:`. | `active_once_spike_test.bt` |
| 2 | `controlling_process` from an acceptor Actor to a handler's pid works, and the ready message arrives before the first `{tcp, ...}` | **Holds, with a condition:** the accepted socket must be passive (`{active, false}`) until the handler arms it after the ready message. With an `{active, once}` socket, data that arrived before the handoff is moved into the handler's mailbox ahead of the ready message (the test pins that order). | `handoff_spike_test.bt` |
| 3 | A `Server` blocking in `accept` inside `handleInfo: #accept` stops cleanly on supervisor shutdown, on `{error, closed}` and when killed mid-accept | **Holds, with a caveat:** the acceptor must **not** override `terminate:`. Without the override, `terminateChild:` and `sup stop` kill it at once while it is blocked. `{error, closed}` leads to `self stop`, a normal exit, and a `#transient` child stays down (`#stopped`). A `kill` mid-accept is restarted and the new acceptor accepts. If `terminate:` is overridden, the actor traps exits, the `shutdown` waits behind the blocked accept, the supervisor waits out the whole shutdown timeout and then kills it, and `terminate:` never runs (pinned by `testTrappingAcceptorWaitsOutShutdownTimeout`). | `accept_loop_spike_test.bt` |
| 4 | A ref-tagged `read_timeout` timer: stale refs ignored, a newer deadline re-arms, `#infinity` cancels, no mailbox flush | **Holds.** A timer that fired and was then cancelled inside the same message arrives afterwards and is counted as stale, not as a timeout. A later deadline keeps the running timer and re-arms it for the remainder when it fires. An earlier deadline replaces the timer. `#infinity` cancels it. | `read_timeout_spike_test.bt` |
| 5 | `(Erlang telemetry) execute:with:with:` works with the hex dependency declared | **Holds, with caveats.** `telemetry ~> 1.3` (1.4.2) in `[native.dependencies]` builds through the bundled rebar3. A 4-argument Beamtalk block works as the `attach` handler fun and receives event, measurements, metadata and config. Caveats: every `(Erlang telemetry)` call site warns `Unknown Erlang module` (BT-4022), and `attach`'s `{error, already_exists}` is typed as a Symbol although it arrives as an Exception, so `r error reason` warns (BT-4023). | `telemetry_spike_test.bt` |
| 6 | Rough cost of the `handleInfo:` round trip per packet (10k echo) | **Measured; see below.** `handleInfo:` dispatch is cheap (~0.4 µs). The cost is in the inline FFI (~7-15 µs per call, BT-4021). | `echo_bench_spike_test.bt` |

## Spike 6 numbers

10,000 one-byte request/response round trips over loopback, with
`nodelay`. macOS, Apple M5 Max, OTP 28, several runs:

| Measure | Per packet / message |
|---|---|
| Echo through `ActiveOnceEcho` (`handleInfo:` + `send` + `setopts`) | 60-66 µs |
| Passive baseline (the test process echoes; the same four socket calls) | 56-59 µs |
| Server path over baseline | 4-8 µs |
| `handleInfo:` dispatch alone (10k queued `{read_timeout, Ref}`, match + state update, no FFI) | 0.36-0.39 µs |
| One inline FFI call (`Erlang erlang send: pid msg: m` in a loop) | ~14.5 µs |

How to read these numbers:

- The round trip is dominated by loopback latency plus the **FFI calls**. Each
  round trip makes four of them (client `send` and `recv`, server `send` and
  `setopts`). Each inline FFI call goes through
  `beamtalk_erlang_proxy:direct_call/3`, which calls `module_info(exports)` on
  every call (about 5 µs on its own). This is the one finding that matters
  for Catalina's per-packet cost. It is filed as BT-4021.
- `handleInfo:` itself costs about what PLAN.md expected: sub-microsecond
  dispatch, well inside the 1-3 µs estimate from `docs/performance.md`.
- Linux, GitHub Actions `ubuntu-latest` runner, OTP 28.5, one run: server echo
  99 µs, passive baseline 89 µs, server path +10 µs, `handleInfo:` dispatch
  0.59 µs, one inline FFI call 22.6 µs. Every CI run prints them in the
  `Spikes` step log.

## Bugs and gaps filed

| Issue | What |
|---|---|
| BT-4021 | Inline FFI re-reads `module_info(exports)` on every call (~5-14 µs per call). Under BT-3957. |
| BT-4022 | `unresolved_ffi` warns on modules from the package's own `[native.dependencies]`. Under BT-3957. |
| BT-4023 | An FFI `Result`'s error side is typed as the spec's raw reason, but at runtime it is an Exception, so `r error reason` gets a false DNU warning. |
| BT-4024 | The docs' `handleInfo:` examples use `[ ... ]` blocks as `match:` arm bodies, which never run (and fail to compile when they write a field). |

None of them blocks the port. Spike 3 needs no new Beamtalk feature (no
`Task`-like worker): a `Server` that leaves `terminate:` alone is enough.

## Idioms the spikes settled

- A `match:` arm that does more than one thing calls a method:
  `{#tcp, _s, data} -> self onData: data;`. A `[ ... ]` arm is a block value
  and does not run (BT-4024).
- An actor that blocks in a foreign call (the acceptor) cannot answer sync
  calls. It reports state through something else (the spikes use Ets), and
  nothing should call it synchronously.
- `{error, closed}` from an FFI call is `result error reason =:= #closed`
  (BT-3954).
