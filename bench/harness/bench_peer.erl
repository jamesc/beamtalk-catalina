%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Start a server peer node: a separate BEAM VM running either Catalina
%% (`catalina`) or Thousand Island (`ti`), driven over the peer control
%% channel (standard_io, so no epmd or distribution). The load generator
%% runs in the calling VM, so client and server never share schedulers.
%%
%% Paths come from the environment, set by the Justfile:
%%   BENCH_ROOT          the repository root
%%   BENCH_BEAMTALK_LIB  `$(beamtalk --print-sysroot)/lib/beamtalk/lib`
%%   BENCH_ELIXIR_LIB    the directory holding Elixir's `elixir/` and `logger/`
-module(bench_peer).

-export([start/1, start/2, stop/1, call/4, call/5, impls/0]).

-define(CALL_TIMEOUT, 120000).

impls() -> [catalina, ti].

start(Impl) -> start(Impl, #{}).

%% Opts: `log` (a file for the peer's logger, default: `none`, which keeps
%% only critical reports on the console).
start(Impl, Opts) ->
    Args = ["-noinput", "+P", "2000000", "+Q", "1000000"]
        ++ lists:append([["-pa", D] || D <- code_paths(Impl)]),
    {ok, Peer, _Node} = peer:start_link(#{
        connection => standard_io,
        args => Args,
        wait_boot => 60000
    }),
    ok = peer:call(Peer, bench_node, boot, [Impl, maps:get(log, Opts, none)], ?CALL_TIMEOUT),
    Peer.

stop(Peer) ->
    catch peer:stop(Peer),
    ok.

call(Peer, M, F, A) -> call(Peer, M, F, A, ?CALL_TIMEOUT).

call(Peer, M, F, A, Timeout) -> peer:call(Peer, M, F, A, Timeout).

code_paths(Impl) ->
    Root = env("BENCH_ROOT"),
    Harness = filename:join([Root, "_build", "bench", "ebin"]),
    [Harness | impl_paths(Impl, Root)].

impl_paths(catalina, Root) ->
    Lib = env("BENCH_BEAMTALK_LIB"),
    Node = filename:join([Root, "bench", "catalina_node", "_build"]),
    filelib:wildcard(filename:join([Lib, "*", "ebin"]))
        ++ [filename:join([Node, "dev", "ebin"]), filename:join([Node, "deps", "catalina", "ebin"])]
        ++ filelib:wildcard(filename:join([Node, "dev", "native", "default", "lib", "*", "ebin"]));
impl_paths(ti, Root) ->
    Lib = env("BENCH_ELIXIR_LIB"),
    Ti = filename:join([Root, "bench", "thousand_island", "_build", "prod", "lib"]),
    [filename:join([Lib, A, "ebin"]) || A <- ["elixir", "logger"]]
        ++ filelib:wildcard(filename:join([Ti, "*", "ebin"])).

env(Name) ->
    case os:getenv(Name) of
        false -> error({missing_environment_variable, Name});
        "" -> error({missing_environment_variable, Name});
        V -> V
    end.
