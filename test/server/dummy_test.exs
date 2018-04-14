defmodule DynamicServerManager.Server.DummyTest do
  use ExUnit.Case
  doctest DynamicServerManager

  alias DynamicServerManager.Server.Dummy

  test "application starts with permanent arg, named server" do
    assert is_pid(Process.whereis(Dummy))
  end

  test "started with no permanent arg, unnamed server" do
    assert {:ok, pid} = Dummy.start_link()
    assert Process.whereis(Dummy) != pid
    GenServer.stop(pid)
  end

end
