defmodule BugsBunny do
  alias BugsBunny.Worker.RabbitConnection, as: Conn

  @type f :: ({:ok, AMQP.Channel.t()} | {:error, :disconected | :out_of_channels} -> any())

  @doc """
  Gets a connection from a connection worker so any client can exec commands
  manually
  """
  @spec get_connection(atom()) :: {:ok, AMQP.Connection.t()} | {:error, :disconnected}
  def get_connection(pool_id) do
    :poolboy.transaction(pool_id, &Conn.get_connection/1)
  end

  @doc """
  Executes function f in the context of a channel, takes a connection worker
  out of the pool, put that connection worker back into the pool so any
  other concurrent client can have access to it, checks out a channel out of
  the worker's channel pool, executes the function with the result of the
  checkout and finally puts the channel back into the worker's pool.
  """
  @spec with_channel(atom(), f()) :: any()
  def with_channel(pool_id, fun) do
    conn_worker = :poolboy.checkout(pool_id)
    :ok = :poolboy.checkin(pool_id, conn_worker)
    do_with_conn(conn_worker, fun)
  end

  @doc """
  Gets a connection worker out of the pool and returns it back immediately so it
  can be reused by another client
  """
  @spec get_connection_worker(atom()) :: pid()
  def get_connection_worker(pool_id) do
    conn_worker = :poolboy.checkout(pool_id)
    :ok = :poolboy.checkin(pool_id, conn_worker)
    conn_worker
  end

  @doc """
  Gets a RabbitMQ channel out of a connection worker
  """
  @spec checkout_channel(pid()) ::
          {:ok, AMQP.Channel.t()} | {:error, :disconected | :out_of_channels}
  def checkout_channel(conn_worker) do
    Conn.checkout_channel(conn_worker)
  end

  @doc """
  Puts back a RabbitMQ channel into its corresponding connection worker
  """
  @spec checkin_channel(pid(), AMQP.Channel.t()) :: :ok
  def checkin_channel(conn_worker, channel) do
    Conn.checkin_channel(conn_worker, channel)
  end

  # Gets a channel out of a connection worker and performs a function with it
  # then it puts it back to the same connection worker, mimicking a transaction.
  @spec do_with_conn(pid(), f()) :: any()
  defp do_with_conn(conn_worker, fun) do
    case checkout_channel(conn_worker) do
      {:ok, channel} = ok_chan ->
        try do
          fun.(ok_chan)
        after
          :ok = checkin_channel(conn_worker, channel)
        end

      {:error, _} = error ->
        fun.(error)
    end
  end

  @spec create_queue_with_bind(
          module(),
          AMQP.Basic.queue(),
          AMQP.Basic.exchange(),
          type :: atom(),
          keyword()
        ) :: :ok | AMQP.Basic.error() | {:error, any()}
  def create_queue_with_bind(adapter, pool_id, queue, exchange, type \\ :direct, options \\ []) do
    queue_options = Keyword.get(options, :queue_options, [])
    exchange_options = Keyword.get(options, :exchange_options, [])
    bind_options = Keyword.get(options, :bind_options, [])
    conn_worker = get_connection_worker(pool_id)

    do_with_conn(conn_worker, fn
      {:ok, channel} ->
        with {:ok, _} <- adapter.declare_queue(channel, queue, queue_options),
             :ok <- adapter.declare_exchange(channel, exchange, type, exchange_options),
             :ok <- adapter.queue_bind(channel, queue, exchange, bind_options) do
          :ok
        else
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end)
  end
end
