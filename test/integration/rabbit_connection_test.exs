defmodule ExRabbitPool.Integration.RabbitConnectionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExRabbitPool.Worker.RabbitConnection, as: ConnWorker
  alias AMQP.Connection

  @moduletag :integration

  setup do
    rabbitmq_config = [
      channels: 1,
      port: String.to_integer(System.get_env("EX_RABBIT_POOL_PORT") || "5672")
    ]
    {:ok, config: rabbitmq_config}
  end

  @tag capture_log: true
  test "reconnects to rabbitmq when a connection crashes", %{config: config} do
    pid = start_supervised!({ConnWorker, [{:reconnect_interval, 10} | config]})
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
  end

  test "reconnects to rabbitmq when a connection is closed", %{config: config} do
    pid = start_supervised!({ConnWorker, [{:reconnect_interval, 10} | config]})
    :erlang.trace(pid, true, [:receive])

    logs =
      capture_log(fn ->
        assert {:ok, %{pid: conn_pid} = conn} = ConnWorker.get_connection(pid)
        :ok = Connection.close(conn)
        assert_receive {:trace, ^pid, :receive, {:EXIT, _channel_pid, :normal}}
        assert_receive {:trace, ^pid, :receive, {:EXIT, ^conn_pid, {:shutdown, :normal}}}
        assert_receive {:trace, ^pid, :receive, :connect}, 200
        refute Process.alive?(conn_pid)
        assert {:ok, _conn} = ConnWorker.get_connection(pid)
      end)

    assert logs =~ "[Rabbit] channel lost reason: :normal"
    assert logs =~ "[Rabbit] error starting channel reason: :closing"
    assert logs =~ "[Rabbit] connection lost, attempting to reconnect reason: {:shutdown, :normal}"
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
        assert length(channels) == 1
        assert Enum.empty?(monitors)
      end)

    assert logs =~ "[Rabbit] channel lost reason: :normal"
  end

  @tag capture_log: true
  test "creates a new channel on demand", %{config: config} do
    config = Keyword.merge(config, [{:reconnect_interval, 10}, {:channels, 0}])
    pid = start_supervised!({ConnWorker, config})
    assert {:ok, channel} = ConnWorker.create_channel(pid)
    :ok = AMQP.Channel.close(channel)
    %{channels: channels} = ConnWorker.state(pid)
    assert Enum.empty?(channels)
  end
end
