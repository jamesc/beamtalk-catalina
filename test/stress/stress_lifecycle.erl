%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Lifecycle under load, against both servers with the same
%% expectations.
%%
%% - suspend/resume: while suspended, existing connections keep echoing and
%%   new connections are refused; after resume, new connections are served
%%   on the same port.
%% - graceful stop: handlers in the middle of a callback finish it (the
%%   client gets its echo) before closing, when that fits in
%%   `shutdown_timeout`; idle connections close at once; `stop` returns
%%   when they are done.
%% - stop past the deadline: handlers still busy at `shutdown_timeout` are
%%   killed, unanswered, and `stop` returns at about the deadline.
%%
%% The stop tests use one acceptor, so every connection is under one
%% connection supervisor. With several, `stop` takes up to
%% `shutdown_timeout` per connection supervisor that has a busy handler: the
%% acceptor pool stops its acceptor supervisors one at a time, as OTP
%% supervisors do (Thousand Island behaves the same way).
-module(stress_lifecycle).

-export([tests/0]).

tests() ->
    [{"lifecycle_suspend_resume", [catalina, ti], fun suspend_resume/1},
     {"lifecycle_stop_drains", [catalina, ti], fun stop_drains/1},
     {"lifecycle_stop_kills_at_deadline", [catalina, ti], fun stop_deadline/1}].

suspend_resume(Ctx) ->
    Port = stress_lib:free_port(),
    stress_lib:with_server(Ctx, #{port => Port}, fun(_) ->
        Stop = atomics:new(1, []),
        Self = self(),
        Workers = [spawn_link(fun() ->
                       {ok, C} = bench_conn:connect(Port, false),
                       ok = stress_lib:echo_once(C, <<"first">>, 60000),
                       Self ! {connected, self()},
                       Self ! {worker, self(), echo_until(C, Stop, #{})}
                   end) || _ <- lists:seq(1, 20)],
        [receive {connected, P} -> ok end || P <- Workers],
        timer:sleep(300),
        ok = stress_lib:node_call(Ctx, suspend, []),
        Suspended = stress_lib:node_call(Ctx, connection_count, []),
        Refused = [bench_conn:connect(Port, false, [], 1) || _ <- lists:seq(1, 5)],
        Before = echo_total(Workers),
        timer:sleep(500),
        During = echo_total(Workers) - Before,
        ok = stress_lib:node_call(Ctx, resume, []),
        {ok, New} = bench_conn:connect(Port, false),
        NewEcho = stress_lib:echo_once(New, <<"after resume">>),
        bench_conn:close(New),
        atomics:put(Stop, 1, 1),
        Results = [receive {worker, P, R} -> R after 30000 -> #{stuck => 1} end || P <- Workers],
        Errors = [R || R <- Results, maps:without([ok], R) =/= #{}],
        stress_lib:check(Suspended =:= 20, "suspend keeps existing connections", Suspended),
        stress_lib:check(lists:all(fun(R) -> R =:= {error, econnrefused} end, Refused),
                         "new connections are refused while suspended", Refused),
        stress_lib:check(During > 0, "existing connections keep echoing while suspended", During),
        stress_lib:check(NewEcho =:= ok, "a new connection is served after resume", NewEcho),
        stress_lib:check(Errors =:= [], "no errors on the existing connections", Errors),
        #{echoes_while_suspended => During}
    end).

echo_until(C, Stop, Acc) ->
    case atomics:get(Stop, 1) of
        1 ->
            bench_conn:close(C),
            Acc;
        0 ->
            K = case stress_lib:echo_once(C, rand:bytes(256)) of
                ok -> ok;
                Other -> Other
            end,
            Acc1 = maps:update_with(K, fun(X) -> X + 1 end, 1, Acc),
            put(echoes, maps:get(ok, Acc1, 0)),
            echo_until(C, Stop, Acc1)
    end.

echo_total(Pids) ->
    lists:sum([case erlang:process_info(P, dictionary) of
                   {dictionary, D} -> proplists:get_value(echoes, D, 0);
                   _ -> 0
               end || P <- Pids]).

%% Busy handlers (sleeping 400 ms in handle_data) and idle ones, then stop
%% with a 2 s shutdown_timeout: the busy ones answer, everyone is closed,
%% and stop takes about as long as the longest callback.
stop_drains(Ctx) ->
    Sleep = 400,
    {ok, Port} = stress_lib:node_call(Ctx, start_server, [#{
        port => 0, num_acceptors => 1, handler => slow_echo, handler_options => Sleep,
        shutdown_timeout => 2000}]),
    stress_lib:ready(Port, #{}),
    Busy = [connect(Port) || _ <- lists:seq(1, 10)],
    Idle = [connect(Port) || _ <- lists:seq(1, 10)],
    stress_lib:wait_until(fun() -> stress_lib:node_call(Ctx, connection_count, []) >= 20 end,
                          10000, all_connected),
    Self = self(),
    Readers = [spawn_link(fun() ->
                   ok = bench_conn:send(C, <<"in flight">>),
                   Self ! {busy, self(), {stress_lib:recv_all(C, 9, 5000), bench_conn:recv(C, 0, 5000)}}
               end) || C <- Busy],
    timer:sleep(100),
    T0 = erlang:monotonic_time(millisecond),
    {StopResult, _} = stress_lib:node_call(Ctx, stop_server, [10000]),
    StopMs = stress_lib:elapsed_ms(T0),
    BusyOutcomes = [receive {busy, P, R} -> R after 10000 -> timeout end || P <- Readers],
    IdleOutcomes = [bench_conn:recv(C, 0, 2000) || C <- Idle],
    [bench_conn:close(C) || C <- Busy ++ Idle],
    stress_lib:check(StopResult =:= ok, "stop succeeds", StopResult),
    stress_lib:check(lists:all(fun(O) -> O =:= {{ok, <<"in flight">>}, {error, closed}} end, BusyOutcomes),
                     "in-flight callbacks finish and answer, then close", BusyOutcomes),
    stress_lib:check(lists:all(fun(O) -> O =:= {error, closed} end, IdleOutcomes),
                     "idle connections are closed", IdleOutcomes),
    stress_lib:check(StopMs >= Sleep - 150 andalso StopMs < 2000,
                     "stop waits for the callbacks, not the whole shutdown_timeout", StopMs),
    #{stop_ms => StopMs}.

%% Handlers sleeping 5 s, shutdown_timeout 500 ms: killed at the deadline
%% without answering.
stop_deadline(Ctx) ->
    {ok, Port} = stress_lib:node_call(Ctx, start_server, [#{
        port => 0, num_acceptors => 1, handler => slow_echo, handler_options => 5000,
        shutdown_timeout => 500}]),
    stress_lib:ready(Port, #{}),
    Busy = [connect(Port) || _ <- lists:seq(1, 10)],
    stress_lib:wait_until(fun() -> stress_lib:node_call(Ctx, connection_count, []) >= 10 end,
                          10000, all_connected),
    [ok = bench_conn:send(C, <<"too slow">>) || C <- Busy],
    timer:sleep(100),
    T0 = erlang:monotonic_time(millisecond),
    {StopResult, _} = stress_lib:node_call(Ctx, stop_server, [10000]),
    StopMs = stress_lib:elapsed_ms(T0),
    Outcomes = [bench_conn:recv(C, 0, 2000) || C <- Busy],
    [bench_conn:close(C) || C <- Busy],
    stress_lib:check(StopResult =:= ok, "stop succeeds", StopResult),
    stress_lib:check(lists:all(fun(O) -> O =:= {error, closed} orelse O =:= {error, econnreset} end, Outcomes),
                     "busy handlers are killed unanswered", Outcomes),
    stress_lib:check(StopMs >= 450 andalso StopMs < 2500, "stop returns at about shutdown_timeout", StopMs),
    #{stop_ms => StopMs}.

connect(Port) ->
    {ok, C} = bench_conn:connect(Port, false),
    C.
