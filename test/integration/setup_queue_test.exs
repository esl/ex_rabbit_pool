defmodule ExRabbitPool.Integration.SetupQueueTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @queue1 "test.queue1"
  @queue2 "test.queue2"

  setup do
    caller = self()

    rabbitmq_config = [
      channels: 1,
      port: String.to_integer(System.get_env("EX_RABBIT_POOL_PORT") || "5672"),
      queues: [
        [
          queue_name: @queue1,
          exchange: "my_exchange",
          queue_options: [auto_delete: true],
          exchange_options: [auto_delete: true]
        ],
        [
          queue_name: @queue2,
          exchange: "my_exchange2",
          queue_options: [auto_delete: true],
          exchange_options: [auto_delete: true]
        ]
      ],
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

    {:ok, pool_id: :setup_queue_pool}
  end

  test "declare queue on startup", %{pool_id: pool_id} do
    ExRabbitPool.with_channel(pool_id, fn {:ok, channel} ->
      assert :ok = AMQP.Basic.publish(channel, "my_exchange", "", "Hello, World!")
      assert {:ok, "Hello, World!", _meta} = AMQP.Basic.get(channel, @queue1)
      assert {:ok, _} = AMQP.Queue.delete(channel, @queue1)

      assert :ok = AMQP.Basic.publish(channel, "my_exchange2", "", "Hell Yeah!")
      assert {:ok, "Hell Yeah!", _meta} = AMQP.Basic.get(channel, @queue2)
      assert {:ok, _} = AMQP.Queue.delete(channel, @queue2)
    end)
  end
end
