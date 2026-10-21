# Catalina v0.1.0 release gate: results

Catalina against [Thousand Island](https://hex.pm/packages/thousand_island)
1.6.0 under load and under failure, for the v0.1.0 go/no-go (BT-4051). How
the harness works is in the README, § Benchmarks and stress tests. The raw
reports these numbers come from are summarised here, not checked in: rerun
`just bench --rounds 7 --max-load 8` and `just stress` to reproduce them.

## Summary

- **Correctness: every stress test passes on Catalina** (18/18), including
  the 30-minute soak. Thousand Island, run with the same assertions, passes
  16 of 17 (one intermittent chaos failure on its side, § Stress). The work
  found and fixed three Catalina bugs and one flaky test (§ Catalina fixes).
- **Echo throughput and latency are at or near parity** on a quiet machine:
  0.85-1.00x Thousand Island at 64 B, 0.89-0.93x at 64 KiB from 100
  connections up, 0.91-0.96x over TLS. Per-connection memory is the same
  (1.03x, one process per connection).
- **Rows more than 2x slower than Thousand Island:**
  - **Accept rate, 0.10x.** The cause is Beamtalk's trace store: **the
    trace store costs 71% of accept throughput (51% at 128 clients) and is
    the limiter.** With its telemetry handlers detached, Catalina accepts at
    0.95-1.03x Thousand Island (§ Trace store).
  - **TLS handshakes, 0.42x in the main run.** On a fresh node they are at
    0.88x. The main run's node had already served the other rows, and the
    trace store's slot free list degrades with use (§ Trace store, § Rows
    more than 2x slower).
  - **Single-connection 64 KiB echo, 0.43x.** Per-message dispatch overhead
    in the Beamtalk runtime, filed (§ Rows more than 2x slower).
- **No pass/fail claim on performance.** Whether 0.1.0 ships with the
  accept-rate gap is a decision on the trace-store issue, not on Catalina.

## Setup

| | |
|---|---|
| Machine | Apple M5 Max, 18 cores, 64 GiB, macOS (Darwin 25.6.0), shared with other agents |
| OTP | 28 (ERTS 16.4), 18 schedulers, in every VM |
| Elixir | 1.20.1 |
| Thousand Island | 1.6.0 (`bench/thousand_island/mix.lock`) |
| Beamtalk | 0.4.0, local build of main at 1a26f8468 (BT-4053, BT-4064, BT-4065, BT-4066, BT-4071 and everything before them) |
| Catalina | main at c06db66 plus the harness commits of this PR (no `src/` changes beyond main) |
| Configuration | both servers: echo handler, 100 acceptors, default transport options and buffer sizes, the same certificate for TLS |
| Method | each server in its own peer VM, the load generator in a third; 7 rounds; every row measured on both servers back to back each round, order alternating; 5 s measured after 1 s warm-up; medians reported |

Every round waited for the 1-minute load average to drop below 8
(`--max-load 8`). Load at the start of each round:

| Round | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|
| Main run | 6.93 | 5.85 | 6.28 | 5.33 | 6.60 | 6.36 | 7.16 |
| Trace store A/B (accept) | 6.53 | 5.89 | 7.65 | 7.05 | 7.31 | 6.28 | 5.91 |
| Trace store A/B (TLS handshakes) | 7.44 | 6.54 | 5.98 | 5.76 | 5.96 | | |

The load the bench itself generates (two busy VMs) is not in these numbers;
they are taken before each round starts.

## Main table

Medians of 7 rounds. Ratio is Catalina ÷ Thousand Island: above 1 is better
for Catalina on throughput, worse on latency and memory.

### Echo (closed loop: send, wait for all of it back, repeat)

| Row | Catalina msg/s | TI msg/s | Ratio | Catalina p50 / p99 / p99.9 µs | TI p50 / p99 / p99.9 µs |
|---|---:|---:|---:|---|---|
| 1 conn, 64 B | 28,546 | 33,635 | 0.85 | 35 / 51 / 108 | 30 / 39 / 85 |
| 10 conns, 64 B | 117,968 | 132,988 | 0.89 | 82 / 148 / 176 | 73 / 133 / 158 |
| 100 conns, 64 B | 142,070 | 144,481 | 0.98 | 598 / 2,313 / 4,161 | 604 / 2,094 / 3,692 |
| 1,000 conns, 64 B | 150,164 | 149,998 | 1.00 | 5,721 / 24,212 / 36,049 | 5,894 / 21,702 / 31,050 |
| 1 conn, 64 KiB | 7,622 (500 MB/s) | 17,573 (1,152 MB/s) | **0.43** | 130 / 145 / 172 | 56 / 69 / 137 |
| 10 conns, 64 KiB | 35,052 (2,297 MB/s) | 52,705 (3,454 MB/s) | 0.67 | 278 / 426 / 490 | 187 / 310 / 356 |
| 100 conns, 64 KiB | 37,867 (2,482 MB/s) | 42,605 (2,792 MB/s) | 0.89 | 2,632 / 2,908 / 3,309 | 2,360 / 2,632 / 2,767 |
| 1,000 conns, 64 KiB | 34,724 (2,276 MB/s) | 37,312 (2,445 MB/s) | 0.93 | 22,583 / 348,468 / 446,886 | 21,702 / 345,017 / 351,952 |

From 100 connections up, both servers are limited by the loopback and the
client, and Catalina's extra per-message cost is hidden. At 1 and 10
connections it shows.

### Connections and TLS

| Row | Catalina | TI | Ratio | Catalina p50 / p99 µs | TI p50 / p99 µs |
|---|---:|---:|---:|---|---|
| Accept rate (connect, one echo, close; 32 clients), conn/s | 3,131 | 31,860 | **0.10** | 9,693 / 23,267 | 935 / 1,224 |
| Accept rate, 128 clients, conn/s | 3,176 | 31,912 | **0.10** | 40,218 / 80,709 | 3,881 / 8,433 |
| TLS handshakes (connect, handshake, one echo, close), /s | 2,979 | 7,012 | **0.42** | 10,392 / 20,242 | 4,417 / 7,192 |
| TLS echo, 100 conns, 64 B, msg/s | 143,958 | 149,838 | 0.96 | 680 / 1,325 | 660 / 1,141 |
| TLS echo, 100 conns, 64 KiB, msg/s | 32,467 | 35,767 | 0.91 | 2,996 / 3,842 | 2,794 / 3,376 |

### Memory: 10,000 idle connections

| | Catalina | TI | Ratio |
|---|---:|---:|---:|
| Node bytes per connection | 14,589 | 14,099 | 1.03 |
| Handler process bytes per connection | 2,944 | 2,800 | 1.05 |
| Processes per connection | 1.00 | 1.00 | 1.00 |

## Trace store

Beamtalk's `beamtalk_trace_store` keeps always-on per-actor dispatch
aggregates (ADR 0069). Since BT-4066 it also monitors every actor and frees
its counter slot when the actor exits. Every connection starts an actor,
so the accept path pays for it.

The A/B ran a third peer, Catalina with the trace store's telemetry handlers
detached (`telemetry:detach/1` of `beamtalk_trace_store:telemetry_handler_ids()`;
`beamtalk_trace_store:disable/0` only gates trace events, not the
aggregates), in the same 7 rounds as Catalina and Thousand Island
(`just bench --ab-trace-store --only accept_tcp,accept_tcp_w128`):

| Row | Catalina | Catalina, trace store detached | TI | Trace store cost |
|---|---:|---:|---:|---:|
| Accept rate, 32 clients, conn/s | 8,689 | 30,361 | 31,955 | **71%** |
| Accept rate, 128 clients, conn/s | 15,973 | 32,289 | 31,355 | **51%** |
| p50 latency, 32 clients | 3.1 ms | 0.98 ms | 0.93 ms | |

**The trace store costs 71% of accept throughput (51% at 128 clients) and
is the limiter.** With it detached, Catalina's accept rate is at parity with
Thousand Island (0.95x and 1.03x), flat across all seven rounds.

The trace store's own process is not where the time goes. It used 1.4% of
the node's reductions, with a peak mailbox of 64-427 and a p99 mailbox of
28-157 messages during the accept rows. The cost is in the callers, and one
part of it grows after start-up:

- **Per actor:** on every dispatch and lifecycle event, the calling process
  runs the trace store's telemetry handlers: an ETS index row, counter
  updates, compare-and-swap for min/max duration, two casts to the trace
  store, and a monitor `DOWN` handled by it.
- **The slot free list.** On one node, back-to-back churn windows run at
  14,000 conn/s in the first window, then step down to ~8,400 and stay
  there. Nothing grows: ETS rows, atoms, persistent terms and processes are
  flat. A call-count diff of the first and third window shows the same work
  per accept (6,781 against 6,791 calls, 4 synchronous calls each) except
  `beamtalk_trace_store:take_slot/0`, which goes from 3.85 to 7.36 calls per
  accept. It takes a counter slot with `ets:first` plus `ets:take` on one
  shared free-list table. Once the first wave of actors has exited, every
  new actor takes its slot from that list, and all of them race for its
  first key and retry. This is also why the main run's accept rows, which
  ran on a node that had already served the echo rows, are lower (3,131)
  than the A/B's (8,689).

Whether this blocks 0.1.0 is decided on the trace-store issue (always-on
aggregates keyed by {Class, Selector} only, with no per-actor slot or
monitor). The data here supports that design.

## Rows more than 2x slower

**Accept rate (0.10x).** The trace store, above.

**TLS handshakes (0.42x in the main run).** A separate A/B on fresh nodes
(`--ab-trace-store --only tls_handshake`, 5 rounds, every round started at
load 5.8-7.4):

| | Catalina | Catalina, trace store detached | TI |
|---|---:|---:|---:|
| TLS handshakes/s | 6,651 | 7,060 | 7,532 |

On a fresh node Catalina is at 0.88x, and the trace store costs 5.8% (a
handshake costs far more than the trace store's per-actor work, so its
share is small). The main run's 0.42x (round 1: 4,807, then ~2,900) is the
same aging as its accept rows: by then the main run's Catalina node had
already served the echo and accept rows, so new actors took their slots
from the trace store's free list (§ Trace store), the contended path. So this row is
more than 2x slower only on an aged node, for the trace-store reason.

**Single-connection 64 KiB echo (0.43x), 10 connections (0.67x).** This is
per-message cost in the handler, visible when one or a few connections are
not limited by the network. Measured on one connection, 5,000 echoes,
untraced:

| Per 64 B echo (one message) | Catalina | TI |
|---|---:|---:|
| Handler reductions | 1,766 | 219 |
| Words garbage-collected | 2,317 | 105 |

The handler makes ~31 dynamic sends and 6 inherited self-sends per message.
In a call-time profile, the dynamic-send machinery is ~54% of handler time,
inherited-method lookup ~10%, and Catalina's own code ~10%. The Beamtalk
costs are filed: BT-4069 (sealed-Value sends as direct calls, ~16 of the
31), BT-4109 (inherited self-sends walk the class chain on every call,
0.40 µs against 0.023 µs for a local method), and BT-4070 (conditionals with
literal blocks compile to sends, Low).

Catalina's own per-message design matches Thousand Island's call for call:
one receive and one send per chunk, the same socket options, the same two
telemetry events per echo (counted: 2.0 `telemetry:execute/3` per echo on
both), and the same continuation handling. There is no
extra copying of 64 KiB payloads. Building the telemetry event name once per
span instead of per event was considered and skipped: it saves 0.04-0.09 µs
per message (the list `add:` sends take the runtime's fast path), which is
below the noise of these rows.

## How the runtime fixes moved the numbers

Earlier measurements, on the same harness but under different machine load,
so read them as orders of magnitude, not exact ratios:

| Beamtalk build | Load | Catalina echo 1 conn 64 B, msg/s | Catalina echo 10 conns 64 KiB, msg/s | Catalina accept, conn/s | Handler reductions per 64 B echo |
|---|---|---:|---:|---:|---:|
| before BT-4053 | 60-90 | 218 | 0 (no echo completed in 3 s) | 80 | — |
| BT-4053 (b07e2c149) | 40-95 | 7,029 | 8,756 | 6,170 | 13,657 |
| BT-4064 (aead84a31) | ~30 | — | — | — | 2,524 |
| BT-4065, BT-4066, BT-4071 (1a26f8468) | 5-7 | 28,546 | 35,052 | 3,131 (trace store) | 1,766 |
| Thousand Island, same final run | 5-7 | 33,635 | 52,705 | 31,860 | 219 |

## Stress

`just stress` at full sizes, both servers, on 1a26f8468. Each test runs
against Catalina and, with the same assertions, Thousand Island (the soak
runs on Catalina only).

Full run 23:31-00:05 BST (`just stress`, full sizes); Catalina **18/18
pass**, Thousand Island 16/17.

| Test | Catalina | Thousand Island | Detail (Catalina) |
|---|---|---|---|
| `fuzz_tcp`, `fuzz_tls` | pass | pass | 40 connections, 480 payloads of 0-1 MiB in random fragments, ~62 MB each, byte-exact |
| `leak_churn` | pass | pass | 10,000 cycles (resets, clean closes, no data, mid-echo); processes, ports, ETS tables and ETS rows back to baseline |
| `leak_server_lifecycle` | pass | pass | 10 rounds of TCP and TLS servers stopped with live connections |
| `limits_refuse_over_max`, `limits_queue_until_free`, `limits_recover_under_load` | pass | pass | over `numConnections`: closed after the 600 ms retry window, as Thousand Island; served when a slot frees; recovers |
| `timeout_idle`, `timeout_trickle_slow`, `timeout_trickle_fast` | pass | pass | idle and slow-trickle connections close at `readTimeout` (400-401 ms); bytes more often than that keep a connection open, as in Thousand Island |
| `timeout_slowloris_under_load` | pass | pass | 500 slow connections all closed within `readTimeout` + 13 ms while echo clients kept working |
| `half_close` | pass | pass | data before a half-close is echoed, then the server closes |
| `chaos_kill_acceptors_and_handlers` | pass | **fail, intermittent** | 30 s, 261 acceptor and 261 handler kills, 3.77M echoes, only `closed` errors, no supervisor restart, no leak |
| `chaos_acceptor_killed_mid_handoff` | pass | pass | 10 acceptors killed the moment their handler starts: no handler left behind |
| `lifecycle_suspend_resume` | pass | pass | existing connections keep echoing while suspended, new ones refused, served again after resume |
| `lifecycle_stop_drains`, `lifecycle_stop_kills_at_deadline` | pass | pass | in-flight callbacks finish within `shutdownTimeout` (stop 308 ms); past it they are killed (stop 506 ms against 500) |
| `soak_mixed_load` (30 min, Catalina only) | pass | | 148.6M echoes over TCP and TLS, persistent, churning and 1,000 idle connections, no errors; memory floor 115 to 117 MiB, settled 88 to 91 MiB after the load; process count did not grow; trace store peak mailbox 509, p99 12 |

**Thousand Island's chaos failure.** After the 30 s of kills, not every
connection closed within 30 s. The test passed on five reruns, so it is
intermittent (1 in 6). The likeliest cause is the race Catalina fixed in
this work: Thousand Island's handler waits for `:thousand_island_ready` with
no timeout, so one whose acceptor is killed between `start_child` and the
handoff waits for ever. That is not proven: the chaos test now names the
leftover handlers' state when it fails, for the next occurrence. It is a
reference-server result and does not bear on Catalina.

Correctness verdict for Catalina: **every stress test passes**, at the
sizes the issue sets (10k-cycle leak check, 30-minute soak).

## Catalina fixes found by this work

| Fix | Found by | PR |
|---|---|---|
| A TimeoutProxy actor leaked on every acceptor start (100 per server, one per acceptor restart) | `leak_server_lifecycle` | #14 |
| A handler whose acceptor died between `startChild:` and the ready message waited forever (Thousand Island has the same race) | `chaos_acceptor_killed_mid_handoff` | #14 |
| Every successful handler start ran two `isKindOf:` checks, each several calls into class processes (accept rate 0.62x to 0.78x Thousand Island at the time) | profiling accept | #16 |
| `AcceptorTest` and `TelemetryTest` shared node-wide injected-error queues and flaked when run in parallel | flaky `just test` | #14 |

## Beamtalk issues filed (under BT-3957)

| Issue | What | Status when measured |
|---|---|---|
| BT-4053 | Dynamic sends to a Value instance called `code:ensure_loaded` on two missing modules each time, through `code_server` | fixed |
| BT-4064 | ...then rebuilt the class's module name from strings on every send | fixed |
| BT-4065 | Class references, `isKindOf:` and `Result ok:`/`error:` were synchronous calls into class processes | fixed |
| BT-4066 | The trace store leaked ETS rows per actor | fixed; its fix is the accept-rate limiter above |
| BT-4067 | Beamtalk modules export no `module_info/0,1`, so eprof, tprof and fprof crash | open (the harness has its own profiler) |
| BT-4068 | `DynamicSupervisor maxChildren` costs an extra call per start and is not atomic | open, Low |
| BT-4070 | Conditionals with literal blocks compile to sends | open, Low |
| BT-4071 | `self hasField:` resolved through the xref index (20 µs per call) | fixed |
| BT-4109 | Inherited self-sends walk the class chain on every call | open |
| BT-4069 | Sends to a sealed-Value-typed receiver could call the class module directly | open (filed by another agent) |
| trace store | Always-on aggregates per {Class, Selector}, no per-actor slot or monitor | open; decides the accept rate |

## Reproducing

```bash
just bench --rounds 7 --duration 5000 --warmup 1000 --max-load 8
just bench --rounds 7 --duration 5000 --warmup 1000 --max-load 8 \
  --ab-trace-store --only accept_tcp,accept_tcp_w128
just stress                         # full sizes, 30-minute soak
bench/run.sh bench_profile --impl catalina --row echo_c1_64KiB --type call_count
```
