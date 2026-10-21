%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Leak check: after thousands of connection-churn cycles (clean
%% closes, resets, connect-and-close without data, closes mid-echo), the
%% server node's process count, port count, ETS tables and the connection
%% supervisors' child count return to their baseline. A server's whole
%% start/stop lifecycle must leave nothing behind either.
-module(stress_leak).

-export([tests/0, churn/4]).

-define(KEYS, [processes, ports, ets]).

tests() ->
    [{"leak_churn", [catalina, ti], fun churn_leak/1},
     {"leak_server_lifecycle", [catalina, ti], fun lifecycle_leak/1}].

churn_leak(Ctx) ->
    Cycles = stress_lib:pick(Ctx, {1000, 10000}),
    stress_lib:with_server(Ctx, #{}, fun(Port) ->
        %% Warm up, so lazily created processes and tables exist before the
        %% baseline.
        {ok, _} = churn(Port, 200, 16, false),
        Base = baseline(Ctx),
        T0 = erlang:monotonic_time(millisecond),
        {ok, Kinds} = churn(Port, Cycles, 32, false),
        Ms = stress_lib:elapsed_ms(T0),
        After = back_to(Ctx, Base),
        stress_lib:check_ets_rows(Base, After, Cycles),
        #{cycles => Cycles, seconds => Ms / 1000, kinds => Kinds,
          processes => maps:get(processes, After), ports => maps:get(ports, After),
          ets => maps:get(ets, After)}
    end).

%% Start and stop servers (TCP and TLS, each with live connections at stop
%% time) and check the node is back where it started.
lifecycle_leak(Ctx) ->
    Rounds = stress_lib:pick(Ctx, {3, 10}),
    Once = fun() ->
        [stress_lib:with_server(Ctx, #{tls => Tls}, fun(Port) ->
            Conns = [begin {ok, C} = bench_conn:connect(Port, Tls), ok = stress_lib:echo_once(C, <<"x">>), C end
                     || _ <- lists:seq(1, 20)],
            {ok, _} = churn(Port, 50, 8, Tls),
            %% The server stops with these still open.
            self() ! {close_later, Conns}
        end) || Tls <- [false, true]],
        receive_close()
    end,
    Once(),
    Base = stress_lib:settle(Ctx, ?KEYS),
    [Once() || _ <- lists:seq(1, Rounds)],
    After = stress_lib:settle(Ctx, ?KEYS),
    Diff = diff(Base, After),
    stress_lib:check(Diff =:= #{}, "node back to baseline after server lifecycles", Diff),
    stress_lib:check_ets_rows(Base, After, Rounds * 2 * 70),
    #{rounds => Rounds, processes => maps:get(processes, After)}.

receive_close() ->
    receive
        {close_later, Conns} -> [bench_conn:close(C) || C <- Conns], receive_close()
    after 0 -> ok
    end.

baseline(Ctx) ->
    stress_lib:wait_until(fun() -> stress_lib:node_call(Ctx, connection_count, []) =:= 0 end,
                          10000, no_connections),
    stress_lib:settle(Ctx, ?KEYS).

%% Wait for every handler to finish, then compare with the baseline.
back_to(Ctx, Base) ->
    stress_lib:wait_until(fun() -> stress_lib:node_call(Ctx, connection_count, []) =:= 0 end,
                          60000, connection_supervisors_empty),
    After = stress_lib:settle(Ctx, ?KEYS),
    Diff = diff(Base, After),
    stress_lib:check(Diff =:= #{}, "processes, ports and ETS tables back to baseline", Diff),
    Acceptors = stress_lib:node_call(Ctx, acceptors, []),
    stress_lib:check(length(Acceptors) =:= 100, "every acceptor still running", length(Acceptors)),
    After.

diff(Base, After) ->
    maps:from_list([{K, {maps:get(K, Base), maps:get(K, After)}}
                    || K <- ?KEYS, maps:get(K, Base) =/= maps:get(K, After)]).

%% `Cycles` connection cycles over `Workers` processes, mixing how each one
%% ends. Answers {ok, CountsByKind} or {error, Reasons}.
churn(Port, Cycles, Workers, Tls) ->
    Counter = atomics:new(1, []),
    Self = self(),
    Pids = [spawn_link(fun() -> Self ! {churned, self(), churn_loop(Port, Tls, Counter, Cycles, #{})} end)
            || _ <- lists:seq(1, Workers)],
    Results = [receive {churned, P, R} -> R after 600000 -> #{timeout => 1} end || P <- Pids],
    Merged = lists:foldl(fun(M, Acc) ->
        maps:fold(fun(K, V, A) -> maps:update_with(K, fun(X) -> X + V end, V, A) end, Acc, M)
    end, #{}, Results),
    case maps:filter(fun(K, _) -> is_tuple(K) orelse K =:= timeout end, Merged) of
        Errors when map_size(Errors) =:= 0 -> {ok, Merged};
        Errors -> error({churn_errors, Errors})
    end.

churn_loop(Port, Tls, Counter, Cycles, Acc) ->
    case atomics:add_get(Counter, 1, 1) > Cycles of
        true -> Acc;
        false ->
            Kind = case rand:uniform(10) of
                1 -> clean_close;
                2 -> no_data;
                3 -> mid_echo;
                _ -> reset
            end,
            Outcome = cycle(Port, Tls, Kind),
            Key = case Outcome of ok -> Kind; Error -> {Kind, Error} end,
            churn_loop(Port, Tls, Counter, Cycles, maps:update_with(Key, fun(X) -> X + 1 end, 1, Acc))
    end.

cycle(Port, Tls, Kind) ->
    case bench_conn:connect(Port, Tls) of
        {ok, C} ->
            R = case Kind of
                no_data -> ok;
                mid_echo -> bench_conn:send(C, rand:bytes(32768));
                _ -> stress_lib:echo_once(C, rand:bytes(64))
            end,
            case Kind of
                clean_close -> bench_conn:close(C);
                _ -> bench_conn:abort(C)
            end,
            R;
        {error, R} ->
            {connect, R}
    end.
