# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0

# Standard Beamtalk project targets.
# See: https://beamtalk.dev/docs/tooling

# Build the project
build:
    beamtalk build

# Run the test suite
test:
    beamtalk test --warnings-as-errors

# Benchmark Catalina against Thousand Island, interleaved (README § Benchmarks and stress tests)
bench *ARGS:
    bench/run.sh bench_main {{ARGS}}

# Correctness under load and failure (test/stress/; not part of `test`)
stress *ARGS:
    bench/run.sh stress_main {{ARGS}}

# A one-round bench on a few rows, as CI runs it (non-blocking)
bench-smoke:
    bench/run.sh bench_main --rounds 1 --duration 1000 --warmup 300 --rows smoke

# The stress tests at smoke sizes with a one-minute soak, as CI runs them (non-blocking)
stress-smoke:
    bench/run.sh stress_main --smoke

# Check formatting
fmt:
    beamtalk fmt-check

# Format in place
fmt-fix:
    beamtalk fmt

# Lint source files
lint:
    beamtalk lint

# Remove build artifacts
clean:
    rm -rf _build

# Full CI check (fmt + lint + build + test)
ci: fmt lint build test

# Tag a release from beamtalk.toml version
release:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(grep '^version' beamtalk.toml | head -1 | sed 's/.*= *"\(.*\)"/\1/')
    git tag "v${version}"
    echo "Tagged v${version}"

# Push release tags to origin
publish:
    git push origin --tags
