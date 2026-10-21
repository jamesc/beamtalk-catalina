%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc `just stress`: Catalina's behaviour under load and under failure.
%%
%% Each test runs against Catalina and, where the expectation is "as
%% Thousand Island does", against Thousand Island too, with the same
%% assertions, so a test that fails only for Catalina is a Catalina bug.
%% Servers run in peer VMs (`bench_peer`); the clients run here.
%%
%%   erl -noshell -pa _build/bench/ebin -s stress_main main -extra \
%%       [--smoke] [--soak-minutes N] [--only NAME,...] [--impl catalina|ti|both]
-module(stress_main).

-export([main/0]).

-define(MODULES, [stress_fuzz, stress_leak, stress_limits, stress_timeouts,
                  stress_chaos, stress_lifecycle, stress_soak]).

main() ->
    Opts = parse(init:get_plain_arguments(), #{size => full, soak_minutes => undefined,
                                               only => [], impl => both}),
    {ok, _} = application:ensure_all_started(ssl),
    Size = maps:get(size, Opts),
    Soak = case maps:get(soak_minutes, Opts) of
        undefined when Size =:= smoke -> 1;
        undefined -> 30;
        M -> M
    end,
    Tests = [T || Mod <- ?MODULES, T <- Mod:tests(), selected(T, Opts)],
    Impls = case maps:get(impl, Opts) of both -> [catalina, ti]; I -> [I] end,
    LogDir = filename:join([os:getenv("BENCH_ROOT"), "_build", "stress"]),
    ok = filelib:ensure_path(LogDir),
    io:format("stress (~p, soak ~p min); load ~s; server logs in ~s~n",
              [Size, Soak, load(), LogDir]),
    Peers = maps:from_list([{I, bench_peer:start(I, #{log => filename:join(LogDir, atom_to_list(I) ++ ".log")})}
                            || I <- Impls]),
    Results = [run_test(T, I, maps:get(I, Peers), Size, Soak)
               || {_Name, TestImpls, _} = T <- Tests, I <- TestImpls, lists:member(I, Impls)],
    [bench_peer:stop(P) || P <- maps:values(Peers)],
    Failed = [R || R = {_, _, {fail, _}, _} <- Results],
    io:format("~n~p passed, ~p failed; load ~s~n", [length(Results) - length(Failed), length(Failed), load()]),
    [io:format("FAILED ~s [~p]: ~P~n", [N, I, Why, 40]) || {N, I, {fail, Why}, _} <- Failed],
    halt(case Failed of [] -> 0; _ -> 1 end).

parse(["--smoke" | T], O) -> parse(T, O#{size => smoke});
parse(["--soak-minutes", N | T], O) -> parse(T, O#{soak_minutes => list_to_number(N)});
parse(["--only", L | T], O) -> parse(T, O#{only => string:split(L, ",", all)});
parse(["--impl", I | T], O) -> parse(T, O#{impl => list_to_atom(I)});
parse([], O) -> O;
parse([X | _], _) -> error({unknown_argument, X}).

list_to_number(S) ->
    try list_to_integer(S) catch error:badarg -> list_to_float(S) end.

selected(_, #{only := []}) -> true;
selected({Name, _, _}, #{only := Only}) ->
    lists:any(fun(O) -> string:prefix(Name, O) =/= nomatch end, Only).

run_test({Name, _, Fun}, Impl, Peer, Size, Soak) ->
    io:format("~-34s ~-8s ", [Name, Impl]),
    Ctx = #{impl => Impl, peer => Peer, size => Size, soak_minutes => Soak},
    T0 = erlang:monotonic_time(millisecond),
    Self = self(),
    %% Each test runs in its own process, so a crash fails only that test.
    {Pid, Ref} = spawn_monitor(fun() -> Self ! {self(), Fun(Ctx)} end),
    Outcome = receive
        {Pid, Result} ->
            erlang:demonitor(Ref, [flush]),
            {pass, Result};
        {'DOWN', Ref, process, Pid, Why} ->
            {fail, Why}
    end,
    Ms = erlang:monotonic_time(millisecond) - T0,
    %% Leave no server running for the next test.
    catch bench_peer:call(Peer, bench_node, stop_server, [10000]),
    case Outcome of
        {pass, Info} -> io:format("PASS ~6.1fs  ~s~n", [Ms / 1000, info(Info)]);
        {fail, W} -> io:format("FAIL ~6.1fs~n    ~P~n", [Ms / 1000, W, 60])
    end,
    {Name, Impl, Outcome, Ms}.

info(ok) -> "";
info(M) when is_map(M) ->
    lists:join("  ", [io_lib:format("~s=~0p", [K, V]) || {K, V} <- lists:sort(maps:to_list(M))]);
info(X) -> io_lib:format("~0p", [X]).

load() ->
    case file:read_file("/proc/loadavg") of
        {ok, B} -> string:join(lists:sublist(string:lexemes(binary_to_list(B), " "), 3), " ");
        _ -> string:trim(string:replace(string:replace(os:cmd("sysctl -n vm.loadavg"), "{", ""), "}", ""), both, " \n")
    end.
