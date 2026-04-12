defmodule ZedTest do
  use ExUnit.Case

  test "version is set" do
    assert Zed.version() == "0.1.0"
  end
end
