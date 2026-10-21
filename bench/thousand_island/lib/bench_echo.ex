# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0

defmodule TiNode.BenchEcho do
  @moduledoc "Echo every packet back, as Catalina's `BenchEcho`."
  use ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    ThousandIsland.Socket.send(socket, data)
    {:continue, state}
  end
end
