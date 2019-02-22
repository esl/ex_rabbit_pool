defmodule ExRabbitPool.ConsumerTest do
  use ExUnit.Case, async: false

  alias ExRabbitPool.Worker.SetupQueue
  alias ExRabbitPool.RabbitMQ
  alias AMQP.Queue
  alias ExRabbitPool.Test.Helpers

  @moduletag :integration

  defmodule TestConsumer do
    use ExRabbitPool.Consumer

    def basic_deliver(%{adapter: adapter, channel: channel}, _payload, %{delivery_tag: tag}) do
      :ok = adapter.ack(channel, tag)
    end
  end

  defmodule TestDefaultConsumer do
    use ExRabbitPool.Consumer
  end

  defp random_queue_name() do
    rnd =
      8
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64()
      |> binary_part(0, 8)

    "test.queue-" <> rnd
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
      assert :ok = RabbitMQ.publish(channel, "#{queue}_exchange", "", "Hello Consumer!")

      assert :ok =
               Helpers.wait_for(fn ->
                 {:ok, result} = Queue.status(channel, queue)
                 result == %{consumer_count: 1, message_count: 0, queue: queue}
               end)
    end)
  end

  @tag capture_io: true
  test "should be able to consume messages out of rabbitmq with default consumer", %{
    pool_id: pool_id,
    queue: queue
  } do
    start_supervised!({TestDefaultConsumer, pool_id: pool_id, queue: queue})

    ExRabbitPool.with_channel(pool_id, fn {:ok, channel} ->
      assert :ok = RabbitMQ.publish(channel, "#{queue}_exchange", "", "Hello Consumer!")

      assert :ok =
               Helpers.wait_for(fn ->
                 {:ok, result} = Queue.status(channel, queue)
                 result == %{consumer_count: 1, message_count: 0, queue: queue}
               end)
    end)
  end

  @tag capture_log: true
  test "should terminate consumer after Basic.cancel (basic_cancel_ok)", %{
    pool_id: pool_id,
    queue: queue
  } do
    consumer_pid =
      start_supervised!({TestConsumer, pool_id: pool_id, queue: queue}, restart: :temporary)

    %{channel: channel, consumer_tag: consumer_tag} = :sys.get_state(consumer_pid)
    {:ok, ^consumer_tag} = RabbitMQ.cancel_consume(channel, consumer_tag)
    assert :ok = Helpers.wait_for(fn -> !Process.alive?(consumer_pid) end)
  end

  @tag capture_log: true
  test "should terminate consumer after queue deletion (basic_cancel)", %{
    pool_id: pool_id,
    queue: queue
  } do
    consumer_pid =
      start_supervised!({TestConsumer, pool_id: pool_id, queue: queue}, restart: :temporary)

    %{consumer_tag: consumer_tag} = :sys.get_state(consumer_pid)

    :erlang.trace(consumer_pid, true, [:receive])

    ExRabbitPool.with_channel(pool_id, fn {:ok, channel} ->
      {:ok, _} = Queue.delete(channel, queue)
    end)

    assert_receive {:trace, ^consumer_pid, :receive,
                    {:basic_cancel, %{consumer_tag: ^consumer_tag, no_wait: true}}},
                   1000

    assert :ok = Helpers.wait_for(fn -> !Process.alive?(consumer_pid) end)
  end
end
