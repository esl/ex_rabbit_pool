defmodule ExRabbitPool.Integration.SetupQueueTest do
  use ExUnit.Case, async: false

  alias ExRabbitPool.Worker.SetupQueue

  @moduletag :integration

  defp random_queue_name() do
    rnd =
      8
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64()
      |> binary_part(0, 8)

    "test.queue-" <> rnd
  end

  setup do
    caller = self()

    rabbitmq_config = [
      channels: 1,
      port: String.to_integer(System.get_env("EX_RABBIT_POOL_PORT") || "5672"),
      caller: caller
    ]

    rabbitmq_conn_pool = [
      :rabbitmq_conn_pool,
      pool_id: :setup_queue_pool,
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

    {:ok, pool_id: :setup_queue_pool, queue1: random_queue_name(), queue2: random_queue_name()}
  end

  test "declare queue on startup", %{pool_id: pool_id, queue1: queue1, queue2: queue2} do
    start_supervised!(
      {SetupQueue,
       {pool_id,
        [
          queues: [
            [
              queue_name: queue1,
              exchange: "my_exchange",
              queue_options: [auto_delete: true],
              exchange_options: [auto_delete: true]
            ],
            [
              queue_name: queue2,
              exchange: "my_exchange2",
              queue_options: [auto_delete: true],
              exchange_options: [auto_delete: true]
            ]
          ]
        ]}}
    )

    ExRabbitPool.with_channel(pool_id, fn {:ok, channel} ->
      assert :ok = AMQP.Basic.publish(channel, "my_exchange", "", "Hello, World!")
      assert {:ok, "Hello, World!", _meta} = AMQP.Basic.get(channel, queue1, no_ack: true)

      assert :ok = AMQP.Basic.publish(channel, "my_exchange2", "", "Hell Yeah!")
      assert {:ok, "Hell Yeah!", _meta} = AMQP.Basic.get(channel, queue2, no_ack: true)

      assert {:ok, _} = AMQP.Queue.delete(channel, queue1)
      assert {:ok, _} = AMQP.Queue.delete(channel, queue2)
    end)
  end

  test "declare queues with multiple bindings on startup", %{
    pool_id: pool_id,
    queue1: queue1,
    queue2: queue2
  } do
    start_supervised!(
      {SetupQueue,
       {pool_id,
        [
          queues: [
            [
              queue_name: queue1,
              exchange: "X",
              queue_options: [auto_delete: true],
              exchange_options: [auto_delete: true],
              bind_options: [routing_key: "orange"]
            ],
            [
              queue_name: queue2,
              exchange: "X",
              queue_options: [auto_delete: true],
              exchange_options: [auto_delete: true],
              bind_options: [routing_key: "black"]
            ],
            [
              queue_name: queue2,
              exchange: "X",
              queue_options: [auto_delete: true],
              exchange_options: [auto_delete: true],
              bind_options: [routing_key: "green"]
            ]
          ]
        ]}}
    )

    ExRabbitPool.with_channel(pool_id, fn {:ok, channel} ->
      assert :ok = AMQP.Basic.publish(channel, "X", "orange", "Hello, World!")
      assert {:ok, "Hello, World!", _meta} = AMQP.Basic.get(channel, queue1, no_ack: true)

      assert :ok = AMQP.Basic.publish(channel, "X", "black", "Hola Mundo!")
      assert {:ok, "Hola Mundo!", _meta} = AMQP.Basic.get(channel, queue2, no_ack: true)

      assert :ok = AMQP.Basic.publish(channel, "X", "green", "Olá Mundo!")
      assert {:ok, "Olá Mundo!", _meta} = AMQP.Basic.get(channel, queue2, no_ack: true)

      assert {:ok, _} = AMQP.Queue.delete(channel, queue1)
      assert {:ok, _} = AMQP.Queue.delete(channel, queue2)
    end)
  end

  test "declare queue with fanout exchange", %{pool_id: pool_id, queue1: queue1, queue2: queue2} do
    start_supervised!(
      {SetupQueue,
       {pool_id,
        [
          queues: [
            [
              queue_name: queue1,
              exchange: "my_exchange",
              queue_options: [auto_delete: true],
              exchange_options: [auto_delete: true, type: :fanout]
            ],
            [
              queue_name: queue2,
              exchange: "my_exchange",
              queue_options: [auto_delete: true],
              exchange_options: [auto_delete: true, type: :fanout]
            ]
          ]
        ]}}
    )

    ExRabbitPool.with_channel(pool_id, fn {:ok, channel} ->
      assert :ok = AMQP.Basic.publish(channel, "my_exchange", "", "Hello, World!")
      assert {:ok, "Hello, World!", _meta} = AMQP.Basic.get(channel, queue1, no_ack: true)
      assert {:ok, "Hello, World!", _meta} = AMQP.Basic.get(channel, queue2, no_ack: true)
      assert {:ok, _} = AMQP.Queue.delete(channel, queue1)
      assert {:ok, _} = AMQP.Queue.delete(channel, queue2)
    end)
  end
end
