%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Byte-exact echo fuzz: many connections at once, each sending
%% payloads of random size (0 to 1 MiB) in random fragments with random
%% pauses, while a separate reader checks that exactly the same bytes come
%% back, in order, and nothing more.
-module(stress_fuzz).

-export([tests/0]).

-define(MAX_PAYLOAD, 1048576).

tests() ->
    [{"fuzz_tcp", [catalina, ti], fun(Ctx) -> fuzz(Ctx, false) end},
     {"fuzz_tls", [catalina, ti], fun(Ctx) -> fuzz(Ctx, true) end}].

fuzz(Ctx, Tls) ->
    Conns = stress_lib:pick(Ctx, {8, 40}),
    PerConn = stress_lib:pick(Ctx, {4, 12}),
    stress_lib:with_server(Ctx, #{tls => Tls}, fun(Port) ->
        Self = self(),
        Pids = [spawn_link(fun() -> Self ! {done, self(), client(Port, Tls, PerConn, I)} end)
                || I <- lists:seq(1, Conns)],
        Results = [receive {done, P, R} -> R after 600000 -> timeout end || P <- Pids],
        Bad = [R || R <- Results, element(1, R) =/= ok],
        stress_lib:check(Bad =:= [], "every payload echoed byte for byte", Bad),
        Bytes = lists:sum([B || {ok, B} <- Results]),
        #{connections => Conns, payloads => Conns * PerConn, bytes => Bytes}
    end).

client(Port, Tls, N, Seed) ->
    rand:seed(exsss, {Seed, erlang:unique_integer([positive]), 42}),
    {ok, C} = bench_conn:connect(Port, Tls),
    Payloads = [rand:bytes(size()) || _ <- lists:seq(1, N)],
    Total = lists:sum([byte_size(P) || P <- Payloads]),
    Expected = iolist_to_binary(Payloads),
    Self = self(),
    %% The writer sends while this process reads, so a large echo never
    %% stalls on flow control.
    Writer = spawn_link(fun() -> Self ! {written, write(C, Payloads)} end),
    Result = case stress_lib:recv_all(C, Total, 30000) of
        {ok, Expected} -> check_tail(C, Total);
        {ok, Got} -> {mismatch, first_difference(Got, Expected), byte_size(Got), Total};
        Error -> {recv_failed, Error, Total}
    end,
    receive {written, W} -> ok after 30000 -> W = writer_timeout end,
    unlink(Writer),
    bench_conn:close(C),
    case {Result, W} of
        {{ok, _}, ok} -> Result;
        {{ok, _}, _} -> {write_failed, W};
        _ -> Result
    end.

%% Nothing beyond the expected bytes.
check_tail(C, Total) ->
    case bench_conn:recv(C, 0, 200) of
        {error, timeout} -> {ok, Total};
        Other -> {extra_data, Other}
    end.

%% Sizes skewed small, with a long tail up to 1 MiB and some empty ones.
size() ->
    case rand:uniform(10) of
        1 -> 0;
        N when N =< 5 -> rand:uniform(4096);
        N when N =< 8 -> rand:uniform(131072);
        _ -> rand:uniform(?MAX_PAYLOAD + 1) - 1
    end.

write(_C, []) -> ok;
write(C, [P | Rest]) ->
    case write_fragments(C, P) of
        ok -> write(C, Rest);
        Error -> Error
    end.

%% Random fragments, from 1 byte to 64 KiB, with an occasional pause.
write_fragments(_C, <<>>) -> ok;
write_fragments(C, Bin) ->
    Len = min(byte_size(Bin), fragment()),
    <<Frag:Len/binary, Rest/binary>> = Bin,
    case bench_conn:send(C, Frag) of
        ok ->
            case rand:uniform(20) of
                1 -> timer:sleep(rand:uniform(5));
                _ -> ok
            end,
            write_fragments(C, Rest);
        Error ->
            Error
    end.

fragment() ->
    case rand:uniform(4) of
        1 -> rand:uniform(16);
        2 -> rand:uniform(1500);
        _ -> rand:uniform(65536)
    end.

first_difference(A, B) -> first_difference(A, B, 0).

first_difference(<<X, A/binary>>, <<X, B/binary>>, I) -> first_difference(A, B, I + 1);
first_difference(_, _, I) -> I.
