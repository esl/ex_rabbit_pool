# TODOL: change this fake adapter to not depend on RabbitMQ
# based on this: http://tech.adroll.com/blog/dev/2018/03/28/elixir-stubs-for-tests.html
defmodule ExRabbitPool.FakeRabbitMQ do
  @behaviour ExRabbitPool.Clients.Adapter
  use AMQP

  @impl true
  def publish(_channel, _exchange, _routing_key, payload, _options \\ []) do
    if String.contains?(payload, "\"owner\":\"error\"") do
      {:error, :kaboom}
    else
      :ok
    end
  end

  @impl true
  def consume(_channel, _queue, _consumer_pid \\ nil, _options \\ []) do
    {:ok, "tag"}
  end

  @impl true
  def cancel_consume(_channel, consumer_tag, _options \\ []) do
    {:ok, consumer_tag}
  end

  @impl true
  def ack(_channel, _tag, _options \\ []) do
    :ok
  end

  @impl true
  def reject(_channel, _tag, _options \\ []) do
    :ok
  end

  @impl true
  def open_connection(config) when is_list(config) do
    if Keyword.get(config, :queue) == "error.queue" do
      {:error, :invalid}
    else
      {:ok, %Connection{pid: self()}}
    end
  end

  def open_connection(_config) do
    {:ok, %Connection{pid: self()}}
  end

  @impl true
  def open_channel(conn) do
    {:ok, %Channel{conn: conn, pid: self()}}
  end

  @impl true
  def close_channel(_channel) do
    :ok
  end

  @impl true
  def close_connection(_conn) do
    :ok
  end

  @impl true
  def declare_queue(_channel, _queue, _options \\ []) do
    {:ok, %{}}
  end

  @impl true
  def declare_exchange(_channel, _exchange, _type \\ :direct, _options \\ []) do
    :ok
  end

  @impl true
  def queue_bind(_channel, _queue, _exchange, _options \\ []) do
    :ok
  end

  @impl true
  def qos(_channel, _options \\ []) do
    :ok
  end
end
