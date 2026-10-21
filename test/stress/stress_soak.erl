%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Soak: mixed load for `--soak-minutes` (30 by default, 1 with
%% `--smoke`): persistent echo clients with payloads up to 64 KiB, churning
%% clients, a TLS churner, TLS echo clients and a pool of idle connections,
%% all checked byte for byte. The server node is sampled throughout.
%%
%% Passes when there are no corrupted bytes or client errors, the process
%% count and memory do not grow (the last third of the samples against the
%% first third, after a warm-up sample), and once the load stops the
%% process, port and ETS counts return to the baseline taken before it.
-module(stress_soak).

-export([tests/0]).

-define(KEYS, [processes, ports, ets]).

tests() ->
    [{"soak_mixed_load", [catalina], fun soak/1}].

soak(Ctx = #{soak_minutes := Minutes}) ->
    Ms = round(Minutes * 60000),
    Interval = max(1000, min(10000, Ms div 30)),
    stress_lib:with_server(Ctx, #{}, fun(Port) ->
        {ok, _} = stress_leak:churn(Port, 200, 16, false),
        Base = stress_lib:settle(Ctx, ?KEYS),
        %% A second, TLS server on the same node for the TLS share of the load.
        {ok, TlsPort} = stress_lib:node_call(Ctx, start_server, [#{name => tls, port => 0, tls => true}]),
        try
            stress_lib:ready(TlsPort, #{tls => true}),
            Idle = bench_load:open_idle(Port, stress_lib:pick(Ctx, {200, 1000}), false),
            Load = start(Port, TlsPort),
            Samples = sample(Ctx, erlang:monotonic_time(millisecond) + Ms, Interval, []),
            Errors = stop(Load),
            bench_load:close_idle(Idle),
            stress_lib:node_call(Ctx, stop_server, [tls, 10000]),
            stress_lib:wait_until(fun() -> stress_lib:node_call(Ctx, connection_count, []) =:= 0 end,
                                  60000, connections_closed),
            After = stress_lib:settle(Ctx, ?KEYS),
            judge(Base, After, Samples, Errors, Minutes)
        after
            stress_lib:node_call(Ctx, stop_server, [tls, 10000])
        end
    end).

judge(Base, After, Samples, Errors, Minutes) ->
    Ok = maps:get(ok, Errors, 0),
    Bad = maps:without([ok], Errors),
    stress_lib:check(Ok > 0, "the load ran", Errors),
    stress_lib:check(Bad =:= #{}, "no client errors or corrupted bytes", Bad),
    Steady = tl(lists:reverse(Samples)),
    Third = max(1, length(Steady) div 3),
    First = lists:sublist(Steady, Third),
    Last = lists:nthtail(length(Steady) - Third, Steady),
    Avg = fun(K, L) -> lists:sum([maps:get(K, S) || S <- L]) / length(L) end,
    Max = fun(K, L) -> lists:max([maps:get(K, S) || S <- L]) end,
    ProcGrowth = Max(processes, Last) - Max(processes, First),
    MemFirst = Avg(memory, First),
    MemLast = Avg(memory, Last),
    stress_lib:check(ProcGrowth =< 50, "process count does not grow", {Max(processes, First), Max(processes, Last)}),
    stress_lib:check(MemLast =< MemFirst * 1.10 + 16 * 1048576, "memory does not grow",
                     {round(MemFirst), round(MemLast)}),
    Diff = maps:from_list([{K, {maps:get(K, Base), maps:get(K, After)}}
                           || K <- ?KEYS, maps:get(K, Base) =/= maps:get(K, After)]),
    stress_lib:check(Diff =:= #{}, "processes, ports and ETS back to baseline", Diff),
    #{minutes => Minutes, samples => length(Samples), echoes => Ok,
      processes_first_last => {Max(processes, First), Max(processes, Last)},
      memory_mib_first_last => {round(MemFirst / 1048576), round(MemLast / 1048576)}}.

sample(Ctx, Deadline, Interval, Acc) ->
    S = stress_lib:stats(Ctx),
    Acc1 = [S | Acc],
    case erlang:monotonic_time(millisecond) + Interval > Deadline of
        true -> Acc1;
        false ->
            timer:sleep(Interval),
            sample(Ctx, Deadline, Interval, Acc1)
    end.

%% === Load ===

start(Port, TlsPort) ->
    Stop = atomics:new(1, []),
    Self = self(),
    Spawn = fun(F) -> spawn_link(fun() -> Self ! {soak, self(), F()} end) end,
    Pids = [Spawn(fun() -> persistent(Port, false, Stop, 65536, #{}) end) || _ <- lists:seq(1, 16)]
        ++ [Spawn(fun() -> persistent(Port, false, Stop, 512, #{}) end) || _ <- lists:seq(1, 16)]
        ++ [Spawn(fun() -> churn(Port, false, Stop, #{}) end) || _ <- lists:seq(1, 4)]
        ++ [Spawn(fun() -> persistent(TlsPort, true, Stop, 16384, #{}) end) || _ <- lists:seq(1, 4)]
        ++ [Spawn(fun() -> churn(TlsPort, true, Stop, #{}) end)],
    {Stop, Pids}.

stop({Stop, Pids}) ->
    atomics:put(Stop, 1, 1),
    Results = [receive {soak, P, R} -> R after 120000 -> #{stuck => 1} end || P <- Pids],
    lists:foldl(fun(M, Acc) ->
        maps:fold(fun(K, V, A) -> maps:update_with(K, fun(X) -> X + V end, V, A) end, Acc, M)
    end, #{}, Results).

persistent(Port, Tls, Stop, MaxSize, Acc) ->
    {ok, C} = bench_conn:connect(Port, Tls),
    persistent_loop(C, Stop, MaxSize, Acc).

persistent_loop(C, Stop, MaxSize, Acc) ->
    case atomics:get(Stop, 1) of
        1 ->
            bench_conn:close(C),
            Acc;
        0 ->
            R = stress_lib:echo_once(C, rand:bytes(rand:uniform(MaxSize))),
            persistent_loop(C, Stop, MaxSize, bump(R, Acc))
    end.

churn(Port, Tls, Stop, Acc) ->
    case atomics:get(Stop, 1) of
        1 -> Acc;
        0 ->
            R = case bench_conn:connect(Port, Tls) of
                {ok, C} ->
                    E = stress_lib:echo_once(C, rand:bytes(64)),
                    bench_conn:abort(C),
                    E;
                Error -> {connect, Error}
            end,
            churn(Port, Tls, Stop, bump(R, Acc))
    end.

bump(K, M) -> maps:update_with(K, fun(X) -> X + 1 end, 1, M).
