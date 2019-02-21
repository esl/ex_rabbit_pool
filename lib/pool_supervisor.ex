defmodule ExRabbitPool.PoolSupervisor do
  use Supervisor

  alias ExRabbitPool.Worker.SetupQueue

  @type config :: [rabbitmq_config: keyword(), rabbitmq_conn_pool: keyword()]

  @spec start_link(config()) :: Supervisor.on_start()
  def start_link(config) do
    Supervisor.start_link(__MODULE__, config)
  end

  @spec start_link(config(), atom()) :: Supervisor.on_start()
  def start_link(config, name) do
    Supervisor.start_link(__MODULE__, config, name: name)
  end

  @impl true
  def init(config) do
    children =
      case Keyword.get(config, :rabbitmq_conn_pool) do
        [] ->
          []

        rabbitmq_conn_pool ->
          rabbitmq_config = Keyword.get(config, :rabbitmq_config, [])
          {_, pool_id} = Keyword.fetch!(rabbitmq_conn_pool, :name)
          # We are using poolboy's pool as a fifo queue so we can distribute the
          # load between workers
          rabbitmq_conn_pool = Keyword.merge(rabbitmq_conn_pool, strategy: :fifo)
          [
            :poolboy.child_spec(pool_id, rabbitmq_conn_pool, rabbitmq_config),
            {SetupQueue, {pool_id, rabbitmq_config}}
          ]
      end

    # if the pool of rabbit connection crashes, try to setup the queues again
    opts = [strategy: :rest_for_one]
    Supervisor.init(children, opts)
  end
end
