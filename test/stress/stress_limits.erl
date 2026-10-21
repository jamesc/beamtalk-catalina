%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Connection limits. With one acceptor and `num_connections` 5, a
%% sixth connection is accepted by the kernel, then held while the acceptor
%% retries (`max_connections_retry_count` x `max_connections_retry_wait`)
%% and closed unserved; if a slot frees up during the retries it is served
%% instead (it queues); and the server recovers once connections close.
%% Run against both servers with the same expectations.
-module(stress_limits).

-export([tests/0]).

-define(LIMIT, 5).
-define(RETRIES, 3).
-define(WAIT, 200).

tests() ->
    [{"limits_refuse_over_max", [catalina, ti], fun refuse/1},
     {"limits_queue_until_free", [catalina, ti], fun queue/1},
     {"limits_recover_under_load", [catalina, ti], fun recover/1}].

opts() ->
    #{num_acceptors => 1, num_connections => ?LIMIT,
      max_connections_retry_count => ?RETRIES, max_connections_retry_wait => ?WAIT}.

fill(Port) ->
    [begin {ok, C} = bench_conn:connect(Port, false), ok = stress_lib:echo_once(C, <<"held">>), C end
     || _ <- lists:seq(1, ?LIMIT)].

%% The extra connection is closed without being served, after about the
%% retry window.
refuse(Ctx) ->
    stress_lib:with_server(Ctx, opts(), fun(Port) ->
        Held = fill(Port),
        T0 = erlang:monotonic_time(millisecond),
        {ok, Extra} = bench_conn:connect(Port, false),
        ok = bench_conn:send(Extra, <<"over">>),
        Outcome = bench_conn:recv(Extra, 0, 5000),
        Ms = stress_lib:elapsed_ms(T0),
        stress_lib:check(lists:member(Outcome, [{error, closed}, {error, econnreset}]),
                         "the connection over the limit is closed unserved", Outcome),
        Window = ?RETRIES * ?WAIT,
        stress_lib:check(Ms >= Window - 50 andalso Ms =< Window + 1500,
                         "closed after the retry window", {Ms, Window}),
        %% The held connections still work.
        [ok = stress_lib:echo_once(C, <<"still">>) || C <- Held],
        [bench_conn:close(C) || C <- Held],
        #{closed_after_ms => Ms, outcome => Outcome}
    end).

%% A slot that frees up during the retries serves the waiting connection.
queue(Ctx) ->
    stress_lib:with_server(Ctx, opts(), fun(Port) ->
        [First | Held] = fill(Port),
        {ok, Extra} = bench_conn:connect(Port, false),
        ok = bench_conn:send(Extra, <<"queued">>),
        timer:sleep(?WAIT div 2),
        T0 = erlang:monotonic_time(millisecond),
        bench_conn:close(First),
        Outcome = stress_lib:recv_all(Extra, 6, 5000),
        Ms = stress_lib:elapsed_ms(T0),
        stress_lib:check(Outcome =:= {ok, <<"queued">>}, "the waiting connection is served", Outcome),
        [bench_conn:close(C) || C <- [Extra | Held]],
        #{served_after_close_ms => Ms}
    end).

%% Hammer the full server with connection attempts, then close everything:
%% it serves a full set of connections again.
recover(Ctx) ->
    Attempts = stress_lib:pick(Ctx, {10, 30}),
    stress_lib:with_server(Ctx, opts(), fun(Port) ->
        Held = fill(Port),
        Self = self(),
        Pids = [spawn_link(fun() ->
                    Self ! {tried, self(), case bench_conn:connect(Port, false) of
                        {ok, C} ->
                            R = stress_lib:echo_once(C, <<"x">>, 10000),
                            bench_conn:abort(C),
                            R;
                        E -> E
                    end}
                end) || _ <- lists:seq(1, Attempts)],
        Refused = [receive {tried, P, R} -> R after 120000 -> timeout end || P <- Pids],
        Served = length([ok || ok <- Refused]),
        [bench_conn:close(C) || C <- Held],
        stress_lib:wait_until(fun() -> stress_lib:node_call(Ctx, connection_count, []) =:= 0 end,
                              10000, connections_closed),
        Again = fill(Port),
        [bench_conn:close(C) || C <- Again],
        stress_lib:check(Served =:= 0, "no attempt is served while the server is full", Served),
        #{attempts => Attempts, refused => length(Refused) - Served}
    end).
