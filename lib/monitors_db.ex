defmodule ExRabbitPool.MonitorsDB do
  @spec new_db() :: :ets.tid()
  def new_db() do
    random_string()
    |> new_db()
  end

  @spec new_db(String.t()) :: :ets.tid()
  def new_db(name) do
    name
    |> String.to_atom()
    |> :ets.new([:set])
  end

  @spec add_monitor(:ets.tid(), {reference(), pid()}) :: true
  def add_monitor(ets, monitor) do
    :ets.insert(ets, monitor)
  end

  @spec remove_monitor(:ets.tid(), pid() | reference()) :: true
  def remove_monitor(ets, channel_pid) when is_pid(channel_pid) do
    match = [{{:_, :"$1"}, [], [{:==, :"$1", {:const, channel_pid}}]}]
    :ets.select_delete(ets, match)
    true
  end

  def remove_monitor(ets, monitor_ref) when is_reference(monitor_ref) do
    :ets.delete(ets, monitor_ref)
  end

  @spec find(:ets.tid(), pid | reference()) :: nil | {reference(), pid()}
  def find(ets, monitor_ref) when is_reference(monitor_ref) do
    case :ets.lookup(ets, monitor_ref) do
      [] -> nil
      [monitor] -> monitor
    end
  end

  def find(ets, pid) when is_pid(pid) do
    match = [{{:"$1", :"$2"}, [{:==, :"$2", {:const, pid}}], [:"$_"]}]

    case :ets.select(ets, match) do
      [] -> nil
      [monitor] -> monitor
    end
  end

  @spec random_string(non_neg_integer()) :: String.t()
  def random_string(length \\ 10) do
    length
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64()
    |> binary_part(0, length)
  end
end
