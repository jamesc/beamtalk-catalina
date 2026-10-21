%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc The load generator: many concurrent client connections driven from
%% one pool of processes in this VM, against a server on `Port`.
%%
%% Each measurement has a warm-up phase and a measured phase. Workers read
%% the phase from a shared `atomics` cell after every operation and record
%% into shared `counters` and a `bench_hist`, so the coordinator never sees
%% a message per operation.
-module(bench_load).

-export([echo/2, churn/2, open_idle/3, close_idle/1, wait_ready/3]).

-define(WARMUP, 0).
-define(MEASURE, 1).
-define(STOP, 2).

%% Closed-loop echo: `conns` connections, each sending a `size`-byte payload
%% and waiting for all of it to come back before sending the next.
%% Options: conns, size, warmup_ms, duration_ms, tls.
%% Answers #{msgs_per_s, bytes_per_s, p50, p99, p999 (µs), errors, ...}.
echo(Port, Opts) ->
    #{conns := N, size := Size} = Opts,
    Tls = maps:get(tls, Opts, false),
    Payload = payload(Size),
    run(N, Opts, fun(Ctx) ->
        case bench_conn:connect(Port, Tls) of
            {ok, C} ->
                ready(Ctx),
                echo_loop(C, Payload, Size, Ctx),
                bench_conn:abort(C);
            {error, R} ->
                failed(Ctx, R)
        end
    end, Size).

echo_loop(C, Payload, Size, Ctx) ->
    case phase(Ctx) of
        ?STOP ->
            ok;
        Phase ->
            T0 = erlang:monotonic_time(),
            case bench_conn:send(C, Payload) of
                ok ->
                    case bench_conn:recv(C, Size) of
                        {ok, Bin} when byte_size(Bin) =:= Size ->
                            done(Ctx, Phase, T0),
                            echo_loop(C, Payload, Size, Ctx);
                        Other ->
                            error_in(Ctx, Other)
                    end;
                Other ->
                    error_in(Ctx, Other)
            end
    end.

%% Connection churn: each of `workers` processes repeatedly connects (and,
%% with `tls`, handshakes), echoes one 64-byte message, and closes.
%% Answers the connection rate as msgs_per_s.
churn(Port, Opts) ->
    Tls = maps:get(tls, Opts, false),
    Payload = payload(64),
    run(maps:get(workers, Opts, 32), Opts, fun(Ctx) ->
        ready(Ctx),
        churn_loop(Port, Tls, Payload, Ctx)
    end, 64).

churn_loop(Port, Tls, Payload, Ctx) ->
    case phase(Ctx) of
        ?STOP ->
            ok;
        Phase ->
            T0 = erlang:monotonic_time(),
            case bench_conn:connect(Port, Tls) of
                {ok, C} ->
                    Ok = bench_conn:send(C, Payload) =:= ok andalso
                        bench_conn:recv(C, 64) =:= {ok, Payload},
                    bench_conn:abort(C),
                    case Ok of
                        true ->
                            done(Ctx, Phase, T0),
                            churn_loop(Port, Tls, Payload, Ctx);
                        false ->
                            error_in(Ctx, echo_failed)
                    end;
                Other ->
                    error_in(Ctx, Other)
            end
    end.

%% Wait until the server answers an echo, for up to `Ms`. A server's start
%% returns before every acceptor is accepting, and on a loaded machine the
%% gap can be seconds.
wait_ready(Port, Tls, Ms) ->
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    wait_ready_loop(Port, Tls, Deadline).

wait_ready_loop(Port, Tls, Deadline) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    Ok = Left > 0 andalso case bench_conn:connect(Port, Tls) of
        {ok, C} ->
            R = bench_conn:send(C, <<"ready">>) =:= ok andalso bench_conn:recv(C, 5, Left),
            bench_conn:abort(C),
            R =:= {ok, <<"ready">>};
        _ ->
            false
    end,
    case Ok of
        true -> ok;
        false when Left =< 0 -> error({server_not_ready, Port});
        false ->
            timer:sleep(100),
            wait_ready_loop(Port, Tls, Deadline)
    end.

%% === The worker pool ===

run(N, Opts, Body, BytesPerOp) ->
    Ctx = #{
        phase => atomics:new(1, []),
        ops => counters:new(2, [write_concurrency]),
        hist => bench_hist:new(),
        coordinator => self()
    },
    Pids = [spawn(fun() -> Body(Ctx) end) || _ <- lists:seq(1, N)],
    {Ready, Failed} = await_ready(length(Pids), 0, 0, []),
    case Ready of
        0 ->
            stop_all(Ctx, Pids),
            #{error => {no_connections, Failed}};
        _ ->
            timer:sleep(maps:get(warmup_ms, Opts, 1000)),
            T0 = erlang:monotonic_time(),
            atomics:put(maps:get(phase, Ctx), 1, ?MEASURE),
            timer:sleep(maps:get(duration_ms, Opts, 5000)),
            atomics:put(maps:get(phase, Ctx), 1, ?STOP),
            T1 = erlang:monotonic_time(),
            Secs = erlang:convert_time_unit(T1 - T0, native, microsecond) / 1.0e6,
            Errors = drain_errors(Pids, Ctx),
            Ops = counters:get(maps:get(ops, Ctx), 1),
            maps:merge(bench_hist:summary(maps:get(hist, Ctx)), #{
                ops => Ops,
                seconds => Secs,
                msgs_per_s => Ops / Secs,
                bytes_per_s => Ops * BytesPerOp / Secs,
                connected => Ready,
                connect_failures => Failed,
                errors => length(Errors),
                error_reasons => lists:usort(Errors)
            })
    end.

await_ready(0, R, F, _) -> {R, F};
await_ready(Left, R, F, Reasons) ->
    receive
        {ready, _} -> await_ready(Left - 1, R + 1, F, Reasons);
        {failed, _, Why} -> await_ready(Left - 1, R, F + 1, [Why | Reasons])
    after 120000 ->
        {R, F + Left}
    end.

%% Wait for every worker to finish its last operation; answer the errors
%% they reported during the run.
drain_errors(Pids, _Ctx) ->
    Refs = [{P, monitor(process, P)} || P <- Pids],
    [receive {'DOWN', Ref, process, P, _} -> ok after 60000 -> exit(P, kill) end
        || {P, Ref} <- Refs],
    collect_errors([]).

collect_errors(Acc) ->
    receive
        {error_in, _, Why} -> collect_errors([Why | Acc]);
        {ready, _} -> collect_errors(Acc);
        {failed, _, Why} -> collect_errors([Why | Acc])
    after 0 -> Acc
    end.

stop_all(Ctx, Pids) ->
    atomics:put(maps:get(phase, Ctx), 1, ?STOP),
    [exit(P, kill) || P <- Pids],
    ok.

ready(#{coordinator := C}) -> C ! {ready, self()}.

failed(#{coordinator := C}, Why) -> C ! {failed, self(), Why}.

error_in(#{coordinator := C}, Why) -> C ! {error_in, self(), simplify(Why)}.

simplify({error, R}) -> R;
simplify(Other) -> Other.

phase(#{phase := A}) -> atomics:get(A, 1).

done(_Ctx, ?WARMUP, _T0) -> ok;
done(#{ops := Ops, hist := H}, ?MEASURE, T0) ->
    Us = erlang:convert_time_unit(erlang:monotonic_time() - T0, native, nanosecond) / 1000,
    counters:add(Ops, 1, 1),
    bench_hist:record(H, Us).

payload(Size) -> rand:bytes(Size).

%% === Idle connections ===

%% Open `N` connections, each proven live by one echo, held by a pool of
%% owner processes. Answers a handle for `close_idle/1`.
open_idle(Port, N, Tls) ->
    Owners = 100,
    Per = [N div Owners + (case I =< N rem Owners of true -> 1; false -> 0 end)
           || I <- lists:seq(1, Owners)],
    Self = self(),
    Pids = [spawn(fun() -> idle_owner(Self, Port, K, Tls) end) || K <- Per, K > 0],
    Results = [receive {idle, P, R} -> R after 300000 -> timeout end || P <- Pids],
    {Pids, lists:sum([K || {ok, K} <- Results]), [R || R <- Results, element(1, R) =/= ok]}.

idle_owner(Parent, Port, K, Tls) ->
    case open_n(Port, K, Tls, []) of
        {error, _} = E ->
            Parent ! {idle, self(), E};
        Conns ->
            Parent ! {idle, self(), {ok, length(Conns)}},
            receive close -> [bench_conn:abort(C) || C <- Conns], ok end
    end.

open_n(_Port, 0, _Tls, Acc) -> Acc;
open_n(Port, K, Tls, Acc) ->
    case bench_conn:connect(Port, Tls) of
        {ok, C} ->
            case bench_conn:send(C, <<"ping">>) =:= ok andalso bench_conn:recv(C, 4) of
                {ok, <<"ping">>} ->
                    open_n(Port, K - 1, Tls, [C | Acc]);
                Other ->
                    [bench_conn:abort(X) || X <- [C | Acc]],
                    {error, {echo_failed, Other}}
            end;
        {error, _} = E ->
            [bench_conn:abort(C) || C <- Acc],
            E
    end.

close_idle({Pids, _, _}) ->
    Refs = [{monitor(process, P), P ! close} || P <- Pids],
    [receive {'DOWN', R, process, _, _} -> ok after 60000 -> ok end || {R, _} <- Refs],
    ok.
