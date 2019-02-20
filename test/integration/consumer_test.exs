defmodule ExRabbitPool.ConsumerTest do
  use ExUnit.Case, async: false

  alias ExRabbitPool.Worker.SetupQueue

  @moduletag :integration

  defmodule TestConsumer do
    use ExRabbitPool.Consumer

    def basic_consume_ok(_state, _consumer_tag), do: :ok

    def basic_deliver(%{adapter: adapter, channel: channel}, _payload, %{delivery_tag: tag}) do
      :ok = adapter.ack(channel, tag)
    end

    def basic_cancel(_state, _consumer_tag, _no_wait), do: :ok

    def basic_cancel_ok(_state, _consumer_tag), do: :ok
  end

  defmodule TestConsumerDefaultDeliver do
    use ExRabbitPool.Consumer

    def basic_consume_ok(_state, _consumer_tag), do: :ok

    def basic_cancel(_state, _consumer_tag, _no_wait), do: :ok

    def basic_cancel_ok(_state, _consumer_tag), do: :ok
  end

  defp random_queue_name() do
    rnd =
      8
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64()
      |> binary_part(0, 8)

    "test.queue-" <> rnd
  end

  defp wait_for(timeout \\ 1000, f)
  defp wait_for(0, _), do: {:error, "Error - Timeout"}

  defp wait_for(timeout, f) do
    if f.() do
      :ok
    else
      :timer.sleep(10)
      wait_for(timeout - 10, f)
    end
  end

  setup do
    queue = random_queue_name()

    rabbitmq_config = [
      channels: 2,
      port: String.to_integer(System.get_env("EX_RABBIT_POOL_PORT") || "5672")
    ]

    rabbitmq_conn_pool = [
      name: {:local, :setup_queue_pool},
      worker_module: ExRabbitPool.Worker.RabbitConnection,
      size: 1,
      max_overflow: 0
    ]

    start_supervised!(%{
      id: ExRabbitPool.PoolSupervisorTest,
      start:
        {ExRabbitPool.PoolSupervisor, :start_link,
         [
           [rabbitmq_config: rabbitmq_config, rabbitmq_conn_pool: rabbitmq_conn_pool],
           ExRabbitPool.PoolSupervisorTest
         ]},
      type: :supervisor
    })

    start_supervised!(
      {SetupQueue,
       {:setup_queue_pool,
        [
          queues: [
            [
              queue_name: queue,
              exchange: "#{queue}_exchange",
              queue_options: [auto_delete: true],
              exchange_options: [auto_delete: true]
            ]
          ]
        ]}}
    )

    {:ok, pool_id: :setup_queue_pool, queue: queue}
  end

  test "should be able to consume messages out of rabbitmq", %{pool_id: pool_id, queue: queue} do
    start_supervised!({TestConsumer, pool_id: pool_id, queue: queue})

    ExRabbitPool.with_channel(pool_id, fn {:ok, channel} ->
      assert :ok = AMQP.Basic.publish(channel, "#{queue}_exchange", "", "Hello Consumer!")

      assert :ok =
               wait_for(fn ->
                 {:ok, result} = AMQP.Queue.status(channel, queue)
                 result == %{consumer_count: 1, message_count: 0, queue: queue}
               end)
    end)
  end

  @tag capture_io: true
  test "should be able to consume messages out of rabbitmq with default consumer", %{pool_id: pool_id, queue: queue} do
    start_supervised!({TestConsumerDefaultDeliver, pool_id: pool_id, queue: queue})

    ExRabbitPool.with_channel(pool_id, fn {:ok, channel} ->
      assert :ok = AMQP.Basic.publish(channel, "#{queue}_exchange", "", "Hello Consumer!")

      assert :ok =
               wait_for(fn ->
                 {:ok, result} = AMQP.Queue.status(channel, queue)
                 result == %{consumer_count: 1, message_count: 0, queue: queue}
               end)
    end)
  end

  @tag capture_log: true
  test "should terminate consumer after Basic.cancel", %{pool_id: pool_id, queue: queue} do
    consumer_pid =
      start_supervised!({TestConsumer, pool_id: pool_id, queue: queue}, restart: :temporary)

    %{channel: channel, consumer_tag: consumer_tag} = :sys.get_state(consumer_pid)
    {:ok, ^consumer_tag} = AMQP.Basic.cancel(channel, consumer_tag)
    assert :ok = wait_for(fn -> !Process.alive?(consumer_pid) end)
  end
end
