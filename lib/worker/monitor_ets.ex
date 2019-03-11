defmodule ExRabbitPool.Worker.MonitorEts do
  use GenServer

  require Logger

  @name __MODULE__
  @tab :monitors_tab

  #########
  ## API
  #########

  def start_link(opts \\ []) do
    GenServer.start_link(@name, :ok, opts ++ [name: @name])
  end

  @doc false
  def get_monitors do
    monitors = monitors()
  end

  @doc false
  def add(monitor) do
    monitors_ets = monitors()
    true = :ets.insert(@tab, {:monitors, [monitor|monitors_ets]})
  end

  @doc false
  def remove_monitor(pid) do
    monitors_ets = monitors()
    remove_monitor(monitors_ets, pid)
  end

  ######################
  ## Server Callbacks
  ######################

  @impl true
  def init(:ok) do
    :ets.new(@tab, [:set, :named_table, :public, read_concurrency: true,
                                                 write_concurrency: true])
    true = :ets.insert(@tab, {:monitors, []})
    {:ok, %{}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.error("Unexpected message at MonitorEts: #{msg}")
    {:noreply, state}
  end

  ##############
  ## Internal
  ##############

  defp monitors do
    [monitors: monitors_ets] = :ets.lookup(@tab, :monitors)
    monitors_ets
  end

  defp remove_monitor(monitors, client_ref) when is_reference(client_ref) do
    monitors
    |> Enum.find(fn {ref, _} -> client_ref == ref end)
    |> case do
      nil ->
        monitors

      {ref, _channel} = returned ->
        true = Process.demonitor(ref)
        true = :ets.insert(@tab, {:monitors, List.delete(monitors, returned)})
        List.delete(monitors, returned)
    end
  end

  defp remove_monitor(monitors, channel_pid) when is_pid(channel_pid) do
    monitors
    |> Enum.find(fn {_ref, %{pid: pid}} ->
      channel_pid == pid
    end)
    |> case do
      nil ->
        monitors

      {ref, _} = returned ->
        true = Process.demonitor(ref)
        true = :ets.insert(@tab, {:monitors, List.delete(monitors, returned)})
        List.delete(monitors, returned)
    end
  end
end
