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

  @spec add_monitor(:ets.tid(), {reference(), AMQP.Channel.t()}) :: true
  def add_monitor(ets, monitor) do
    :ets.insert(ets, monitor)
  end

  @spec remove_monitor(:ets.tid(), pid() | AMQP.Channel.t() | reference()) :: true
  def remove_monitor(ets, monitor_ref) when is_reference(monitor_ref) do
    :ets.delete(ets, monitor_ref)
  end

  def remove_monitor(ets, channel_or_pid) when is_pid(channel_or_pid) or is_map(channel_or_pid) do
    channel_pid =
      case channel_or_pid do
        %{pid: pid} -> pid
        _ -> channel_or_pid
      end

    match = [{{:_, %{pid: :"$1"}}, [], [{:==, :"$1", {:const, channel_pid}}]}]
    :ets.select_delete(ets, match)
    true
  end

  @spec find(:ets.tid(), pid() | AMQP.Channel.t() | reference()) ::
          nil | {reference(), AMQP.Channel.t()}
  def find(ets, monitor_ref) when is_reference(monitor_ref) do
    case :ets.lookup(ets, monitor_ref) do
      [] -> nil
      [monitor] -> monitor
    end
  end

  def find(ets, channel_or_pid) when is_pid(channel_or_pid) or is_map(channel_or_pid) do
    channel_pid =
      case channel_or_pid do
        %{pid: pid} -> pid
        _ -> channel_or_pid
      end

    match = [{{:"$1", %{pid: :"$2"}}, [{:==, :"$2", {:const, channel_pid}}], [:"$_"]}]

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
