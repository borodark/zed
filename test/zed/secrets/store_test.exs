defmodule Zed.Secrets.StoreTest do
  use ExUnit.Case, async: true

  alias Zed.Secrets.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "zed-store-test-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "write_value/3" do
    test "writes bytes and sets mode 0400 by default", %{dir: dir} do
      path = Path.join(dir, "secret")
      :ok = Store.write_value(path, "shh")

      assert File.read!(path) == "shh"
      {:ok, stat} = File.stat(path)
      # mode low 9 bits should be 0o400
      assert Bitwise.band(stat.mode, 0o777) == 0o400
    end

    test "accepts custom mode", %{dir: dir} do
      path = Path.join(dir, "pubkey")
      :ok = Store.write_value(path, "pub", 0o444)

      {:ok, stat} = File.stat(path)
      assert Bitwise.band(stat.mode, 0o777) == 0o444
    end

    test "creates parent directories", %{dir: dir} do
      path = Path.join([dir, "nested", "deep", "secret"])
      :ok = Store.write_value(path, "x")
      assert File.regular?(path)
    end
  end

  describe "read_value/1" do
    test "returns {:ok, bytes} for existing file", %{dir: dir} do
      path = Path.join(dir, "f")
      Store.write_value(path, "hello")
      assert Store.read_value(path) == {:ok, "hello"}
    end

    test "returns {:error, :enoent} for missing file", %{dir: dir} do
      assert {:error, :enoent} = Store.read_value(Path.join(dir, "nope"))
    end
  end

  describe "fingerprint/1" do
    test "sha256 of empty string is well-known constant" do
      # RFC reference vector
      assert Store.fingerprint("") ==
               "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    end

    test "differs for different inputs" do
      refute Store.fingerprint("a") == Store.fingerprint("b")
    end

    test "deterministic" do
      assert Store.fingerprint("same") == Store.fingerprint("same")
    end
  end

  describe "destroy/1" do
    test "removes existing file", %{dir: dir} do
      path = Path.join(dir, "victim")
      Store.write_value(path, "x")
      assert :ok = Store.destroy(path)
      refute File.exists?(path)
    end

    test "returns :ok when file absent (idempotent)" do
      assert :ok = Store.destroy("/tmp/zed-never-existed-#{:rand.uniform(999_999)}")
    end
  end
end
