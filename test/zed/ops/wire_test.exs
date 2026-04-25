defmodule Zed.Ops.WireTest do
  use ExUnit.Case, async: true

  alias Zed.Ops.Wire

  describe "encode/1 + decode/1 round-trip" do
    test "tuples and atoms" do
      term = {:zedops, :v1, "req-1", :ping, %{foo: 1}, <<1, 2, 3>>}
      {:ok, bin} = Wire.encode(term)
      assert {:ok, ^term} = Wire.decode(bin)
    end

    test "reply variants" do
      for reply <- [
            {:zedops_reply, "req-1", :ok},
            {:zedops_reply, "req-1", {:ok, %{result: :pong}}},
            {:zedops_reply, "req-1", {:error, :unknown_action}}
          ] do
        {:ok, bin} = Wire.encode(reply)
        assert {:ok, ^reply} = Wire.decode(bin)
      end
    end
  end

  describe "encode/1" do
    test "rejects payloads larger than 64 KiB" do
      huge = :binary.copy(<<0>>, Wire.max_payload() + 1)
      assert {:error, {:payload_too_large, _}} = Wire.encode(huge)
    end

    test "accepts payloads at the boundary" do
      ok_size = Wire.max_payload() - 200
      bin = :binary.copy(<<0>>, ok_size)
      assert {:ok, _} = Wire.encode(bin)
    end
  end

  describe "decode/1" do
    test "garbage returns :bad_term" do
      assert {:error, :bad_term} = Wire.decode(<<0, 1, 2, 3, 4>>)
    end

    test "decoded atoms that are already known come through" do
      term = {:zedops_reply, "req", :ok}
      {:ok, bin} = Wire.encode(term)
      assert {:ok, ^term} = Wire.decode(bin)
    end
  end
end
