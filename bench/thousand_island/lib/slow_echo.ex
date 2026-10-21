# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0

defmodule TiNode.SlowEcho do
  @moduledoc """
  Echo after sleeping `handler_options` milliseconds, as Catalina's
  `SlowEcho`; for the lifecycle stress tests.
  """
  use ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    if is_integer(state), do: Process.sleep(state)
    ThousandIsland.Socket.send(socket, data)
    {:continue, state}
  end
end
