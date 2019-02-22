defmodule ExRabbitPool.Worker.SetupQueue do
  use GenServer, restart: :transient

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  def init({pool_id, rabbitmq_config}) do
    setup_queues(pool_id, rabbitmq_config)
    :ignore
  end

  defp setup_queues(pool_id, rabbitmq_config) do
    adapter = rabbitmq_config |> Keyword.get(:adapter, ExRabbitPool.RabbitMQ)
    queues = rabbitmq_config |> Keyword.get(:queues, [])

    for queue_config <- queues do
      queue_name = queue_config |> Keyword.fetch!(:queue_name)
      exchange = queue_config |> Keyword.fetch!(:exchange)
      # Fail if couldn't create queue
      ExRabbitPool.create_queue_with_bind(adapter, pool_id, queue_name, exchange, queue_config)
      |> case do
        :ok ->
          :ok

        error ->
          raise error
      end
    end
  end
end
