%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc The harness's side of a server peer node (see `bench_peer`): boots
%% Catalina or Thousand Island, starts and stops one server at a time, and
%% answers questions about it. Both servers have the same tree, so the tree
%% walks are shared:
%%
%%   server (rest_for_one): listener, acceptor pool, shutdown listener
%%   acceptor pool: one acceptor supervisor per acceptor
%%   acceptor supervisor: connection supervisor (dynamic), acceptor
%%
%% Harness server options (a map; all optional but `port`):
%%   port, tls, handler (echo | slow_echo), handler_options, num_acceptors,
%%   num_connections, read_timeout, shutdown_timeout,
%%   max_connections_retry_count, max_connections_retry_wait,
%%   transport_options (a proplist).
-module(bench_node).

-export([
    boot/2,
    impl/0,
    start_server/1,
    stop_server/1,
    stop_server/2,
    suspend/0,
    resume/0,
    stats/0,
    server_pid/0,
    acceptor_supervisors/0,
    acceptors/0,
    acceptors_by_supervisor/0,
    acceptor_pool/0,
    kill/1,
    kill_acceptor_at_next_handler/1,
    connection_supervisors/0,
    connection_count/0,
    connection_pids/0,
    handler_memory/0,
    kill_random_acceptor/0,
    kill_random_handler/0,
    gc_all/0,
    cert_dir/0
]).


%% === Boot ===

boot(Impl, Log) ->
    persistent_term:put({?MODULE, impl}, Impl),
    configure_logger(Log),
    {ok, _} = application:ensure_all_started(ssl),
    boot(Impl).

boot(catalina) ->
    {ok, _} = application:ensure_all_started(beamtalk_stdlib),
    {ok, _} = application:ensure_all_started(catalina_node),
    %% Load every package module so its class registers (on_load).
    Dirs = [D || D <- code:get_path(), is_package_ebin(D)],
    [code:ensure_loaded(list_to_atom(filename:basename(F, ".beam")))
        || D <- Dirs, F <- filelib:wildcard(filename:join(D, "bt@*.beam"))],
    ok;
boot(ti) ->
    {ok, _} = application:ensure_all_started(thousand_island),
    {module, _} = code:ensure_loaded('Elixir.TiNode.BenchEcho'),
    {module, _} = code:ensure_loaded('Elixir.TiNode.SlowEcho'),
    ok.

is_package_ebin(Dir) ->
    lists:any(fun(Part) -> lists:member(Part, filename:split(Dir)) end,
              ["catalina_node"]).

configure_logger(none) ->
    logger:set_primary_config(level, critical);
configure_logger(File) ->
    _ = logger:remove_handler(default),
    ok = logger:add_handler(file, logger_std_h, #{
        config => #{file => File},
        level => all
    }),
    logger:set_primary_config(level, notice).

impl() -> persistent_term:get({?MODULE, impl}).

%% The certificate pair both servers use for TLS.
cert_dir() ->
    filename:join([os:getenv("BENCH_ROOT"), "test", "fixtures"]).

%% === One server ===

%% Start a server owned by a long-lived process (the caller is a transient
%% peer-call process). Answers `{ok, Port}`. A node runs one server per
%% `name` (default `main`); everything else here is about `main`.
start_server(Opts) ->
    Name = maps:get(name, Opts, main),
    case whereis(owner_name(Name)) of
        undefined -> ok;
        _ -> error({server_already_running, Name})
    end,
    Caller = self(),
    Ref = make_ref(),
    Owner = spawn(fun() -> owner(Caller, Ref, Name, maps:remove(name, Opts)) end),
    receive
        {Ref, Reply} -> Reply
    after 60000 ->
        exit(Owner, kill),
        {error, start_timeout}
    end.

owner_name(Name) -> list_to_atom("bench_node_owner_" ++ atom_to_list(Name)).

owner(Caller, Ref, Name, Opts) ->
    process_flag(trap_exit, true),
    case catch start(impl(), Opts) of
        {ok, Server, Port} ->
            register(owner_name(Name), self()),
            persistent_term:put({?MODULE, server, Name}, Server),
            Caller ! {Ref, {ok, Port}},
            owner_loop(Name, Server);
        Other ->
            Caller ! {Ref, {error, Other}}
    end.

owner_loop(Name, Server) ->
    receive
        {stop, Timeout, From, Ref} ->
            T0 = erlang:monotonic_time(millisecond),
            Result = stop(impl(), Server, Timeout),
            Elapsed = erlang:monotonic_time(millisecond) - T0,
            persistent_term:erase({?MODULE, server, Name}),
            unregister(owner_name(Name)),
            From ! {Ref, {Result, Elapsed}};
        {'EXIT', _, _} ->
            owner_loop(Name, Server)
    end.

%% Stop the `main` server, waiting up to `Timeout` ms. Answers
%% `{Result, ElapsedMs}`.
stop_server(Timeout) -> stop_server(main, Timeout).

stop_server(Name, Timeout) ->
    case whereis(owner_name(Name)) of
        undefined ->
            {ok, 0};
        Owner ->
            Ref = make_ref(),
            Owner ! {stop, Timeout, self(), Ref},
            receive {Ref, Reply} -> Reply end
    end.

server() -> persistent_term:get({?MODULE, server, main}).

start(catalina, Opts) ->
    Server = 'bt@catalina_node@catalina_node':'class_start:'(nil, catalina_options(Opts)),
    {_, Port} = result(beamtalk_message_dispatch:send(Server, listenerInfo, [])),
    {ok, Server, Port};
start(ti, Opts) ->
    {ok, Pid} = 'Elixir.ThousandIsland':start_link(ti_options(Opts)),
    {ok, {_, Port}} = 'Elixir.ThousandIsland':listener_info(Pid),
    {ok, Pid, Port}.

stop(catalina, Server, Timeout) ->
    case beamtalk_message_dispatch:send(Server, 'stop:', [Timeout]) of
        #{isOk := true} -> ok;
        #{errReason := R} -> {error, R}
    end;
stop(ti, Pid, Timeout) ->
    'Elixir.ThousandIsland':stop(Pid, Timeout).

catalina_options(Opts) ->
    Keys = [
        {port, port},
        {num_acceptors, numAcceptors},
        {num_connections, numConnections},
        {read_timeout, readTimeout},
        {shutdown_timeout, shutdownTimeout},
        {max_connections_retry_count, maxConnectionsRetryCount},
        {max_connections_retry_wait, maxConnectionsRetryWait},
        {handler_options, handlerOptions}
    ],
    Base = maps:from_list([{To, maps:get(From, Opts)} || {From, To} <- Keys, maps:is_key(From, Opts)]),
    Base#{
        handler => case maps:get(handler, Opts, echo) of
            slow_echo -> slowEcho;
            echo -> echo
        end,
        tls => maps:get(tls, Opts, false),
        transportOptions => transport_options(Opts)
    }.

ti_options(Opts) ->
    Keys = [port, num_acceptors, num_connections, read_timeout, shutdown_timeout,
            max_connections_retry_count, max_connections_retry_wait, handler_options],
    Base = [{K, maps:get(K, Opts)} || K <- Keys, maps:is_key(K, Opts)],
    Handler = case maps:get(handler, Opts, echo) of
        slow_echo -> 'Elixir.TiNode.SlowEcho';
        echo -> 'Elixir.TiNode.BenchEcho'
    end,
    Transport = case maps:get(tls, Opts, false) of
        true -> 'Elixir.ThousandIsland.Transports.SSL';
        false -> 'Elixir.ThousandIsland.Transports.TCP'
    end,
    [{handler_module, Handler}, {transport_module, Transport},
     {transport_options, transport_options(Opts)} | Base].

transport_options(Opts) ->
    User = maps:get(transport_options, Opts, []),
    case maps:get(tls, Opts, false) of
        true ->
            Dir = cert_dir(),
            [{certfile, filename:join(Dir, "cert.pem")},
             {keyfile, filename:join(Dir, "key.pem")} | User];
        false ->
            User
    end.

result(#{'$beamtalk_class' := 'Result', isOk := true, okValue := V}) -> V;
result(#{'$beamtalk_class' := 'Result', errReason := R}) -> error({beamtalk_error, R}).

%% === Operations ===

suspend() -> op(suspend).

resume() -> op(resume).

op(Op) ->
    case impl() of
        catalina ->
            case beamtalk_message_dispatch:send(server(), Op, []) of
                #{isOk := true} -> ok;
                #{errReason := R} -> {error, R}
            end;
        ti ->
            'Elixir.ThousandIsland':Op(server())
    end.

server_pid() ->
    case server() of
        {beamtalk_supervisor, _, _, Pid} -> Pid;
        Pid when is_pid(Pid) -> Pid
    end.

%% The acceptor pool is the server's only supervisor child.
acceptor_pool() ->
    [Pool] = [P || {_, P, supervisor, _} <- supervisor:which_children(server_pid()), is_pid(P)],
    Pool.

%% The pool's children, the acceptor supervisors.
acceptor_supervisors() ->
    [S || {_, S, _, _} <- supervisor:which_children(acceptor_pool()), is_pid(S)].

%% `{AcceptorSupervisor, Acceptor}` for each acceptor supervisor; the
%% acceptor is `undefined` while it is restarting.
acceptors_by_supervisor() ->
    [{S, case [A || {_, A, worker, _} <- safe_children(S), is_pid(A)] of
             [A] -> A;
             [] -> undefined
         end} || S <- acceptor_supervisors()].

%% The live acceptor processes (the worker child of each acceptor supervisor).
acceptors() ->
    [A || S <- acceptor_supervisors(),
          {_, A, worker, _} <- safe_children(S), is_pid(A)].

connection_supervisors() ->
    [C || S <- acceptor_supervisors(),
          {_, C, supervisor, _} <- safe_children(S), is_pid(C)].

%% Live handlers across the server, counted by the connection supervisors.
connection_count() ->
    lists:sum([proplists:get_value(active, safe_count(C), 0) || C <- connection_supervisors()]).

connection_pids() ->
    [H || C <- connection_supervisors(), {_, H, _, _} <- safe_children(C), is_pid(H)].

%% Bytes of process memory across the handler processes.
handler_memory() ->
    lists:sum([M || P <- connection_pids(), {memory, M} <- [erlang:process_info(P, memory)]]).

safe_children(Sup) ->
    try supervisor:which_children(Sup) catch _:_ -> [] end.

safe_count(Sup) ->
    try supervisor:count_children(Sup) catch _:_ -> [] end.

kill_random_acceptor() -> kill_random(acceptors()).

kill_random_handler() -> kill_random(connection_pids()).

kill(Pid) ->
    exit(Pid, kill),
    ok.

%% For a one-acceptor server: watch its connection supervisor and kill the
%% acceptor the moment a handler appears, before (or while) it is handed its
%% socket. Answers at once; the watcher gives up after `Ms`.
kill_acceptor_at_next_handler(Ms) ->
    [ConnSup] = connection_supervisors(),
    [Acceptor] = acceptors(),
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    spawn(fun() -> watch_and_kill(ConnSup, Acceptor, Deadline) end),
    ok.

watch_and_kill(ConnSup, Acceptor, Deadline) ->
    case [P || {_, P, _, _} <- safe_children(ConnSup), is_pid(P)] of
        [_ | _] ->
            exit(Acceptor, kill);
        [] ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> ok;
                false -> watch_and_kill(ConnSup, Acceptor, Deadline)
            end
    end.

kill_random([]) -> none;
kill_random(Pids) ->
    P = lists:nth(rand:uniform(length(Pids)), Pids),
    exit(P, kill),
    P.

gc_all() ->
    [erlang:garbage_collect(P) || P <- erlang:processes()],
    ok.

%% Node-wide counters for the leak checks and the memory rows.
stats() ->
    #{
        processes => erlang:system_info(process_count),
        ports => erlang:system_info(port_count),
        ets => length(ets:all()),
        %% Rows across every table: a table that only grows is a leak even
        %% when the table count is steady.
        ets_rows => lists:sum([N || T <- ets:all(), N <- [ets:info(T, size)], is_integer(N)]),
        memory => erlang:memory(total),
        process_memory => erlang:memory(processes),
        binary_memory => erlang:memory(binary),
        connections => try connection_count() catch _:_ -> 0 end
    }.
