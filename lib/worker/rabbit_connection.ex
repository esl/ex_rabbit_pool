defmodule ExRabbitPool.Worker.RabbitConnection do
  use GenServer

  require Logger
  alias ExRabbitPool.Worker.MonitorEts

  @reconnect_interval 1_000
  @default_channels 10

  defmodule State do
    @type config :: keyword() | String.t()

    @enforce_keys [:config]
    @type t :: %__MODULE__{
            adapter: module(),
            connection: AMQP.Connection.t(),
            channels: list(AMQP.Channel.t()),
            config: config()
          }

    defstruct adapter: ExRabbitPool.RabbitMQ,
              connection: nil,
              channels: [],
              config: nil
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
    if Process.alive?(connection.pid) do
      {:reply, {:ok, connection}, state}
    else
      {:reply, {:ok, :disconnected}, state}
    end
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
        {from_pid, _ref}, %{channels: [channel | rest]} = state
      ) do
    monitor_ref = Process.monitor(from_pid)
    :ok = MonitorEts.add({monitor_ref, channel})
    {:reply, {:ok, channel}, %State{state | channels: rest}}
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

  # When checkin back a channel to the pool is a good practice to not re-use
  # channels, so, we need to remove it from the channel list, unlink it and
  # start a new one
  @impl true
  def handle_cast(
        {:checkin_channel, %{pid: pid} = channel},
        %{connection: conn, adapter: adapter, channels: channels} = state
      ) do
    # only start a new channel when checkin back a channel that isn't removed yet
    # this can happen when a channel crashed or is closed when a client holds it
    # so we get an `:EXIT` message and a `:checkin_channel` message in no given
    # order
    if find_channel(pid, channels, MonitorEts.get_monitors()) do
      new_channels = remove_channel(channels, pid)
      MonitorEts.remove_monitor(pid)
      true = Process.unlink(pid)
      # ommit the result
      adapter.close_channel(channel)

      case start_channel(adapter, conn) do
        {:ok, channel} ->
          true = Process.link(channel.pid)
          {:noreply, %State{state | channels: [channel | new_channels]}}

        {:error, :closing} ->
          # RabbitMQ Connection is closed. nothing to do, wait for reconnection
          {:noreply, %State{state | channels: new_channels}}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:connect, %{adapter: adapter, config: config} = state) do
    # TODO: add exponential backoff for reconnects
    # TODO: stop the worker when we couldn't reconnect several times
    case adapter.open_connection(config) do
      {:error, reason} ->
        Logger.error("[Rabbit] error opening a connection reason: #{inspect(reason)}")
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

  # Connection crashed/closed
  @impl true
  def handle_info({:EXIT, pid, reason}, %{connection: %{pid: pid}, config: config} = state) do
    Logger.error("[Rabbit] connection lost, attempting to reconnect reason: #{inspect(reason)}")
    # TODO: use exponential backoff to reconnect
    # TODO: use circuit breaker to fail fast
    schedule_connect(config)
    {:noreply, %State{state | connection: nil, channels: []}}
  end

  # Connection crashed so channels are going to crash too
  @impl true
  def handle_info(
        {:EXIT, pid, reason},
        %{connection: nil, channels: channels} = state
      ) do
    Logger.error("[Rabbit] connection lost, removing channel reason: #{inspect(reason)}")
    new_channels = remove_channel(channels, pid)
    MonitorEts.remove_monitor(pid)
    {:noreply, %State{state | channels: new_channels}}
  end

  # Channel crashed/closed, Connection crashed/closed
  @impl true
  def handle_info(
        {:EXIT, pid, reason},
        %{channels: channels, connection: conn, adapter: adapter} = state
      ) do
    Logger.warn("[Rabbit] channel lost reason: #{inspect(reason)}")
    # don't start a new channel if crashed channel doesn't belongs to the pool
    # anymore
    if find_channel(pid, channels, MonitorEts.get_monitors()) do
      new_channels = remove_channel(channels, pid)
      MonitorEts.remove_monitor(pid)

      case start_channel(adapter, conn) do
        {:ok, channel} ->
          true = Process.link(channel.pid)
          {:noreply, %State{state | channels: [channel | new_channels]}}

        {:error, :closing} ->
          # RabbitMQ Connection is closed. nothing to do, wait for reconnections
          {:noreply, %State{state | channels: new_channels}}
      end
    else
      {:noreply, state}
    end
  end

  # if client holding a channel fails, then we need to take its channel back
  @impl true
  def handle_info(
        {:DOWN, down_ref, :process, _, _},
        %{channels: channels} = state
      ) do
    MonitorEts.get_monitors()
    |> Enum.find(fn {ref, _chan} ->
      down_ref == ref
    end)
    |> case do
      nil ->
        {:noreply, state}

      {_ref, channel} = returned ->
        MonitorEts.remove_monitor(returned)
        {:noreply, %State{state | channels: [channel | channels]}}
    end
  end

  @impl true
  def terminate(_reason, %{connection: connection, adapter: adapter}) do
    if connection && Process.alive?(connection.pid) do
      adapter.close_connection(connection)
    end
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
    if Process.alive?(connection.pid) do
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
    else
      {:error, :closing}
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

  defp find_channel(channel_pid, channels, monitors) do
    Enum.find(channels, &(&1.pid == channel_pid)) ||
      Enum.find(monitors, fn {_ref, %{pid: pid}} ->
        pid == channel_pid
      end)
  end
end
