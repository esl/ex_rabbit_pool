defmodule Example.EchoConsumer do
  use GenServer

  require Logger

  defmodule State do
    @moduledoc """
    RabbitMQ Consumer Worker State.

    State attributes:

      * `:pool_id` - the name of the connection pool to RabbitMQ
      * `:channel` - the RabbitMQ channel for consuming new messages
      * `:monitor` - a monitor for handling channel crashes
      * `:queue` - the name of the queue to consume
      * `:consumer_tag` - the consumer tag assigned by RabbitMQ
      * `:config` - the consumer configuration attributes
      * `:adapter` - the RabbitMQ client to use
    """
    @enforce_keys [:pool_id]

    @typedoc "Consumer State Type"
    @type t :: %__MODULE__{
            pool_id: atom(),
            channel: AMQP.Channel.t(),
            monitor: reference(),
            queue: String.t(),
            consumer_tag: String.t(),
            config: keyword(),
            adapter: module()
          }
    defstruct pool_id: nil,
              caller: nil,
              channel: nil,
              monitor: nil,
              queue: nil,
              consumer_tag: nil,
              config: [],
              adapter: nil
  end

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  ####################
  # Server Callbacks #
  ####################

  @impl true
  def init(config) do
    {opts, consumer_config} = Keyword.split(config, [:adapter, :pool_id, :queue])
    adapter = Keyword.get(opts, :adapter, ExRabbitPool.RabbitMQ)
    pool_id = Keyword.fetch!(opts, :pool_id)
    queue = Keyword.fetch!(opts, :queue)
    send(self(), :connect)

    {:ok,
     %State{
       pool_id: pool_id,
       queue: queue,
       adapter: adapter,
       config: consumer_config
     }}
  end

  # Gets a connection worker out of the connection pool, if there is one available
  # takes a channel out of it channel pool, if there is one available subscribe
  # itself as a consumer process.
  @impl true
  def handle_info(:connect, %{pool_id: pool_id} = state) do
    pool_id
    |> ExRabbitPool.get_connection_worker()
    |> ExRabbitPool.checkout_channel()
    |> handle_channel_checkout(state)
  end

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, chan_pid, reason},
        %{monitor: monitor, channel: %{pid: chan_pid}} = state
      ) do
    Logger.error("[consumer] channel down reason: #{inspect(reason)}")
    schedule_connect()
    {:noreply, %State{state | monitor: nil, consumer_tag: nil, channel: nil}}
  end

  ################################
  # AMQP Basic.Consume Callbacks #
  ################################

  # Confirmation sent by the broker after registering this process as a consumer
  @impl true
  def handle_info({:basic_consume_ok, %{consumer_tag: _consumer_tag}}, state) do
    Logger.info("[consumer] successfully registered as a consumer (basic_consume_ok)")
    {:noreply, state}
  end

  # This is sent for each message consumed, where `payload` contains the message
  # content and `meta` contains all the metadata set when sending with
  # Basic.publish or additional info set by the broker;
  @impl true
  def handle_info(
        {:basic_deliver, payload, %{delivery_tag: delivery_tag}},
        %{channel: channel, adapter: adapter} = state
      ) do
    Logger.info("[consumer] consuming payload (#{inspect payload})")
    :ok = adapter.ack(channel, delivery_tag, requeue: false)
    {:noreply, state}
  end

  # Sent by the broker when the consumer is unexpectedly cancelled (such as after a queue deletion)
  @impl true
  def handle_info({:basic_cancel, %{consumer_tag: _consumer_tag}}, state) do
    Logger.error("[consumer] consumer was cancelled by the broker (basic_cancel)")
    {:stop, :normal, %State{state | channel: nil}}
  end

  # Confirmation sent by the broker to the consumer process after a Basic.cancel
  @impl true
  def handle_info({:basic_cancel_ok, %{consumer_tag: _consumer_tag}}, state) do
    Logger.error("[consumer] consumer was cancelled by the broker (basic_cancel_ok)")
    {:stop, :normal, %State{state | channel: nil}}
  end

  # When successfully checks out a channel, subscribe itself as a consumer
  # process and monitors it handle crashes and reconnections
  defp handle_channel_checkout(
         {:ok, %{pid: channel_pid} = channel},
         %{config: config, queue: queue, adapter: adapter} = state
       ) do
    config = Keyword.get(config, :options, [])

    case adapter.consume(channel, queue, self(), config) do
      {:ok, consumer_tag} ->
        ref = Process.monitor(channel_pid)
        {:noreply, %State{state | channel: channel, monitor: ref, consumer_tag: consumer_tag}}

      {:error, reason} ->
        Logger.error("[consumer] error consuming channel reason: #{inspect(reason)}")
        schedule_connect()
        {:noreply, %State{state | channel: nil, consumer_tag: nil}}
    end
  end

  # When there was an error checking out a channel, retry in a configured interval
  defp handle_channel_checkout({:error, reason}, state) do
    Logger.error("[consumer] error getting channel reason: #{inspect(reason)}")
    schedule_connect()
    {:noreply, state}
  end

  defp schedule_connect do
    Process.send_after(self(), :connect, 1000)
  end
end

rabbitmq_config = [channels: 2]

rabbitmq_conn_pool = [
  name: {:local, :connection_pool},
  worker_module: ExRabbitPool.Worker.RabbitConnection,
  size: 1,
  max_overflow: 0
]

{:ok, pid} =
  ExRabbitPool.PoolSupervisor.start_link(
    rabbitmq_config: rabbitmq_config,
    rabbitmq_conn_pool: rabbitmq_conn_pool
  )

queue = "ex_rabbit_pool"
exchange = "my_exchange"
routing_key = "example"

ExRabbitPool.with_channel(:connection_pool, fn {:ok, channel} ->
  {:ok, _} = AMQP.Queue.declare(channel, queue, auto_delete: true, exclusive: true)
  :ok = AMQP.Exchange.declare(channel, exchange, :direct, auto_delete: true, exclusive: true)
  :ok = AMQP.Queue.bind(channel, queue, exchange, routing_key: routing_key)
end)

{:ok, consumer_pid} = Example.EchoConsumer.start_link(pool_id: :connection_pool, queue: queue)

ExRabbitPool.with_channel(:connection_pool, fn {:ok, channel} ->
  :ok = AMQP.Basic.publish(channel, exchange, routing_key, "Hello World!")
  :ok = AMQP.Basic.publish(channel, exchange, routing_key, "Hell Yeah!")
end)
