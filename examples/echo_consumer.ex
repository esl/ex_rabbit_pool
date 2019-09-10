defmodule Example.EchoConsumer do
  use ExRabbitPool.Consumer

  require Logger

  ################################
  # AMQP Basic.Consume Callbacks #
  ################################

  # Confirmation sent by the broker after registering this process as a consumer
  def basic_consume_ok(_state, _consumer_tag) do
    Logger.info("[consumer] successfully registered as a consumer (basic_consume_ok)")
    :ok
  end

  # This is sent for each message consumed, where `payload` contains the message
  # content and `meta` contains all the metadata set when sending with
  # Basic.publish or additional info set by the broker;
  def basic_deliver(%{adapter: adapter, channel: channel}, payload, %{delivery_tag: delivery_tag}) do
    Logger.info("[consumer] consuming payload (#{inspect payload})")
    :ok = adapter.ack(channel, delivery_tag, requeue: false)
    :ok
  end

  # Sent by the broker when the consumer is unexpectedly cancelled (such as after a queue deletion)
  def basic_cancel(_state, _consumer_tag, _no_wait) do
    Logger.error("[consumer] consumer was cancelled by the broker (basic_cancel)")
    :ok
  end

  # Confirmation sent by the broker to the consumer process after a Basic.cancel
  def basic_cancel_ok(_state, _consumer_tag) do
    Logger.error("[consumer] consumer was cancelled by the broker (basic_cancel_ok)")
    :ok
  end
end
