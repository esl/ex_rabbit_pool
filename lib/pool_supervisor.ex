defmodule ExRabbitPool.PoolSupervisor do
  use Supervisor

  @type config :: [rabbitmq_config: keyword(), connection_pools: list()]

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
      for pool_config <- Keyword.get(config, :connection_pools, []) do
        rabbitmq_config = Keyword.get(config, :rabbitmq_config, [])
        {_, pool_id} = Keyword.fetch!(pool_config, :name)
        # We are using poolboy's pool as a fifo queue so we can distribute the
        # load between workers
        pool_config = Keyword.merge(pool_config, strategy: :fifo)
        :poolboy.child_spec(pool_id, pool_config, rabbitmq_config)
      end

    # if the pool of rabbit connection crashes, try to setup the queues again
    opts = [strategy: :rest_for_one]
    Supervisor.init(children, opts)
  end
end
