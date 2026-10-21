%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc A shared, lock-free latency histogram: log-scale buckets 1% wide
%% (`counters`), so many client processes record into one without
%% messages, and percentiles are accurate to about 1%.
-module(bench_hist).

-export([new/0, record/2, count/1, percentile/2, summary/1]).

-define(BUCKETS, 2400).
%% 1 / ln(1.01): bucket i holds values in [1.01^i, 1.01^(i+1)) microseconds.
-define(SCALE, 100.49916).

new() -> counters:new(?BUCKETS, [write_concurrency]).

%% Record one latency, in microseconds.
record(H, Us) when Us < 1 -> counters:add(H, 1, 1);
record(H, Us) ->
    I = min(?BUCKETS, 1 + trunc(math:log(Us) * ?SCALE)),
    counters:add(H, I, 1).

count(H) -> lists:sum(values(H)).

values(H) -> [counters:get(H, I) || I <- lists:seq(1, ?BUCKETS)].

%% The P-th percentile (0 < P =< 100), in microseconds, or `undefined`
%% if nothing was recorded.
percentile(H, P) ->
    Vs = values(H),
    case lists:sum(Vs) of
        0 -> undefined;
        Total -> find(Vs, 1, 0, max(1, ceil(Total * P / 100)))
    end.

find([V | Rest], I, Seen, Rank) ->
    case Seen + V >= Rank of
        true -> midpoint(I);
        false -> find(Rest, I + 1, Seen + V, Rank)
    end.

%% The geometric middle of bucket I.
midpoint(1) -> 1.0;
midpoint(I) -> math:exp((I - 1 + 0.5) / ?SCALE).

summary(H) ->
    #{p50 => percentile(H, 50), p99 => percentile(H, 99), p999 => percentile(H, 99.9)}.
