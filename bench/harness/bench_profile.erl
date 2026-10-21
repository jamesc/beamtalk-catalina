%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Profile one bench row on one server: the load runs from this VM
%% while every process in the server peer is traced with call-time (or
%% call-count) breakpoints for a window in the middle of the run. Prints the top functions by time, and
%% the same grouped by module, so the costs can be split into the server's
%% own code, the language runtime, and OTP.
%%
%%   bench/run.sh bench_profile [--impl catalina|ti] [--row ROW]
%%       [--seconds N] [--top N] [--type call_time|call_count]
-module(bench_profile).

-export([main/0, profile/3]).

main() ->
    Opts = parse(init:get_plain_arguments(), #{impl => catalina, row => "echo_c10_64KiB",
                                               seconds => 3, top => 40, type => call_time}),
    {ok, _} = application:ensure_all_started(ssl),
    #{impl := Impl, row := RowId} = Opts,
    [{_, Kind, Params}] = [R || R = {Id, _, _} <- bench_main:rows(full), Id =:= RowId],
    Peer = bench_peer:start(Impl),
    Tls = maps:get(tls, Params, false),
    {ok, Port} = bench_peer:call(Peer, bench_node, start_server, [#{port => 0, tls => Tls}]),
    bench_load:wait_ready(Port, Tls, 120000),
    Secs = maps:get(seconds, Opts),
    Self = self(),
    Load = spawn_link(fun() ->
        Run = Params#{warmup_ms => 1000, duration_ms => Secs * 1000 + 2000},
        Self ! {load, case Kind of
            echo -> bench_load:echo(Port, Run);
            churn -> bench_load:churn(Port, Run)
        end}
    end),
    timer:sleep(1500),
    Out = bench_peer:call(Peer, ?MODULE, profile,
                          [maps:get(type, Opts), Secs * 1000, maps:get(top, Opts)], 600000),
    Metrics = receive {load, M} -> M end,
    unlink(Load),
    io:format("~s ~s: ~.1f ops/s while profiling (profiler overhead included)~n~n~s",
              [Impl, RowId, maps:get(msgs_per_s, Metrics, 0.0), Out]),
    bench_peer:call(Peer, bench_node, stop_server, [5000]),
    bench_peer:stop(Peer),
    halt(0).

parse(["--impl", I | T], O) -> parse(T, O#{impl => list_to_atom(I)});
parse(["--row", R | T], O) -> parse(T, O#{row => R});
parse(["--seconds", N | T], O) -> parse(T, O#{seconds => list_to_integer(N)});
parse(["--top", N | T], O) -> parse(T, O#{top => list_to_integer(N)});
parse(["--type", Ty | T], O) -> parse(T, O#{type => list_to_atom(Ty)});
parse([], O) -> O;
parse([X | _], _) -> error({unknown_argument, X}).

%% Runs in the server peer. Traces every process for `Ms` with the call
%% time (or call count) breakpoints and answers the report as an iolist.
%%
%% This reads the counters with `erlang:trace_info/2` and lists functions
%% with `erlang:get_module_info/2` rather than using `tprof` or `eprof`:
%% those call `M:module_info(functions)`, which Beamtalk-compiled modules
%% do not export, and crash.
profile(Type, Ms, Top) ->
    Flag = case Type of call_time -> call_time; call_count -> call_count end,
    erlang:trace_pattern({'_', '_', '_'}, true, [local, Flag]),
    erlang:trace(all, true, [call]),
    timer:sleep(Ms),
    erlang:trace(all, false, [call]),
    erlang:trace_pattern({'_', '_', '_'}, pause, [local, Flag]),
    Rows = lists:append([module_rows(M, Flag) || {M, _} <- code:all_loaded()]),
    erlang:trace_pattern({'_', '_', '_'}, false, [local, Flag]),
    Total = lists:sum([V || {V, _, _} <- Rows]),
    ByFun = lists:reverse(lists:keysort(1, Rows)),
    ByMod = lists:reverse(lists:keysort(2, maps:to_list(lists:foldl(fun({V, {M, _, _}, _}, Acc) ->
        maps:update_with(M, fun(X) -> X + V end, V, Acc)
    end, #{}, Rows)))),
    Unit = case Type of call_time -> "us"; call_count -> "calls" end,
    [io_lib:format("total ~p ~s over ~p ms~n~nTop functions (own time):~n", [Total, Unit, Ms]),
     [io_lib:format("~6.2f%  ~12w ~s ~10w calls  ~p~n",
                    [pct(V, Total), V, Unit, C, MFA]) || {V, MFA, C} <- lists:sublist(ByFun, Top)],
     io_lib:format("~nBy module:~n", []),
     [io_lib:format("~6.2f%  ~12w ~s  ~p~n", [pct(V, Total), V, Unit, M])
      || {M, V} <- lists:sublist(ByMod, Top)]].

%% {Value, MFA, Calls} for every function of M that was called.
module_rows(M, Flag) ->
    Funs = try erlang:get_module_info(M, functions) catch _:_ -> [] end,
    [{V, {M, F, A}, C} || {F, A} <- Funs, {V, C} <- [read(M, F, A, Flag)], C > 0].

read(M, F, A, call_time) ->
    case erlang:trace_info({M, F, A}, call_time) of
        {call_time, L} when is_list(L) ->
            lists:foldl(fun({_Pid, C, S, Us}, {V, N}) -> {V + S * 1000000 + Us, N + C} end, {0, 0}, L);
        _ -> {0, 0}
    end;
read(M, F, A, call_count) ->
    case erlang:trace_info({M, F, A}, call_count) of
        {call_count, C} when is_integer(C) -> {C, C};
        _ -> {0, 0}
    end.

pct(_, 0) -> 0.0;
pct(V, T) -> 100 * V / T.
