defmodule ExRabbitPool.Test.Helpers do
  def wait_for(timeout \\ 1000, f)
  def wait_for(0, _), do: {:error, "Error - Timeout"}

  def wait_for(timeout, f) do
    if f.() do
      :ok
    else
      :timer.sleep(10)
      wait_for(timeout - 10, f)
    end
  end
end
