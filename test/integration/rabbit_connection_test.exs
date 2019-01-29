defmodule BugsBunny.Integration.RabbitConnectionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias BugsBunny.RabbitMQ
  alias BugsBunny.Worker.RabbitConnection, as: ConnWorker

  @moduletag :integration

  setup do
    rabbitmq_config = [
      channels: 5,
      port: String.to_integer(System.get_env("POLLER_RMQ_PORT") || "5672"),
      queue: "test.queue",
      exchange: "",
      adapter: RabbitMQ,
      queue_options: [auto_delete: true],
      exchange_options: [auto_delete: true]
    ]

    {:ok, config: rabbitmq_config}
  end

  test "reconnects to rabbitmq when a connection crashes", %{config: config} do
    pid = start_supervised!({ConnWorker, [{:reconnect_interval, 100} | config]})
    :erlang.trace(pid, true, [:receive])

    logs =
      capture_log(fn ->
        assert {:ok, %{pid: conn_pid}} = ConnWorker.get_connection(pid)
        true = Process.exit(conn_pid, :kill)
        assert_receive {:trace, ^pid, :receive, {:EXIT, ^conn_pid, :killed}}
        assert_receive {:trace, ^pid, :receive, {:EXIT, _channel_pid, :shutdown}}
        assert_receive {:trace, ^pid, :receive, :connect}, 200
        assert {:ok, _conn} = ConnWorker.get_connection(pid)
      end)

    assert logs =~ "[Rabbit] connection lost, attempting to reconnect reason: :killed"
    assert logs =~ "[Rabbit] connection lost, removing channel reason: :shutdown"
  end

  test "creates a new channel to when a channel crashes", %{config: config} do
    pid = start_supervised!({ConnWorker, [{:reconnect_interval, 10} | config]})
    :erlang.trace(pid, true, [:receive])

    logs =
      capture_log(fn ->
        assert {:ok, channel} = ConnWorker.checkout_channel(pid)
        %{pid: channel_pid} = channel

        client_pid =
          spawn(fn ->
            :ok = AMQP.Channel.close(channel)
          end)

        ref = Process.monitor(client_pid)
        assert_receive {:DOWN, ^ref, :process, ^client_pid, :normal}
        assert_receive {:trace, ^pid, :receive, {:EXIT, ^channel_pid, :normal}}
        %{channels: channels, monitors: monitors} = ConnWorker.state(pid)
        assert length(channels) == 5
        assert Enum.empty?(monitors)
      end)

    assert logs =~ "[Rabbit] channel lost, attempting to reconnect reason: :normal"
  end
end
