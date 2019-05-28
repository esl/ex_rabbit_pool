defmodule ExRabbitPool.MonitorsDBTest do
  use ExUnit.Case, async: false
  alias ExRabbitPool.MonitorsDB

  test "normal operations for monitors db" do
    table = MonitorsDB.new_db()
    ref1 = make_ref()
    ref2 = make_ref()
    pid1 = :c.pid(0, Enum.random(1..1000), 0)
    pid2 = :c.pid(0, Enum.random(1..1000), 0)
    channel1 = %{pid: pid1}
    channel2 = %{pid: pid2}
    MonitorsDB.add_monitor(table, {ref1, channel1})
    MonitorsDB.add_monitor(table, {ref2, channel2})
    # find by ref
    assert {^ref1, ^channel1} = MonitorsDB.find(table, ref1)
    # find by channel
    assert {^ref1, ^channel1} = MonitorsDB.find(table, channel1)
    # find by pid
    assert {^ref1, ^channel1} = MonitorsDB.find(table, pid1)
    # not found
    refute MonitorsDB.find(table, make_ref())

    # remove by pid
    MonitorsDB.remove_monitor(table, pid1)
    refute MonitorsDB.find(table, pid1)

    # remove by ref
    MonitorsDB.remove_monitor(table, ref2)
    refute MonitorsDB.find(table, ref2)
  end
end
