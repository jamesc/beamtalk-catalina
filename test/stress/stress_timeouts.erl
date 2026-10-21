%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Read timeouts and half-close, against both servers with the same
%% expectations.
%%
%% Slow-loris: a connection that sends nothing, or trickles bytes further
%% apart than `read_timeout`, is closed by the read timeout; many of them at
%% once are all closed, and the server keeps serving meanwhile. As in
%% Thousand Island the timeout is per read, so bytes arriving more often
%% than `read_timeout` keep a connection open; that case is pinned too.
%%
%% Half-close: a client that shuts down its write side gets the echo of
%% what it sent before, then the server closes the connection.
-module(stress_timeouts).

-export([tests/0]).

-define(READ_TIMEOUT, 400).

tests() ->
    [{"timeout_idle", [catalina, ti], fun idle/1},
     {"timeout_trickle_slow", [catalina, ti], fun trickle_slow/1},
     {"timeout_trickle_fast", [catalina, ti], fun trickle_fast/1},
     {"timeout_slowloris_under_load", [catalina, ti], fun slowloris/1},
     {"half_close", [catalina, ti], fun half_close/1}].

opts() -> #{read_timeout => ?READ_TIMEOUT}.

%% How long until the server closes C, reading and discarding echoes.
closed_after(C, T0) ->
    case bench_conn:recv(C, 0, 10000) of
        {ok, _} -> closed_after(C, T0);
        {error, R} when R =:= closed; R =:= econnreset -> {closed, stress_lib:elapsed_ms(T0)};
        Other -> {not_closed, Other}
    end.

check_window(What, {closed, Ms}, Low, High) ->
    stress_lib:check(Ms >= Low andalso Ms =< High, What, {Ms, Low, High}),
    Ms;
check_window(What, Other, _, _) ->
    stress_lib:check(false, What, Other).

idle(Ctx) ->
    stress_lib:with_server(Ctx, opts(), fun(Port) ->
        {ok, C} = bench_conn:connect(Port, false),
        Silent = check_window("an idle connection closes after read_timeout",
                              closed_after(C, erlang:monotonic_time(millisecond)),
                              ?READ_TIMEOUT - 50, ?READ_TIMEOUT + 1000),
        {ok, C2} = bench_conn:connect(Port, false),
        ok = stress_lib:echo_once(C2, <<"hello">>),
        AfterData = check_window("idle after data closes after read_timeout",
                                 closed_after(C2, erlang:monotonic_time(millisecond)),
                                 ?READ_TIMEOUT - 50, ?READ_TIMEOUT + 1000),
        #{silent_ms => Silent, after_data_ms => AfterData}
    end).

%% A byte every 1.5 x read_timeout: closed after the first gap.
trickle_slow(Ctx) ->
    stress_lib:with_server(Ctx, opts(), fun(Port) ->
        {ok, C} = bench_conn:connect(Port, false),
        ok = stress_lib:echo_once(C, <<"a">>),
        T0 = erlang:monotonic_time(millisecond),
        timer:sleep(?READ_TIMEOUT * 3 div 2),
        _ = bench_conn:send(C, <<"b">>),
        Outcome = bench_conn:recv(C, 0, 2000),
        stress_lib:check(lists:member(Outcome, [{error, closed}, {error, econnreset}]),
                         "the late byte is not echoed: the connection was closed", Outcome),
        #{closed_within_ms => stress_lib:elapsed_ms(T0)}
    end).

%% A byte every read_timeout / 4 for several timeouts' worth: stays open,
%% then closes once the bytes stop.
trickle_fast(Ctx) ->
    stress_lib:with_server(Ctx, opts(), fun(Port) ->
        {ok, C} = bench_conn:connect(Port, false),
        Steps = 12,
        [begin
            timer:sleep(?READ_TIMEOUT div 4),
            ok = stress_lib:echo_once(C, <<"t">>)
         end || _ <- lists:seq(1, Steps)],
        Ms = check_window("closes once the bytes stop",
                          closed_after(C, erlang:monotonic_time(millisecond)),
                          ?READ_TIMEOUT - 50, ?READ_TIMEOUT + 1000),
        #{open_for_ms => Steps * ?READ_TIMEOUT div 4, then_closed_ms => Ms}
    end).

%% Many idle and trickling connections at once, while echo clients keep
%% working: all the slow ones are closed, and echo carries on.
slowloris(Ctx) ->
    N = stress_lib:pick(Ctx, {50, 500}),
    stress_lib:with_server(Ctx, opts(), fun(Port) ->
        Self = self(),
        Slow = [spawn_link(fun() ->
                    {ok, C} = bench_conn:connect(Port, false),
                    T0 = erlang:monotonic_time(millisecond),
                    case I rem 2 of
                        0 -> ok;
                        1 -> _ = bench_conn:send(C, <<"x">>)
                    end,
                    Self ! {slow, self(), closed_after(C, T0)}
                end) || I <- lists:seq(1, N)],
        Stop = atomics:new(1, []),
        Echoers = [spawn_link(fun() -> Self ! {echoed, self(), echo_until(Port, Stop, 0)} end)
                   || _ <- lists:seq(1, 4)],
        Closed = [receive {slow, P, R} -> R after 30000 -> timeout end || P <- Slow],
        atomics:put(Stop, 1, 1),
        Echoed = [receive {echoed, P, R} -> R after 30000 -> timeout end || P <- Echoers],
        NotClosed = [R || R <- Closed, element(1, R) =/= closed],
        stress_lib:check(NotClosed =:= [], "every slow connection is closed", NotClosed),
        Late = [Ms || {closed, Ms} <- Closed, Ms > ?READ_TIMEOUT + 5000],
        stress_lib:check(Late =:= [], "closed within read_timeout + 5 s", Late),
        stress_lib:check(lists:all(fun(E) -> is_integer(E) andalso E > 0 end, Echoed),
                         "echo clients kept working", Echoed),
        Ms = [M || {closed, M} <- Closed],
        #{slow => N, max_close_ms => lists:max(Ms), echoes => lists:sum(Echoed)}
    end).

%% Echo on a fresh connection until told to stop; each connection does a
%% few round trips (well inside read_timeout) and closes.
echo_until(Port, Stop, Count) ->
    case atomics:get(Stop, 1) of
        1 -> Count;
        0 ->
            {ok, C} = bench_conn:connect(Port, false),
            ok = stress_lib:echo_once(C, <<"ping">>),
            bench_conn:abort(C),
            echo_until(Port, Stop, Count + 1)
    end.

half_close(Ctx) ->
    stress_lib:with_server(Ctx, opts(), fun(Port) ->
        %% Data, then shut down the write side: the echo arrives, then the
        %% server closes.
        {ok, C} = bench_conn:connect(Port, false),
        ok = bench_conn:send(C, <<"hello">>),
        timer:sleep(50),
        ok = bench_conn:shutdown_write(C),
        Got = stress_lib:recv_all(C, 5, 2000),
        After = bench_conn:recv(C, 0, 2000),
        bench_conn:close(C),
        stress_lib:check(Got =:= {ok, <<"hello">>}, "data sent before the half-close is echoed", Got),
        stress_lib:check(After =:= {error, closed}, "then the server closes", After),
        %% Shut down at once, without data: the server closes.
        {ok, C2} = bench_conn:connect(Port, false),
        ok = bench_conn:shutdown_write(C2),
        T0 = erlang:monotonic_time(millisecond),
        Bare = bench_conn:recv(C2, 0, 2000),
        Ms = stress_lib:elapsed_ms(T0),
        bench_conn:close(C2),
        stress_lib:check(Bare =:= {error, closed}, "a bare half-close is closed by the server", Bare),
        stress_lib:check(Ms < ?READ_TIMEOUT, "closed by the half-close, not the read timeout", Ms),
        #{bare_close_ms => Ms}
    end).
