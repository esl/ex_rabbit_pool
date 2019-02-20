defmodule Example.EchoConsumer do
  use ExRabbitPool.Consumer

  require Logger

  ################################
  # AMQP Basic.Consume Callbacks #
  ################################

  # Confirmation sent by the broker after registering this process as a consumer
  def basic_consume_ok(_adapter, _channel, _consumer_tag) do
    Logger.info("[consumer] successfully registered as a consumer (basic_consume_ok)")
    :ok
  end

  # This is sent for each message consumed, where `payload` contains the message
  # content and `meta` contains all the metadata set when sending with
  # Basic.publish or additional info set by the broker;
  def basic_deliver(adapter, channel, payload, %{delivery_tag: delivery_tag}) do
    Logger.info("[consumer] consuming payload (#{inspect payload})")
    :ok = adapter.ack(channel, delivery_tag, requeue: false)
    :ok
  end

  # Sent by the broker when the consumer is unexpectedly cancelled (such as after a queue deletion)
  def basic_cancel(_adapter, _channel, _consumer_tag, _no_wait) do
    Logger.error("[consumer] consumer was cancelled by the broker (basic_cancel)")
    :ok
  end

  # Confirmation sent by the broker to the consumer process after a Basic.cancel
  def basic_cancel_ok(_adapter, _channel, _consumer_tag) do
    Logger.error("[consumer] consumer was cancelled by the broker (basic_cancel_ok)")
    :ok
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
