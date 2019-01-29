defmodule BugsBunny.Worker.SetupQueue do
  use GenServer, restart: :temporary

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  def init({pool_id, rabbitmq_config}) do
    adapter = rabbitmq_config |> Keyword.get(:adapter, BugsBunny.RabbitMQ)
    queue = rabbitmq_config |> Keyword.fetch!(:queue)
    exchange = rabbitmq_config |> Keyword.fetch!(:exchange)
    queue_options = rabbitmq_config |> Keyword.get(:queue_options, [])
    exchange_options = rabbitmq_config |> Keyword.get(:exchange_options, [])

    BugsBunny.create_queue_with_bind(adapter, pool_id, queue, exchange, :direct,
      queue_options: queue_options,
      exchange_options: exchange_options
    )
    |> case do
      :ok -> :ignore
      {:error, _} = error -> {:stop, error}
    end
  end
end
