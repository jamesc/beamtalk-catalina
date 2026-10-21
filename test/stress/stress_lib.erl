%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Helpers shared by the stress tests (`just stress`, see
%% `stress_main`). A test gets a context map:
%%
%%   impl   catalina | ti
%%   peer   the server peer node (`bench_peer`)
%%   size   smoke | full
%%   soak_minutes
-module(stress_lib).

-export([
    with_server/3,
    ready/2,
    node_call/3,
    stats/1,
    settle/2,
    wait_until/3,
    check/2,
    check/3,
    pick/2,
    free_port/0,
    echo_once/2,
    echo_once/3,
    recv_all/3,
    elapsed_ms/1,
    check_ets_rows/3,
    log/2
]).

%% Start a server with `Opts`, run `Fun(Port)`, and stop it whatever happens.
with_server(Ctx, Opts, Fun) ->
    {ok, Port} = node_call(Ctx, start_server, [maps:merge(#{port => 0}, Opts)]),
    try
        ready(Port, Opts),
        Fun(Port)
    after
        node_call(Ctx, stop_server, [10000])
    end.

%% Wait until a server just started is accepting and serving.
ready(Port, Opts) ->
    bench_load:wait_ready(Port, maps:get(tls, Opts, false), 120000).

node_call(#{peer := Peer}, F, A) -> bench_peer:call(Peer, bench_node, F, A).

stats(Ctx) -> node_call(Ctx, stats, []).

%% Node stats once the server is quiet: after garbage collection, and once
%% the process count has stopped changing.
settle(Ctx, Keys) ->
    settle(Ctx, Keys, undefined, 20).

settle(Ctx, Keys, Prev, Tries) ->
    node_call(Ctx, gc_all, []),
    timer:sleep(250),
    S = stats(Ctx),
    Now = maps:with(Keys, S),
    case Now =:= Prev orelse Tries =:= 0 of
        true -> S;
        false -> settle(Ctx, Keys, Now, Tries - 1)
    end.

%% Poll `Fun` until it answers true, or fail with `What` after `Ms`.
wait_until(Fun, Ms, What) ->
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    wait_loop(Fun, Deadline, What).

wait_loop(Fun, Deadline, What) ->
    case Fun() of
        true -> ok;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> error({timed_out_waiting_for, What});
                false ->
                    timer:sleep(50),
                    wait_loop(Fun, Deadline, What)
            end
    end.

%% Fail the test with `What` unless `Cond`.
check(Cond, What) -> check(Cond, What, []).

check(true, _What, _Detail) -> ok;
check(_, What, Detail) -> error({check_failed, What, Detail}).

%% Smoke and full sizes of a parameter.
pick(#{size := smoke}, {Smoke, _Full}) -> Smoke;
pick(#{size := full}, {_Smoke, Full}) -> Full.

%% A port that is free right now (for tests that must reconnect to the same
%% port after `resume`).
free_port() ->
    {ok, L} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, P} = inet:port(L),
    gen_tcp:close(L),
    P.

%% Timeouts here only detect hangs: the stress tests check behaviour, not
%% speed, and a loaded machine can be very slow.
echo_once(C, Data) -> echo_once(C, Data, 60000).

%% Send Data and read back exactly as many bytes; answers ok or the reason.
echo_once(C, Data, Timeout) ->
    case bench_conn:send(C, Data) of
        ok ->
            case recv_all(C, byte_size(Data), Timeout) of
                {ok, Data} -> ok;
                {ok, Other} -> {mismatch, byte_size(Other)};
                Error -> Error
            end;
        Error ->
            Error
    end.

%% Exactly N bytes (N >= 0), gathered from as many reads as it takes.
recv_all(_C, 0, _Timeout) -> {ok, <<>>};
recv_all(C, N, Timeout) -> recv_all(C, N, Timeout, []).

recv_all(_C, 0, _Timeout, Acc) -> {ok, iolist_to_binary(lists:reverse(Acc))};
recv_all(C, N, Timeout, Acc) ->
    case bench_conn:recv(C, 0, Timeout) of
        {ok, B} when byte_size(B) =< N -> recv_all(C, N - byte_size(B), Timeout, [B | Acc]);
        {ok, B} -> {ok, iolist_to_binary(lists:reverse([B | Acc]))};
        Error -> Error
    end.

%% ETS rows may move a little (timers, caches), but must not grow with the
%% work done: allow one row per 100 units of `Work` (connections, say).
check_ets_rows(Base, After, Work) ->
    Grown = maps:get(ets_rows, After) - maps:get(ets_rows, Base),
    check(Grown =< max(20, Work div 100), "ETS rows do not grow with the load",
          #{base => maps:get(ets_rows, Base), now => maps:get(ets_rows, After), work => Work}).

elapsed_ms(T0) -> erlang:monotonic_time(millisecond) - T0.

log(F, A) -> io:format(standard_error, "    " ++ F ++ "~n", A).
