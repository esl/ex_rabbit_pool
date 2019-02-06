defmodule ExRabbitPool.Worker.SetupQueue do
  use GenServer, restart: :temporary

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  def init({pool_id, rabbitmq_config}) do
    adapter = rabbitmq_config |> Keyword.get(:adapter, ExRabbitPool.RabbitMQ)
    queues = rabbitmq_config |> Keyword.get(:queues, [])

    for queue_config <- queues do
      queue_name = queue_config |> Keyword.fetch!(:queue_name)
      exchange = queue_config |> Keyword.fetch!(:exchange)
      queue_options = queue_config |> Keyword.get(:queue_options, [])
      exchange_options = queue_config |> Keyword.get(:exchange_options, [])
      bind_options = queue_config |> Keyword.get(:bind_options, [])

      # Fail if couldn't create queue
      :ok =
        ExRabbitPool.create_queue_with_bind(adapter, pool_id, queue_name, exchange, :direct,
          queue_options: queue_options,
          exchange_options: exchange_options,
          bind_options: bind_options
        )
    end

    :ignore
  end
end
