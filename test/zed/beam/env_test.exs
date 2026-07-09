defmodule Zed.Beam.EnvTest do
  use ExUnit.Case, async: false

  alias Zed.Beam.Env

  describe "resolve_cookie/1" do
    test "resolves {:env, VAR} from System env" do
      System.put_env("ZED_TEST_COOKIE", "abc123")
      assert {:ok, "abc123"} = Env.resolve_cookie({:env, "ZED_TEST_COOKIE"})
      System.delete_env("ZED_TEST_COOKIE")
    end

    test "returns :env_var_unset when the env var is missing" do
      System.delete_env("ZED_TEST_UNSET_COOKIE")
      assert {:error, {:env_var_unset, "ZED_TEST_UNSET_COOKIE"}} =
               Env.resolve_cookie({:env, "ZED_TEST_UNSET_COOKIE"})
    end

    test "returns :env_var_empty when the env var is set to empty string" do
      System.put_env("ZED_TEST_EMPTY_COOKIE", "")
      assert {:error, {:env_var_empty, "ZED_TEST_EMPTY_COOKIE"}} =
               Env.resolve_cookie({:env, "ZED_TEST_EMPTY_COOKIE"})
      System.delete_env("ZED_TEST_EMPTY_COOKIE")
    end

    test "resolves {:file, path} trimming one trailing newline" do
      path =
        Path.join(System.tmp_dir!(), "zed_env_cookie_#{System.unique_integer([:positive])}")

      File.write!(path, "supersecret\n")

      assert {:ok, "supersecret"} = Env.resolve_cookie({:file, path})

      File.rm!(path)
    end

    test "surfaces file read errors" do
      path = Path.join(System.tmp_dir!(), "zed_env_nonexistent_#{System.unique_integer([:positive])}")
      assert {:error, {:cookie_file_read_failed, ^path, :enoent}} =
               Env.resolve_cookie({:file, path})
    end

    test "passes through a bare binary" do
      assert {:ok, "already_a_binary"} = Env.resolve_cookie("already_a_binary")
    end

    test "returns not-yet-supported for {:secret, ...} refs" do
      assert {:error, {:secret_ref_not_yet_supported, :foo}} =
               Env.resolve_cookie({:secret, :foo})

      assert {:error, {:secret_ref_not_yet_supported, :foo, :value}} =
               Env.resolve_cookie({:secret, :foo, :value})
    end
  end

  describe "compose_env_file/2" do
    test "returns exported RELEASE_DISTRIBUTION + RELEASE_NODE + RELEASE_COOKIE for FQDN/IP nodes" do
      out = Env.compose_env_file(:"foo@10.0.0.1", "supersecret")

      assert out =~ "export RELEASE_DISTRIBUTION=name\n"
      assert out =~ ~s(export RELEASE_NODE="foo@10.0.0.1"\n)
      assert out =~ ~s(export RELEASE_COOKIE="supersecret"\n)
    end

    test "uses sname distribution mode for bare hostnames" do
      out = Env.compose_env_file(:"foo@bare", "abc")
      assert out =~ "export RELEASE_DISTRIBUTION=sname\n"
    end
  end
end
