defmodule ExRabbitPool.ConsumerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias ExRabbitPool.Worker.SetupQueue
  alias ExRabbitPool.RabbitMQ
  alias AMQP.Queue
  require Logger

  @moduletag :integration

  defmodule TestConsumer do
    use ExRabbitPool.Consumer

    def setup_channel(%{adapter: adapter, config: config}, channel) do
      config = Keyword.get(config, :options, [])
      Logger.warn("Setting up channel with options: #{inspect(config)}")
      adapter.qos(channel, config)
    end

    def basic_deliver(%{adapter: adapter, channel: channel}, _payload, %{delivery_tag: tag}) do
      :ok = adapter.ack(channel, tag)
    end
  end

  defmodule TestConsumerDelayedAck do
    use ExRabbitPool.Consumer

    def setup_channel(%{adapter: adapter, config: config}, channel) do
      config = Keyword.get(config, :options, [])
      Logger.warn("Setting up channel with options: #{inspect(config)}")
      adapter.qos(channel, config)
    end

    def basic_deliver(%{adapter: adapter, channel: channel}, _payload, %{delivery_tag: tag}) do
      Task.async(fn ->
        Process.sleep(3000)
        adapter.ack(channel, tag)
      end)

      :ok
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

  def wait_for(timeout \\ 1000, f)
  def wait_for(0, _), do: {:error, "Error - Timeout"}

  def wait_for(timeout, f) do
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
           [rabbitmq_config: rabbitmq_config, connection_pools: [rabbitmq_conn_pool]],
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
    logs =
      capture_log(fn ->
        pid =
          start_supervised!(
            {TestConsumer, pool_id: pool_id, queue: queue, options: [prefetch_count: 19]}
          )

        :erlang.trace(pid, true, [:receive])

        ExRabbitPool.with_channel(pool_id, fn {:ok, channel} ->
          assert :ok = RabbitMQ.publish(channel, "#{queue}_exchange", "", "Hello Consumer!")
          assert_receive {:trace, ^pid, :receive, {:basic_deliver, "Hello Consumer!", _}}, 1000
          {:ok, result} = Queue.status(channel, queue)
          assert result == %{consumer_count: 1, message_count: 0, queue: queue}
        end)
      end)

    assert logs =~ "Setting up channel with options: [prefetch_count: 19]"
  end

  test "consumable messages should not exceed prefetch_count", %{pool_id: pool_id, queue: queue} do
    logs =
      capture_log(fn ->
        pid =
          start_supervised!(
            {TestConsumerDelayedAck, pool_id: pool_id, queue: queue, options: [prefetch_count: 2]}
          )

        :erlang.trace(pid, true, [:receive])

        ExRabbitPool.with_channel(pool_id, fn {:ok, channel} ->
          assert :ok = RabbitMQ.publish(channel, "#{queue}_exchange", "", "Hello Consumer 1!")
          assert :ok = RabbitMQ.publish(channel, "#{queue}_exchange", "", "Hello Consumer 2!")
          assert :ok = RabbitMQ.publish(channel, "#{queue}_exchange", "", "Hello Consumer 3!")
          assert_receive {:trace, ^pid, :receive, {:basic_deliver, "Hello Consumer 1!", _}}, 1000
          assert_receive {:trace, ^pid, :receive, {:basic_deliver, "Hello Consumer 2!", _}}, 1000
          refute_receive {:trace, ^pid, :receive, {:basic_deliver, "Hello Consumer 3!", _}}, 1000

          assert :ok ==
                   wait_for(fn ->
                     {:ok, result} = Queue.status(channel, queue)
                     result == %{consumer_count: 1, message_count: 1, queue: queue}
                   end)
        end)
      end)

    assert logs =~ "Setting up channel with options: [prefetch_count: 2]"
  end

  test "should be able to consume messages out of rabbitmq with default consumer", %{
    pool_id: pool_id,
    queue: queue
  } do
    pid = start_supervised!({TestDefaultConsumer, pool_id: pool_id, queue: queue})
    Process.group_leader(pid, self())
    :erlang.trace(pid, true, [:receive])

    ExRabbitPool.with_channel(pool_id, fn {:ok, channel} ->
      assert :ok = RabbitMQ.publish(channel, "#{queue}_exchange", "", "Hello Consumer!")
      assert_receive {:trace, ^pid, :receive, {:basic_deliver, "Hello Consumer!", _}}, 1000

      assert_receive {:io_request, ^pid, _,
                      {:put_chars, :unicode, "[*] RabbitMQ message received: Hello Consumer!\n"}}

      {:ok, result} = Queue.status(channel, queue)
      assert result == %{consumer_count: 1, message_count: 0, queue: queue}
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
    assert :ok = wait_for(fn -> !Process.alive?(consumer_pid) end)
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

    assert :ok = wait_for(fn -> !Process.alive?(consumer_pid) end)
  end
end
