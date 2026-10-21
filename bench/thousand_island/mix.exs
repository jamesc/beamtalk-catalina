# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0

# The Thousand Island baseline for `just bench` and `just stress`: the real
# Thousand Island, pinned, with an echo handler equivalent to Catalina's
# `BenchEcho`. The harness loads its compiled beams into a peer node.
defmodule TiNode.MixProject do
  use Mix.Project

  def project do
    [
      app: :ti_node,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: [{:thousand_island, "== 1.6.0"}]
    ]
  end

  def application, do: [extra_applications: [:logger, :ssl]]
end
