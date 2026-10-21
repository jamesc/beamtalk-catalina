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
%%       [--only ROWID,...] [--out DIR]
-module(bench_main).

-export([main/0, rows/1]).

main() ->
    Opts = parse(init:get_plain_arguments(), #{
        rounds => 5, duration => 5000, warmup => 1000, rows => full,
        only => [], out => filename:join([os:getenv("BENCH_ROOT"), "_build", "bench"])
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
parse([], O) -> O;
parse([X | _], _) -> error({unknown_argument, X}).

%% === Rows ===

%% {Id, Kind, Params}. `smoke` is the CI subset.
rows(full) ->
    [{echo_id(C, S), echo, #{conns => C, size => S}}
        || S <- [64, 65536], C <- [1, 10, 100, 1000]]
    ++ [{"accept_tcp", churn, #{workers => 32}},
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
    Peers = maps:from_list([{I, bench_peer:start(I)} || I <- bench_peer:impls()]),
    Results = lists:append([round(R, Rows, Peers, Opts, Raw) || R <- lists:seq(1, Rounds)]),
    [bench_peer:stop(P) || P <- maps:values(Peers)],
    file:close(Raw),
    Report = report(Rows, Results, Env#{started => Stamp, finished_load => load(), opts => Opts}),
    ReportFile = filename:join(Out, "report-" ++ Tag ++ ".md"),
    ok = file:write_file(ReportFile, Report),
    io:put_chars(Report),
    log("~nraw: ~s~nreport: ~s~n", [RawFile, ReportFile]),
    ok.

select(Rows, []) -> Rows;
select(Rows, Only) -> [R || R = {Id, _, _} <- Rows, lists:member(Id, Only)].

round(R, Rows, Peers, Opts, Raw) ->
    Order = case R rem 2 of 1 -> [catalina, ti]; 0 -> [ti, catalina] end,
    log("round ~p (~s)~n", [R, load()]),
    lists:append([[measure(R, Row, I, maps:get(I, Peers), Opts, Raw) || I <- Order] || Row <- Rows]).

measure(Round, {Id, Kind, Params}, Impl, Peer, Opts, Raw) ->
    Load = load(),
    Tls = maps:get(tls, Params, false),
    Server = maps:merge(#{port => 0, tls => Tls}, maps:get(server, Params, #{})),
    {ok, Port} = bench_peer:call(Peer, bench_node, start_server, [Server]),
    Metrics = try
        bench_load:wait_ready(Port, Tls, 120000),
        run_row(Kind, Port, Peer, Params#{
            warmup_ms => maps:get(warmup, Opts), duration_ms => maps:get(duration, Opts)})
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

%% === Report ===

%% Metrics reported per kind: {key, label, better}, where better says which
%% direction is good for the ratio's reading.
metrics(echo) ->
    [{msgs_per_s, "msg/s", higher}, {bytes_per_s, "MB/s", higher},
     {p50, "p50 µs", lower}, {p99, "p99 µs", lower}, {p999, "p99.9 µs", lower}];
metrics(churn) ->
    [{msgs_per_s, "conn/s", higher}, {p50, "p50 µs", lower}, {p99, "p99 µs", lower}];
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
    [Header, Lines].

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
fmt(_, V) -> io_lib:format("~.1f", [V]).

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
