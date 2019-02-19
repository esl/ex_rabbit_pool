defmodule ExRabbitPool.Worker.RabbitConnection do
  use GenServer

  require Logger

  @reconnect_interval 1_000
  @default_channels 1_000

  defmodule State do
    @type config :: keyword() | String.t()

    @enforce_keys [:config]
    @type t :: %__MODULE__{
            adapter: module(),
            connection: AMQP.Connection.t(),
            channels: list(AMQP.Channel.t()),
            # TODO: use an ets table to persist the monitors
            monitors: [],
            config: config()
          }

    defstruct adapter: ExRabbitPool.RabbitMQ,
              connection: nil,
              channels: [],
              config: nil,
              monitors: []
  end

  ##############
  # Client API #
  ##############

  @spec start_link(State.config()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, [])
  end

  @spec get_connection(pid()) :: {:ok, AMQP.Connection.t()} | {:error, :disconnected}
  def get_connection(pid) do
    GenServer.call(pid, :conn)
  end

  @spec checkout_channel(pid()) ::
          {:ok, AMQP.Channel.t()}
          | {:error, :disconnected}
          | {:error, :out_of_channels}
  def checkout_channel(pid) do
    GenServer.call(pid, :checkout_channel)
  end

  @spec checkin_channel(pid(), AMQP.Channel.t()) :: :ok
  def checkin_channel(pid, channel) do
    GenServer.cast(pid, {:checkin_channel, channel})
  end

  @spec create_channel(pid()) :: {:ok, AMQP.Channel.t()} | {:error, any()}
  def create_channel(pid) do
    GenServer.call(pid, :create_channel)
  end

  @doc false
  def state(pid) do
    GenServer.call(pid, :state)
  end

  ####################
  # Server Callbacks #
  ####################

  @doc """
  Traps exits so all the linked connection and multiplexed channels can be
  restarted by this worker.
  Triggers an async connection but making sure future calls need to wait
  for the connection to happen before them.

    * `config` is the rabbitmq config settings
  """
  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    send(self(), :connect)

    # split our opts from the ones passed to the amqp client
    {opts, amqp_config} = Keyword.split(config, [:adapter])
    adapter = Keyword.get(opts, :adapter, ExRabbitPool.RabbitMQ)

    {:ok, %State{adapter: adapter, config: amqp_config}}
  end

  @impl true
  def handle_call(:conn, _from, %State{connection: nil} = state) do
    {:reply, {:error, :disconnected}, state}
  end

  @impl true
  def handle_call(:conn, _from, %State{connection: connection} = state) do
    {:reply, {:ok, connection}, state}
  end

  # TODO: improve better pooling of channels
  # TODO: add overflow support
  # TODO: maybe make the checkout_channel call async/sync with GenServer.reply/2
  @impl true
  def handle_call(:checkout_channel, _from, %State{connection: nil} = state) do
    {:reply, {:error, :disconnected}, state}
  end

  @impl true
  def handle_call(:checkout_channel, _from, %{channels: []} = state) do
    {:reply, {:error, :out_of_channels}, state}
  end

  # Checkout a channel out of a channel pool and monitors the client requesting
  # it so we can handle client crashes returning the monitor back to the pool
  @impl true
  def handle_call(
        :checkout_channel,
        {from_pid, _ref},
        %{channels: [channel | rest], monitors: monitors} = state
      ) do
    monitor_ref = Process.monitor(from_pid)

    {:reply, {:ok, channel},
     %State{state | channels: rest, monitors: [{monitor_ref, channel} | monitors]}}
  end

  # Create a channel without linking the worker process to the channel pid, this
  # way clients can create channels on demand without the need of a pool, but
  # they are now in charge of handling channel crashes, connection closing,
  # channel closing, etc.
  @impl true
  def handle_call(:create_channel, _from, %{connection: conn, adapter: adapter} = state) do
    result = start_channel(adapter, conn)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  # Puts back a channel into the channel pool, demonitors the client that was
  # holding it and deletes the monitor from the monitors list
  @impl true
  def handle_cast({:checkin_channel, channel}, %{channels: channels, monitors: monitors} = state) do
    case Enum.find(monitors, fn {_ref, c} -> channel == c end) do
      # checkin unmonitored channel :thinking_face:
      nil ->
        {:noreply, state}

      {ref, _} = returned ->
        true = Process.demonitor(ref)
        new_monitors = List.delete(monitors, returned)
        {:noreply, %State{state | channels: [channel | channels], monitors: new_monitors}}
    end
  end

  @impl true
  def handle_info(:connect, %{adapter: adapter, config: config} = state) do
    # TODO: add exponential backoff for reconnects
    # TODO: stop the worker when we couldn't reconnect several times
    case adapter.open_connection(config) do
      {:error, reason} ->
        Logger.error("[Rabbit] error reason: #{inspect(reason)}")
        # TODO: use exponential backoff to reconnect
        # TODO: use circuit breaker to fail fast
        schedule_connect(config)
        {:noreply, state}

      {:ok, connection} ->
        Logger.info("[Rabbit] connected")
        %{pid: pid} = connection
        # link itself to the connection `pid` to handle connection
        # errors and spawn as many channels as needed based on config
        # defaults to `1_000`
        true = Process.link(pid)

        num_channels = Keyword.get(config, :channels, @default_channels)

        channels =
          do_times(num_channels, 0, fn ->
            {:ok, channel} = start_channel(adapter, connection)
            true = Process.link(channel.pid)

            channel
          end)

        {:noreply, %State{state | connection: connection, channels: channels}}
    end
  end

  # connection crashed
  @impl true
  def handle_info({:EXIT, pid, reason}, %{connection: %{pid: pid}, config: config} = state) do
    Logger.error("[Rabbit] connection lost, attempting to reconnect reason: #{inspect(reason)}")
    # TODO: use exponential backoff to reconnect
    # TODO: use circuit breaker to fail fast
    schedule_connect(config)
    {:noreply, %State{state | connection: nil}}
  end

  # connection crashed so channels are going to crash too
  @impl true
  def handle_info(
        {:EXIT, pid, reason},
        %{connection: nil, channels: channels, monitors: monitors} = state
      ) do
    Logger.error("[Rabbit] connection lost, removing channel reason: #{inspect(reason)}")
    new_channels = remove_channel(channels, pid)
    new_monitors = remove_monitor(monitors, pid)
    {:noreply, %State{state | channels: new_channels, monitors: new_monitors}}
  end

  # connection did not crash but a channel did
  @impl true
  def handle_info(
        {:EXIT, pid, reason},
        %{channels: channels, connection: conn, adapter: adapter, monitors: monitors} = state
      ) do
    Logger.error("[Rabbit] channel lost, attempting to reconnect reason: #{inspect(reason)}")
    # TODO: use exponential backoff to reconnect
    # TODO: use circuit breaker to fail fast
    new_channels = remove_channel(channels, pid)
    new_monitors = remove_monitor(monitors, pid)
    {:ok, channel} = start_channel(adapter, conn)
    true = Process.link(channel.pid)
    {:noreply, %State{state | channels: [channel | new_channels], monitors: new_monitors}}
  end

  # if client holding a channel fails, then we need to take its channel back
  @impl true
  def handle_info(
        {:DOWN, down_ref, :process, _, _},
        %{channels: channels, monitors: monitors} = state
      ) do
    monitors
    |> Enum.find(fn {ref, _chan} ->
      down_ref == ref
    end)
    |> case do
      nil ->
        {:noreply, state}

      {_ref, channel} = returned ->
        new_monitors = List.delete(monitors, returned)
        {:noreply, %State{state | channels: [channel | channels], monitors: new_monitors}}
    end
  end

  @impl true
  def terminate(_reason, %{connection: connection, adapter: adapter}) do
    try do
      adapter.close_connection(connection)
    catch
      _, _ -> :ok
    end
  end

  def terminate(_reason, _state) do
    :ok
  end

  #############
  # Internals #
  #############

  defp schedule_connect(config) do
    interval = get_reconnect_interval(config)
    Process.send_after(self(), :connect, interval)
  end

  # Opens a channel using the specified client, each channel is backed by a
  # GenServer process, so we need to link the worker to all those processes
  # to be able to restart them when closed or when they crash e.g by a
  # connection error
  # TODO: maybe start channels on demand as needed and store them in the state for re-use
  @spec start_channel(module(), AMQP.Connection.t()) :: {:ok, AMQP.Channel.t()} | {:error, any()}
  defp start_channel(client, connection) do
    case client.open_channel(connection) do
      {:ok, _channel} = result ->
        Logger.info("[Rabbit] channel connected")
        result

      {:error, reason} = error ->
        Logger.error("[Rabbit] error starting channel reason: #{inspect(reason)}")
        error

      error ->
        Logger.error("[Rabbit] error starting channel reason: #{inspect(error)}")
        {:error, error}
    end
  end

  defp get_reconnect_interval(config) do
    Keyword.get(config, :reconnect_interval, @reconnect_interval)
  end

  @spec do_times(non_neg_integer(), non_neg_integer(), (() -> any())) :: [any()]
  defp do_times(limit, counter, _function) when counter >= limit, do: []

  defp do_times(limit, counter, function) do
    [function.() | do_times(limit, 1 + counter, function)]
  end

  defp remove_channel(channels, channel_pid) do
    Enum.filter(channels, fn %{pid: pid} ->
      channel_pid != pid
    end)
  end

  defp remove_monitor(monitors, channel_pid) when is_pid(channel_pid) do
    monitors
    |> Enum.find(fn {_ref, %{pid: pid}} ->
      channel_pid == pid
    end)
    |> case do
      # if nil means DOWN message already handled and monitor already removed
      nil ->
        monitors

      {ref, _} = returned ->
        true = Process.demonitor(ref)
        List.delete(monitors, returned)
    end
  end

  defp remove_monitor(monitors, client_ref) when is_reference(client_ref) do
    monitors
    |> Enum.find(fn {ref, _} ->
      client_ref == ref
    end)
    |> case do
      # if nil means DOWN message already handled and monitor already removed
      nil ->
        monitors

      {ref, _channel} = returned ->
        true = Process.demonitor(ref)
        List.delete(monitors, returned)
    end
  end
end
