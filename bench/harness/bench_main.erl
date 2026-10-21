%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc `just bench`: Catalina against Thousand Island, interleaved.
%%
%% Both servers run in their own peer VMs for the whole run, and the load
%% generator in this one. Every round measures every row once for each
%% server, back to back, alternating which goes first, so machine load
%% (the box is shared) hits both alike. The report gives medians over the
%% rounds and the Catalina/TI ratio for each metric.
%%
%%   erl -noshell -pa _build/bench/ebin -s bench_main main -extra \
%%       [--rounds 5] [--duration 5000] [--warmup 1000] [--rows full|smoke]
%%       [--only ROWID,...] [--out DIR] [--max-load L] [--ab-trace-store]
%%
%% With `--ab-trace-store`, a third peer runs Catalina with the Beamtalk
%% trace store's telemetry handlers detached (`catalina_notrace`), measured
%% in the same rounds, and the report adds what the trace store costs.
%%
%% With `--max-load L`, each round waits (up to 30 minutes) until the
%% 1-minute load average is below L, so a shared machine is measured when
%% it is quiet; the report records the load at every round.
-module(bench_main).

-export([main/0, rows/1]).

main() ->
    Opts = parse(init:get_plain_arguments(), #{
        rounds => 5, duration => 5000, warmup => 1000, rows => full,
        only => [], max_load => undefined, ab_trace_store => false,
        out => filename:join([os:getenv("BENCH_ROOT"), "_build", "bench"])
    }),
    try run(Opts) of
        ok -> halt(0)
    catch
        C:R:St ->
            io:format(standard_error, "bench failed: ~p:~p~n~p~n", [C, R, St]),
            halt(1)
    end.

parse(["--rounds", N | T], O) -> parse(T, O#{rounds => list_to_integer(N)});
parse(["--duration", N | T], O) -> parse(T, O#{duration => list_to_integer(N)});
parse(["--warmup", N | T], O) -> parse(T, O#{warmup => list_to_integer(N)});
parse(["--rows", R | T], O) -> parse(T, O#{rows => list_to_atom(R)});
parse(["--only", R | T], O) -> parse(T, O#{only => string:split(R, ",", all)});
parse(["--out", D | T], O) -> parse(T, O#{out => D});
parse(["--max-load", L | T], O) -> parse(T, O#{max_load => list_to_number(L)});
parse(["--ab-trace-store" | T], O) -> parse(T, O#{ab_trace_store => true});
parse([], O) -> O;
parse([X | _], _) -> error({unknown_argument, X}).

list_to_number(S) ->
    try list_to_integer(S) catch error:badarg -> list_to_float(S) end.

%% === Rows ===

%% {Id, Kind, Params}. `smoke` is the CI subset.
rows(full) ->
    [{echo_id(C, S), echo, #{conns => C, size => S}}
        || S <- [64, 65536], C <- [1, 10, 100, 1000]]
    ++ [{"accept_tcp", churn, #{workers => 32}},
        %% Churn at the highest rate the clients can drive.
        {"accept_tcp_w128", churn, #{workers => 128}},
        {"tls_handshake", churn, #{workers => 32, tls => true}},
        {"tls_echo_c100_64B", echo, #{conns => 100, size => 64, tls => true}},
        {"tls_echo_c100_64KiB", echo, #{conns => 100, size => 65536, tls => true}},
        %% No read timeout: opening 10,000 connections can take longer than
        %% the default 60 s on a slow server, and the first ones would close.
        {"idle_10k", idle, #{conns => 10000, server => #{read_timeout => infinity}}}];
rows(smoke) ->
    [{echo_id(10, 64), echo, #{conns => 10, size => 64}},
     {echo_id(10, 65536), echo, #{conns => 10, size => 65536}},
     {"accept_tcp", churn, #{workers => 8}},
     {"tls_handshake", churn, #{workers => 8, tls => true}},
     {"idle_1k", idle, #{conns => 1000, server => #{read_timeout => infinity}}}].

echo_id(C, 64) -> "echo_c" ++ integer_to_list(C) ++ "_64B";
echo_id(C, 65536) -> "echo_c" ++ integer_to_list(C) ++ "_64KiB".

%% === The run ===

run(Opts = #{rounds := Rounds, out := Out}) ->
    ok = filelib:ensure_path(Out),
    {ok, _} = application:ensure_all_started(ssl),
    Rows = select(rows(maps:get(rows, Opts)), maps:get(only, Opts)),
    Stamp = calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}]),
    Tag = [C || C <- Stamp, C =/= $:],
    RawFile = filename:join(Out, "raw-" ++ Tag ++ ".jsonl"),
    {ok, Raw} = file:open(RawFile, [write]),
    Env = environment(),
    log("bench: ~p rounds, ~p rows, ~p ms per measurement; ~s~n",
        [Rounds, length(Rows), maps:get(duration, Opts), load()]),
    Impls = impls(Opts),
    Peers = maps:from_list([{I, bench_peer:start(I)} || I <- Impls]),
    PerRound = [round(R, Rows, Peers, Opts, Raw) || R <- lists:seq(1, Rounds)],
    Results = lists:append([Rs || {_, _, Rs} <- PerRound]),
    [bench_peer:stop(P) || P <- maps:values(Peers)],
    file:close(Raw),
    Report = [report(Rows, Results, Env#{started => Stamp, finished_load => load(), opts => Opts}),
              "\nLoad average (1, 5, 15 min) at the start of each round:\n\n",
              [io_lib:format("- round ~p: ~s~n", [R, L]) || {R, L, _} <- PerRound]],
    ReportFile = filename:join(Out, "report-" ++ Tag ++ ".md"),
    ok = file:write_file(ReportFile, unicode:characters_to_binary(Report)),
    io:put_chars(Report),
    log("~nraw: ~s~nreport: ~s~n", [RawFile, ReportFile]),
    ok.

impls(#{ab_trace_store := true}) -> [catalina, ti, catalina_notrace];
impls(_) -> [catalina, ti].

select(Rows, []) -> Rows;
select(Rows, Only) -> [R || R = {Id, _, _} <- Rows, lists:member(Id, Only)].

round(R, Rows, Peers, Opts, Raw) ->
    Base = impls(Opts),
    %% Rotate the order each round so no implementation always goes first.
    Shift = (R - 1) rem length(Base),
    Order = lists:nthtail(Shift, Base) ++ lists:sublist(Base, Shift),
    wait_for_quiet(maps:get(max_load, Opts), erlang:monotonic_time(second) + 1800),
    Load = load(),
    log("round ~p (~s)~n", [R, Load]),
    {R, Load, lists:append([[measure(R, Row, I, maps:get(I, Peers), Opts, Raw) || I <- Order] || Row <- Rows])}.

measure(Round, {Id, Kind, Params}, Impl, Peer, Opts, Raw) ->
    Load = load(),
    Tls = maps:get(tls, Params, false),
    Server = maps:merge(#{port => 0, tls => Tls}, maps:get(server, Params, #{})),
    {ok, Port} = bench_peer:call(Peer, bench_node, start_server, [Server]),
    Metrics = try
        bench_load:wait_ready(Port, Tls, 120000),
        bench_peer:call(Peer, bench_node, watch_start, [watched()]),
        M0 = run_row(Kind, Port, Peer, Params#{
            warmup_ms => maps:get(warmup, Opts), duration_ms => maps:get(duration, Opts)}),
        maps:merge(M0, watched_metrics(bench_peer:call(Peer, bench_node, watch_stop, [])))
    after
        bench_peer:call(Peer, bench_node, stop_server, [5000])
    end,
    Rec = #{round => Round, row => list_to_binary(Id), impl => Impl,
            load => list_to_binary(Load), metrics => Metrics},
    io:format(Raw, "~s~n", [json:encode(jsonable(Rec))]),
    log("  ~-22s ~-8s ~s~n", [Id, Impl, brief(Kind, Metrics)]),
    {Id, Impl, Metrics}.

run_row(echo, Port, _Peer, P) -> bench_load:echo(Port, P);
run_row(churn, Port, _Peer, P) -> bench_load:churn(Port, P);
run_row(idle, Port, Peer, #{conns := N}) ->
    Before = settled_stats(Peer),
    Idle = bench_load:open_idle(Port, N, false),
    {_, Opened, Failures} = Idle,
    After = settled_stats(Peer),
    HandlerMem = bench_peer:call(Peer, bench_node, handler_memory, []),
    bench_load:close_idle(Idle),
    Held = maps:get(connections, After),
    Base = #{opened => Opened, server_connections => Held,
             open_failures => lists:usort([R || {error, R} <- Failures])},
    case Opened =:= N andalso Held =:= N of
        true ->
            D = fun(K) -> (maps:get(K, After) - maps:get(K, Before)) / N end,
            Base#{bytes_per_conn => D(memory),
                  process_bytes_per_conn => D(process_memory),
                  handler_bytes_per_conn => HandlerMem / N,
                  processes_per_conn => D(processes),
                  ports_per_conn => D(ports)};
        false ->
            %% Per-connection figures are only meaningful with all N held.
            Base#{error => incomplete}
    end.

%% Node stats once the process count has stopped changing (a previous
%% row's server may still be winding down), after garbage collection.
settled_stats(Peer) -> settled_stats(Peer, undefined, 40).

settled_stats(Peer, Prev, Tries) ->
    bench_peer:call(Peer, bench_node, gc_all, []),
    timer:sleep(500),
    S = bench_peer:call(Peer, bench_node, stats, []),
    Now = maps:get(processes, S),
    case Now =:= Prev orelse Tries =:= 0 of
        true -> S;
        false -> settled_stats(Peer, Now, Tries - 1)
    end.

%% Node-wide processes every connection may touch: Beamtalk's trace store
%% (BT-4066 monitors every actor through it). Their peak mailbox and
%% reductions per second go in the raw results and the report.
watched() -> [beamtalk_trace_store].

watched_metrics(W) ->
    maps:fold(fun(Name, #{peak_queue := Q, p99_queue := Q99, reductions := R,
                          reduction_share := Share, seconds := S}, Acc) ->
        K = fun(Suffix) -> list_to_atom(atom_to_list(Name) ++ Suffix) end,
        Acc#{K("_peak_queue") => Q,
             K("_p99_queue") => Q99,
             K("_reductions_per_s") => R / max(S, 0.001),
             K("_reduction_share_pct") => 100 * Share}
    end, #{}, W).

brief(echo, #{msgs_per_s := M, p50 := P50, p99 := P99, errors := E}) ->
    io_lib:format("~10.1f msg/s  p50 ~s  p99 ~s  errors ~p", [M, us(P50), us(P99), E]);
brief(churn, #{msgs_per_s := M, p50 := P50, errors := E}) ->
    io_lib:format("~10.1f conn/s  p50 ~s  errors ~p", [M, us(P50), E]);
brief(idle, #{error := E, opened := O, server_connections := H, open_failures := F}) ->
    io_lib:format("~p: ~p opened, ~p held by the server; ~0p", [E, O, H, F]);
brief(idle, #{bytes_per_conn := B, processes_per_conn := P, opened := O}) ->
    io_lib:format("~p conns  ~w B/conn  ~.2f procs/conn", [O, round(B), P]);
brief(_, M) ->
    io_lib:format("~p", [M]).

us(undefined) -> "-";
us(V) when V >= 1000 -> io_lib:format("~.2fms", [V / 1000]);
us(V) -> io_lib:format("~wus", [round(V)]).

%% Wait until the 1-minute load average is below Max, or the deadline.
wait_for_quiet(undefined, _) -> ok;
wait_for_quiet(Max, Deadline) ->
    Load1 = load1(),
    case Load1 < Max orelse erlang:monotonic_time(second) > Deadline of
        true -> ok;
        false ->
            log("  load ~.2f >= ~p, waiting~n", [Load1, Max]),
            timer:sleep(30000),
            wait_for_quiet(Max, Deadline)
    end.

load1() ->
    [L | _] = string:lexemes(load(), " "),
    list_to_number(string:trim(L)).

%% === Report ===

%% Metrics reported per kind: {key, label, better}, where better says which
%% direction is good for the ratio's reading.
metrics(echo) ->
    [{msgs_per_s, "msg/s", higher}, {bytes_per_s, "MB/s", higher},
     {p50, "p50 µs", lower}, {p99, "p99 µs", lower}, {p999, "p99.9 µs", lower}];
metrics(churn) ->
    [{msgs_per_s, "conn/s", higher}, {p50, "p50 µs", lower}, {p99, "p99 µs", lower},
     {beamtalk_trace_store_peak_queue, "trace store peak mailbox", lower},
     {beamtalk_trace_store_p99_queue, "trace store p99 mailbox", lower},
     {beamtalk_trace_store_reductions_per_s, "trace store reductions/s", lower},
     {beamtalk_trace_store_reduction_share_pct, "trace store % of node reductions", lower}];
metrics(idle) ->
    [{bytes_per_conn, "node bytes/conn", lower},
     {handler_bytes_per_conn, "handler bytes/conn", lower},
     {processes_per_conn, "processes/conn", lower}].

report(Rows, Results, Env) ->
    Header = io_lib:format(
        "# Catalina vs Thousand Island~n~n"
        "- Started: ~s~n- Machine: ~s~n- OS: ~s~n- OTP: ~s (ERTS ~s), ~p schedulers~n"
        "- Elixir: ~s~n- Thousand Island: ~s~n- Beamtalk: ~s~n- Catalina: ~s~n"
        "- Rounds: ~p, ~p ms measured after ~p ms warm-up per measurement~n"
        "- Load at start: ~s~n- Load at end: ~s~n~n"
        "Medians over the rounds. Ratio is Catalina ÷ Thousand Island: above 1 "
        "is better for Catalina on throughput rows, worse on latency and memory rows.~n~n"
        "| Row | Metric | Catalina | Thousand Island | Ratio | Catalina rounds | TI rounds |~n"
        "|---|---|---:|---:|---:|---|---|~n",
        [maps:get(started, Env), maps:get(machine, Env), maps:get(os, Env),
         maps:get(otp, Env), maps:get(erts, Env), maps:get(schedulers, Env),
         maps:get(elixir, Env), maps:get(thousand_island, Env), maps:get(beamtalk, Env),
         maps:get(catalina, Env),
         maps:get(rounds, maps:get(opts, Env)), maps:get(duration, maps:get(opts, Env)),
         maps:get(warmup, maps:get(opts, Env)), maps:get(load, Env), maps:get(finished_load, Env)]),
    Lines = [row_lines(Id, Kind, Results) || {Id, Kind, _} <- Rows],
    [Header, Lines, ab_trace_store(Rows, Results)].

%% Catalina against Catalina with the trace store detached, when measured.
ab_trace_store(Rows, Results) ->
    case [x || {_, catalina_notrace, _} <- Results] of
        [] -> [];
        _ ->
            ["\n## Trace store A/B\n\n"
             "Catalina as shipped against Catalina with the Beamtalk trace store's "
             "telemetry handlers detached, in the same rounds. Cost is how much "
             "faster the detached node is on the row's main throughput metric.\n\n"
             "| Row | Catalina | Catalina, trace store detached | Trace store cost |\n"
             "|---|---:|---:|---:|\n",
             [begin
                  With = median(values(Id, catalina, msgs_per_s, Results)),
                  Without = median(values(Id, catalina_notrace, msgs_per_s, Results)),
                  io_lib:format("| ~s | ~s | ~s | ~s |~n",
                                [Id, fmt(msgs_per_s, With), fmt(msgs_per_s, Without), cost(With, Without)])
              end || {Id, Kind, _} <- Rows, Kind =/= idle]]
    end.

cost(With, Without) when is_number(With), is_number(Without), Without > 0 ->
    io_lib:format("~.1f%", [100 * (Without - With) / Without]);
cost(_, _) -> "-".

row_lines(Id, Kind, Results) ->
    [begin
        Cat = values(Id, catalina, Key, Results),
        Ti = values(Id, ti, Key, Results),
        Mc = median(Cat),
        Mt = median(Ti),
        io_lib:format("| ~s | ~s | ~s | ~s | ~s | ~s | ~s |~n",
                      [Id, Label, fmt(Key, Mc), fmt(Key, Mt), ratio(Mc, Mt),
                       all(Key, Cat), all(Key, Ti)])
     end || {Key, Label, _} <- metrics(Kind)].

values(Id, Impl, Key, Results) ->
    [V || {I, Im, M} <- Results, I =:= Id, Im =:= Impl,
          V <- [maps:get(Key, M, undefined)], is_number(V)].

median([]) -> undefined;
median(Vs) ->
    S = lists:sort(Vs),
    N = length(S),
    case N rem 2 of
        1 -> lists:nth(N div 2 + 1, S);
        0 -> (lists:nth(N div 2, S) + lists:nth(N div 2 + 1, S)) / 2
    end.

ratio(undefined, _) -> "-";
ratio(_, undefined) -> "-";
ratio(_, T) when T == 0 -> "-";
ratio(C, T) -> io_lib:format("~.3f", [C / T]).

fmt(_, undefined) -> "-";
fmt(bytes_per_s, V) -> io_lib:format("~.1f", [V / 1.0e6]);
fmt(processes_per_conn, V) -> io_lib:format("~.2f", [V]);
fmt(_, V) when V >= 100 -> integer_to_list(round(V));
fmt(_, V) -> io_lib:format("~.1f", [float(V)]).

all(Key, Vs) -> lists:join(", ", [fmt(Key, V) || V <- Vs]).

%% === Environment ===

environment() ->
    #{
        machine => machine(),
        os => trim(os:cmd("uname -sr")),
        otp => erlang:system_info(otp_release),
        erts => erlang:system_info(version),
        schedulers => erlang:system_info(schedulers_online),
        elixir => env_or("BENCH_ELIXIR_VERSION", "?"),
        thousand_island => env_or("BENCH_TI_VERSION", "?"),
        beamtalk => env_or("BENCH_BEAMTALK_VERSION", "?"),
        catalina => env_or("BENCH_CATALINA_REV", "?"),
        load => load()
    }.

machine() ->
    case os:type() of
        {unix, darwin} ->
            trim(os:cmd("sysctl -n machdep.cpu.brand_string")) ++ ", "
                ++ trim(os:cmd("sysctl -n hw.ncpu")) ++ " cores, "
                ++ integer_to_list(list_to_integer(trim(os:cmd("sysctl -n hw.memsize"))) div (1 bsl 30))
                ++ " GiB";
        _ ->
            trim(os:cmd("grep -m1 'model name' /proc/cpuinfo | cut -d: -f2")) ++ ", "
                ++ trim(os:cmd("nproc")) ++ " cores"
    end.

%% The 1/5/15-minute load averages.
load() ->
    case file:read_file("/proc/loadavg") of
        {ok, B} ->
            string:join(lists:sublist(string:lexemes(binary_to_list(B), " "), 3), " ");
        _ ->
            trim(string:replace(string:replace(os:cmd("sysctl -n vm.loadavg"), "{", ""), "}", ""))
    end.

env_or(K, D) -> case os:getenv(K) of false -> D; "" -> D; V -> V end.

trim(S) -> string:trim(lists:flatten(S)).

jsonable(M) when is_map(M) -> maps:map(fun(_, V) -> jsonable(V) end, M);
jsonable(L) when is_list(L) -> [jsonable(X) || X <- L];
jsonable(undefined) -> null;
jsonable(A) when is_atom(A) -> A;
jsonable(N) when is_number(N) -> N;
jsonable(B) when is_binary(B) -> B;
jsonable(T) -> iolist_to_binary(io_lib:format("~0p", [T])).

log(F, A) -> io:format(standard_error, F, A).
