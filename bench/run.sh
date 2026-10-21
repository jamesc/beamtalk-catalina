#!/usr/bin/env bash
# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0
#
# Build the bench/stress harness and run one of its entry modules:
#   bench/run.sh bench_main [ARGS...]    (just bench)
#   bench/run.sh stress_main [ARGS...]   (just stress)
#
# Builds the Catalina peer package (bench/catalina_node), the Thousand Island
# baseline (bench/thousand_island, a mix project) and the Erlang harness
# (bench/harness, test/stress) into _build/bench/ebin.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
main="$1"
shift

(cd "$root/bench/catalina_node" && beamtalk build >/dev/null)
(cd "$root/bench/thousand_island" \
  && MIX_ENV=prod mix local.hex --force --if-missing >/dev/null \
  && MIX_ENV=prod mix deps.get >/dev/null \
  && MIX_ENV=prod mix compile >/dev/null)
mkdir -p "$root/_build/bench/ebin"
erlc -o "$root/_build/bench/ebin" "$root"/bench/harness/*.erl "$root"/test/stress/*.erl

export BENCH_ROOT="$root"
export BENCH_BEAMTALK_LIB="$(beamtalk --print-sysroot)/lib/beamtalk/lib"
export BENCH_ELIXIR_LIB="$(cd "$root/bench/thousand_island" && elixir -e 'IO.write(Path.dirname(:code.lib_dir(:elixir)))')"
export BENCH_ELIXIR_VERSION="$(cd "$root/bench/thousand_island" && elixir -e 'IO.write(System.version())')"
export BENCH_TI_VERSION="$(sed -n 's/.*"thousand_island": {:hex, :thousand_island, "\([^"]*\)".*/\1/p' "$root/bench/thousand_island/mix.lock")"
export BENCH_BEAMTALK_VERSION="$(beamtalk --version | awk '{print $2}') ($(git -C "$(beamtalk --print-sysroot)/.." rev-parse --short HEAD 2>/dev/null || echo unknown))"
export BENCH_CATALINA_REV="$(git -C "$root" rev-parse --short HEAD)$(git -C "$root" diff --quiet HEAD -- src || echo '+dirty')"

exec erl -noshell +P 2000000 +Q 1000000 -pa "$root/_build/bench/ebin" -s "$main" main -extra "$@"
