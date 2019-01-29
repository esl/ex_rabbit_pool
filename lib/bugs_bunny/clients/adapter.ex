defmodule BugsBunny.Clients.Adapter do
  @callback open_connection(keyword() | String.t()) :: {:ok, AMQP.Connection.t()} | {:error, any}
  @callback open_channel(AMQP.Connection.t()) :: {:ok, AMQP.Channel.t()} | {:error, any()} | any()
  @callback close_connection(AMQP.Connection.t()) :: :ok | {:error, any}
  @callback publish(AMQP.Channel.t(), String.t(), String.t(), String.t(), keyword) ::
              :ok | AMQP.Basic.error()
  @callback consume(AMQP.Channel.t(), String.t(), pid() | nil, keyword) ::
              {:ok, String.t()} | AMQP.Basic.error()
  @callback ack(AMQP.Channel.t(), String.t(), keyword()) :: :ok | AMQP.Basic.error()
  @callback reject(AMQP.Channel.t(), String.t(), keyword()) :: :ok | AMQP.Basic.error()
  @callback declare_queue(AMQP.Channel.t(), AMQP.Basic.queue(), keyword()) ::
              {:ok, map()} | AMQP.Basic.error()
  @callback queue_bind(AMQP.Channel.t(), AMQP.Basic.queue(), AMQP.Basic.exchange(), keyword()) ::
              :ok | AMQP.Basic.error()
  @callback declare_exchange(AMQP.Channel.t(), AMQP.Basic.exchange(), type :: atom, keyword()) ::
              :ok | AMQP.Basic.error()
end
