defmodule Zed.QRTest do
  use ExUnit.Case, async: true

  alias Zed.QR

  describe "admin_payload/5" do
    test "builds a :zed_admin 7-tuple with correct shape" do
      payload = QR.admin_payload({192, 168, 0, 33}, 4040, "sha256:aabb", "ott_xyz", 1_713_546_000)

      {tag, node_atom, ip, port, fp, ott, exp} = payload
      assert tag == :zed_admin
      assert node_atom == Node.self()
      assert ip == {192, 168, 0, 33}
      assert port == 4040
      assert fp == "sha256:aabb"
      assert ott == "ott_xyz"
      assert exp == 1_713_546_000
    end
  end

  describe "payload_bin/1" do
    test "returns an Erlang-term-format binary" do
      payload = QR.admin_payload({192, 168, 0, 33}, 4040, "sha256:aa", "ott_xx", 1_713_546_000)
      bin = QR.payload_bin(payload)

      # io_lib:format "~p" output for a 7-tuple:
      assert is_binary(bin)
      assert bin =~ "zed_admin"
      assert bin =~ "192,168,0,33"
      assert bin =~ "4040"
      assert bin =~ "sha256:aa"
      assert bin =~ "ott_xx"
      assert bin =~ "1713546000"
    end
  end

  describe "render/1" do
    test "returns {:ok, iodata} for a valid payload" do
      payload = QR.admin_payload({127, 0, 0, 1}, 4040, "sha256:aa", "ott_xx", 1_713_546_000)
      assert {:ok, iodata} = QR.render(payload)
      # ANSI-rendered output: should contain escape codes
      bin = IO.iodata_to_binary(iodata)
      assert bin =~ "\e["
      # QR codes are at least version 1 (21x21 = 21 rows). Each row ends
      # with \n, so we expect ≥ 21 newlines.
      assert bin |> String.graphemes() |> Enum.count(&(&1 == "\n")) >= 21
    end
  end
end
