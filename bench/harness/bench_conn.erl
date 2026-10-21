%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Client connections over TCP or TLS behind one interface, for the
%% load generator and the stress tests. A connection is `{tcp, Socket}` or
%% `{tls, SslSocket}`; sockets are passive binaries with `nodelay`.
-module(bench_conn).

-export([connect/2, connect/3, connect/4, send/2, recv/2, recv/3, close/1, abort/1,
         shutdown_write/1, setopts/2, recv_exact/3, client_tls_options/0]).

-define(CONNECT_TIMEOUT, 60000).
-define(RECV_TIMEOUT, 60000).

connect(Port, Tls) -> connect(Port, Tls, []).

%% Connect, retrying while the listen backlog is full (`econnrefused` or
%% `timeout` with many connections in flight). Extra are additional socket
%% options.
connect(Port, Tls, Extra) -> connect(Port, Tls, Extra, 20).

connect(Port, Tls, Extra, Attempts) ->
    Opts = [binary, {active, false}, {nodelay, true}, {reuseaddr, true} | Extra],
    case gen_tcp:connect({127, 0, 0, 1}, Port, Opts, ?CONNECT_TIMEOUT) of
        {ok, S} when Tls ->
            case ssl:connect(S, client_tls_options(), ?CONNECT_TIMEOUT) of
                {ok, Ssl} -> {ok, {tls, Ssl}};
                {error, _} = E ->
                    gen_tcp:close(S),
                    E
            end;
        {ok, S} ->
            {ok, {tcp, S}};
        {error, R} when (R =:= econnrefused orelse R =:= timeout orelse R =:= eaddrnotavail
                         orelse R =:= econnreset), Attempts > 1 ->
            timer:sleep(20 + rand:uniform(50)),
            connect(Port, Tls, Extra, Attempts - 1);
        {error, _} = E ->
            E
    end.

client_tls_options() ->
    [{verify, verify_none}, {reuse_sessions, false}, {active, false},
     {versions, ['tlsv1.3', 'tlsv1.2']}].

send({tcp, S}, Data) -> gen_tcp:send(S, Data);
send({tls, S}, Data) -> ssl:send(S, Data).

recv(C, Len) -> recv(C, Len, ?RECV_TIMEOUT).

recv({tcp, S}, Len, T) -> gen_tcp:recv(S, Len, T);
recv({tls, S}, Len, T) -> ssl:recv(S, Len, T).

%% Exactly Len bytes (Len > 0), as one binary.
recv_exact(C, Len, T) -> recv(C, Len, T).

setopts({tcp, S}, O) -> inet:setopts(S, O);
setopts({tls, S}, O) -> ssl:setopts(S, O).

close({tcp, S}) -> gen_tcp:close(S);
close({tls, S}) -> ssl:close(S).

%% Close with a reset (SO_LINGER 0), so the client side leaves no TIME_WAIT
%% entry: churn at thousands of connections a second would otherwise run
%% out of ephemeral ports.
abort({tcp, S}) ->
    _ = inet:setopts(S, [{linger, {true, 0}}]),
    gen_tcp:close(S);
abort({tls, S}) ->
    _ = ssl:setopts(S, [{linger, {true, 0}}]),
    ssl:close(S).

shutdown_write({tcp, S}) -> gen_tcp:shutdown(S, write);
shutdown_write({tls, S}) -> ssl:shutdown(S, write).
