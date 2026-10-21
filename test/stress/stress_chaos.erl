%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Chaos under load: while echo clients (persistent and churning) load
%% the server, kill random acceptors and handlers. Kills are spread so that
%% no acceptor supervisor exceeds its restart intensity (at most 2 kills in
%% any 6 s per supervisor; OTP's default is 3 in 5 s). Checks:
%%
%% - the server keeps serving: echoes complete in every 2 s window;
%% - no byte is ever corrupted; the only client errors are closes and
%%   resets of connections whose handler was killed;
%% - the server, its acceptor pool and every acceptor supervisor are the
%%   same processes afterwards (restarts stayed inside the intensity), and
%%   every acceptor is running again;
%% - nothing leaks once the load stops.
-module(stress_chaos).

-export([tests/0]).

-define(KEYS, [processes, ports, ets]).
-define(INTERVAL, 50).

tests() ->
    [{"chaos_kill_acceptors_and_handlers", [catalina, ti], fun chaos/1},
     {"chaos_acceptor_killed_mid_handoff", [catalina, ti], fun mid_handoff/1}].

%% Kill the acceptor right after it starts a handler, before the handler
%% has its socket. Whatever the client sees, no handler may be left behind
%% once the client is gone, and the restarted acceptor serves again.
%% (Thousand Island's handoff is fast enough that the kill usually lands
%% after it; Catalina's handlers monitor the acceptor until the handoff.)
mid_handoff(Ctx) ->
    Rounds = stress_lib:pick(Ctx, {3, 10}),
    stress_lib:with_server(Ctx, #{num_acceptors => 1}, fun(Port) ->
        Seen = [begin
            stress_lib:wait_until(fun() ->
                [A] = stress_lib:node_call(Ctx, acceptors_by_supervisor, []),
                is_pid(element(2, A))
            end, 30000, acceptor_running),
            ok = stress_lib:node_call(Ctx, kill_acceptor_at_next_handler, [10000]),
            {ok, C} = bench_conn:connect(Port, false),
            Outcome = stress_lib:echo_once(C, <<"handoff">>, 5000),
            bench_conn:abort(C),
            stress_lib:wait_until(fun() -> stress_lib:node_call(Ctx, connection_count, []) =:= 0 end,
                                  10000, no_handler_left_behind),
            %% One kill per 2 s keeps inside the restart intensity.
            timer:sleep(2000),
            Outcome
         end || _ <- lists:seq(1, Rounds)],
        stress_lib:wait_until(fun() ->
            [A] = stress_lib:node_call(Ctx, acceptors_by_supervisor, []),
            is_pid(element(2, A))
        end, 30000, acceptor_restarted),
        {ok, C2} = bench_conn:connect(Port, false),
        After = stress_lib:echo_once(C2, <<"after">>),
        bench_conn:close(C2),
        stress_lib:check(After =:= ok, "the restarted acceptor serves", After),
        #{rounds => Rounds, client_saw => lists:usort(Seen)}
    end).

chaos(Ctx) ->
    Seconds = stress_lib:pick(Ctx, {5, 30}),
    stress_lib:with_server(Ctx, #{}, fun(Port) ->
        {ok, _} = stress_leak:churn(Port, 200, 16, false),
        Base = stress_lib:settle(Ctx, ?KEYS),
        Server = stress_lib:node_call(Ctx, server_pid, []),
        Pool = stress_lib:node_call(Ctx, acceptor_pool, []),
        Sups = lists:sort(stress_lib:node_call(Ctx, acceptor_supervisors, [])),
        Load = start_load(Port, 40, 4),
        T0 = erlang:monotonic_time(millisecond),
        Kills = kill_loop(Ctx, T0 + Seconds * 1000, #{}, {0, 0}),
        Report = stop_load(Load),
        #{windows := Windows, mismatches := Mismatches, errors := Errors, echoes := Echoes} = Report,
        stress_lib:check(Mismatches =:= 0, "no corrupted bytes", Mismatches),
        Unexpected = maps:without([closed, econnreset, timeout_after_kill], Errors),
        stress_lib:check(map_size(Unexpected) =:= 0, "only closes and resets", Errors),
        Empty = [W || {W, 0} <- Windows],
        stress_lib:check(Empty =:= [], "echoes completed in every 2 s window", Empty),
        stress_lib:check(stress_lib:node_call(Ctx, server_pid, []) =:= Server, "the server was not restarted", Server),
        stress_lib:check(stress_lib:node_call(Ctx, acceptor_pool, []) =:= Pool, "the acceptor pool was not restarted", Pool),
        stress_lib:check(lists:sort(stress_lib:node_call(Ctx, acceptor_supervisors, [])) =:= Sups,
                         "no acceptor supervisor was restarted", []),
        stress_lib:wait_until(fun() ->
            lists:all(fun({_, A}) -> is_pid(A) end, stress_lib:node_call(Ctx, acceptors_by_supervisor, []))
        end, 5000, every_acceptor_running),
        stress_lib:wait_until(fun() -> stress_lib:node_call(Ctx, connection_count, []) =:= 0 end,
                              30000, connections_closed),
        After = stress_lib:settle(Ctx, ?KEYS),
        Diff = maps:from_list([{K, {maps:get(K, Base), maps:get(K, After)}}
                               || K <- ?KEYS, maps:get(K, Base) =/= maps:get(K, After)]),
        stress_lib:check(Diff =:= #{}, "no leak after the chaos", Diff),
        {AccKills, HandlerKills} = Kills,
        #{seconds => Seconds, acceptor_kills => AccKills, handler_kills => HandlerKills,
          echoes => Echoes, errors => Errors}
    end).

%% Alternate acceptor and handler kills every ?INTERVAL ms until Deadline.
%% History maps each acceptor supervisor to its recent kill times.
kill_loop(Ctx, Deadline, History, Counts) ->
    kill_loop(Ctx, Deadline, History, acceptor, Counts).

kill_loop(Ctx, Deadline, History, Turn, {A, H}) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline of
        true -> {A, H};
        false ->
            {History1, Counts, Next} = case Turn of
                acceptor ->
                    case kill_acceptor(Ctx, Now, History) of
                        {ok, Hist} -> {Hist, {A + 1, H}, handler};
                        none -> {History, {A, H}, handler}
                    end;
                handler ->
                    case stress_lib:node_call(Ctx, kill_random_handler, []) of
                        none -> {History, {A, H}, acceptor};
                        _ -> {History, {A, H + 1}, acceptor}
                    end
            end,
            timer:sleep(?INTERVAL),
            kill_loop(Ctx, Deadline, History1, Next, Counts)
    end.

kill_acceptor(Ctx, Now, History) ->
    Recent = fun(S) -> [T || T <- maps:get(S, History, []), Now - T < 6000] end,
    Candidates = [{S, P} || {S, P} <- stress_lib:node_call(Ctx, acceptors_by_supervisor, []),
                            is_pid(P), length(Recent(S)) < 2],
    case Candidates of
        [] -> none;
        _ ->
            {S, P} = lists:nth(rand:uniform(length(Candidates)), Candidates),
            stress_lib:node_call(Ctx, kill, [P]),
            {ok, History#{S => [Now | Recent(S)]}}
    end.

%% === Load ===

%% Persistent echo clients that reconnect when their connection dies, and
%% churning clients. Every echo is checked byte for byte. Completions are
%% counted per 2 s window.
start_load(Port, Persistent, Churners) ->
    Stop = atomics:new(1, []),
    Windows = counters:new(1000, [write_concurrency]),
    T0 = erlang:monotonic_time(millisecond),
    Self = self(),
    Ctx = #{port => Port, stop => Stop, windows => Windows, t0 => T0},
    Pids = [spawn_link(fun() -> Self ! {load, self(), persistent(Ctx, undefined, #{})} end)
            || _ <- lists:seq(1, Persistent)]
        ++ [spawn_link(fun() -> Self ! {load, self(), churner(Ctx, #{})} end)
            || _ <- lists:seq(1, Churners)],
    Ctx#{pids => Pids}.

stop_load(#{stop := Stop, pids := Pids, windows := Windows, t0 := T0}) ->
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    atomics:put(Stop, 1, 1),
    Results = [receive {load, P, R} -> R after 60000 -> #{stuck => 1} end || P <- Pids],
    Merged = lists:foldl(fun(M, Acc) ->
        maps:fold(fun(K, V, A) -> maps:update_with(K, fun(X) -> X + V end, V, A) end, Acc, M)
    end, #{}, Results),
    %% Only full windows count, and not the first, while clients connect.
    Full = Elapsed div 2000,
    Ws = [{I, counters:get(Windows, I + 1)} || I <- lists:seq(1, min(Full, 1000) - 1)],
    #{windows => Ws,
      echoes => maps:get(ok, Merged, 0),
      mismatches => maps:get(mismatch, Merged, 0),
      errors => maps:without([ok, mismatch], Merged)}.

stopped(#{stop := S}) -> atomics:get(S, 1) =:= 1.

tick(#{windows := W, t0 := T0}) ->
    I = (erlang:monotonic_time(millisecond) - T0) div 2000,
    I < 1000 andalso counters:add(W, I + 1, 1).

persistent(Ctx = #{port := Port}, Conn, Acc) ->
    case stopped(Ctx) of
        true ->
            Conn =/= undefined andalso bench_conn:abort(Conn),
            Acc;
        false when Conn =:= undefined ->
            case bench_conn:connect(Port, false) of
                {ok, C} -> persistent(Ctx, C, Acc);
                {error, R} -> persistent(Ctx, undefined, bump({connect, R}, Acc))
            end;
        false ->
            Data = rand:bytes(rand:uniform(4096)),
            case stress_lib:echo_once(Conn, Data, 5000) of
                ok ->
                    tick(Ctx),
                    persistent(Ctx, Conn, bump(ok, Acc));
                {mismatch, _} ->
                    bench_conn:abort(Conn),
                    persistent(Ctx, undefined, bump(mismatch, Acc));
                {error, timeout} ->
                    %% A killed handler can leave the connection half-open
                    %% for a moment; reconnect.
                    bench_conn:abort(Conn),
                    persistent(Ctx, undefined, bump(timeout_after_kill, Acc));
                {error, R} ->
                    bench_conn:abort(Conn),
                    persistent(Ctx, undefined, bump(R, Acc))
            end
    end.

churner(Ctx = #{port := Port}, Acc) ->
    case stopped(Ctx) of
        true -> Acc;
        false ->
            Acc1 = case bench_conn:connect(Port, false) of
                {ok, C} ->
                    Data = rand:bytes(64),
                    R = stress_lib:echo_once(C, Data, 5000),
                    bench_conn:abort(C),
                    case R of
                        ok -> tick(Ctx), bump(ok, Acc);
                        {mismatch, _} -> bump(mismatch, Acc);
                        {error, timeout} -> bump(timeout_after_kill, Acc);
                        {error, E} -> bump(E, Acc)
                    end;
                {error, E} ->
                    bump({connect, E}, Acc)
            end,
            churner(Ctx, Acc1)
    end.

bump(K, M) -> maps:update_with(K, fun(X) -> X + 1 end, 1, M).
