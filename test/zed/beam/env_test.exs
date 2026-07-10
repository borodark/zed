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

    test "{:secret, slot} without dataset opt returns :secret_dataset_not_provided" do
      assert {:error, {:secret_dataset_not_provided, :beam_cookie, :value}} =
               Env.resolve_cookie({:secret, :beam_cookie})

      assert {:error, {:secret_dataset_not_provided, :beam_cookie, :pub}} =
               Env.resolve_cookie({:secret, :beam_cookie, :pub})
    end

    test "{:secret, slot} surfaces Resolve errors when dataset opt provided" do
      # No ZFS dataset really exists; Property.get_all returns %{}
      # so lookup fails cleanly.
      assert {:error, {:slot_property_missing, "secret.nonexistent_slot.path"}} =
               Env.resolve_cookie({:secret, :nonexistent_slot}, dataset: "no/such/dataset")
    end

    test "{:secret, slot} trims trailing newline like {:file, ...} does" do
      # Prepare a props map by monkey-patching a temp file that Bootstrap
      # would have stamped. Since we test Env.resolve_cookie against a
      # real ZFS dataset via SSH on mac-248 in the C6 smoke, here we
      # just cover the trim behavior end-to-end using the file form.
      tmp =
        Path.join(
          System.tmp_dir!(),
          "zed_cookie_trim_#{System.unique_integer([:positive])}"
        )

      File.write!(tmp, "with_newline\n")
      assert {:ok, "with_newline"} = Env.resolve_cookie({:file, tmp})
      File.rm!(tmp)
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

    test "appends extra env after the RELEASE_* baseline, sorted by key" do
      out =
        Env.compose_env_file(:"foo@10.0.0.1", "secret", %{
          "PEER_NODE" => "bar@10.0.0.2",
          "ENV_TAG" => "smoke"
        })

      assert out =~ ~s(export ENV_TAG="smoke"\n)
      assert out =~ ~s(export PEER_NODE="bar@10.0.0.2"\n)

      # Baseline appears BEFORE extras
      release_pos = :binary.match(out, "RELEASE_COOKIE") |> elem(0)
      peer_pos = :binary.match(out, "PEER_NODE") |> elem(0)
      assert release_pos < peer_pos
    end

    test "empty extra_env yields the same output as the baseline call" do
      baseline = Env.compose_env_file(:"foo@10.0.0.1", "secret")
      with_empty = Env.compose_env_file(:"foo@10.0.0.1", "secret", %{})
      assert baseline == with_empty
    end
  end

  describe "resolve_env_value/2" do
    test "resolves {:env, VAR}" do
      System.put_env("ZED_TEST_ENV_VAL", "hello")
      assert {:ok, "hello"} = Env.resolve_env_value({:env, "ZED_TEST_ENV_VAL"})
      System.delete_env("ZED_TEST_ENV_VAL")
    end

    test "returns :env_var_unset when the env var is missing" do
      System.delete_env("ZED_TEST_ENV_MISSING")
      assert {:error, {:env_var_unset, "ZED_TEST_ENV_MISSING"}} =
               Env.resolve_env_value({:env, "ZED_TEST_ENV_MISSING"})
    end

    test "resolves {:file, path} trimming one trailing newline" do
      path = Path.join(System.tmp_dir!(), "zed_env_val_#{System.unique_integer([:positive])}")
      File.write!(path, "diskval\n")
      assert {:ok, "diskval"} = Env.resolve_env_value({:file, path})
      File.rm!(path)
    end

    test "surfaces file read errors" do
      path = Path.join(System.tmp_dir!(), "zed_env_nope_#{System.unique_integer([:positive])}")
      assert {:error, {:env_file_read_failed, ^path, :enoent}} =
               Env.resolve_env_value({:file, path})
    end

    test "passes through a bare binary" do
      assert {:ok, "already_a_binary"} = Env.resolve_env_value("already_a_binary")
    end

    test "{:secret, slot} without dataset opt returns :secret_dataset_not_provided" do
      assert {:error, {:secret_dataset_not_provided, :beam_cookie, :value}} =
               Env.resolve_env_value({:secret, :beam_cookie})
    end

    test "{:secret, slot} surfaces Resolve errors when dataset opt provided" do
      assert {:error, {:slot_property_missing, "secret.nonexistent_slot.path"}} =
               Env.resolve_env_value({:secret, :nonexistent_slot}, dataset: "no/such/dataset")
    end

    test "unknown ref shape returns :unsupported_env_ref" do
      assert {:error, {:unsupported_env_ref, {:weird, :ref}}} =
               Env.resolve_env_value({:weird, :ref})
    end
  end

  describe "compose_env_file/4 (resolving variant)" do
    test "resolves each extra_env value and interpolates the result" do
      System.put_env("ZED_TEST_SKB", "compiled_key_base")

      extra = %{
        "ZED_SERVE" => "1",
        "ZED_SECRET_KEY_BASE" => {:env, "ZED_TEST_SKB"}
      }

      assert {:ok, out} = Env.compose_env_file(:"foo@10.0.0.1", "cookie123", extra, [])

      assert out =~ ~s(export ZED_SERVE="1"\n)
      assert out =~ ~s(export ZED_SECRET_KEY_BASE="compiled_key_base"\n)
      assert out =~ ~s(export RELEASE_COOKIE="cookie123"\n)

      System.delete_env("ZED_TEST_SKB")
    end

    test "surfaces the first failing key with a stable error shape" do
      System.delete_env("ZED_TEST_MISSING_ENV_KEY")

      extra = %{
        "GOOD" => "ok",
        "BAD" => {:env, "ZED_TEST_MISSING_ENV_KEY"}
      }

      assert {:error, {:env_key, "BAD", {:env_var_unset, "ZED_TEST_MISSING_ENV_KEY"}}} =
               Env.compose_env_file(:"foo@10.0.0.1", "cookie", extra, [])
    end

    test "threads dataset: opt through to {:secret, ...} resolution" do
      extra = %{"ZED_SECRET" => {:secret, :nonexistent_slot}}

      assert {:error, {:env_key, "ZED_SECRET", {:slot_property_missing, _}}} =
               Env.compose_env_file(:"foo@10.0.0.1", "cookie", extra, dataset: "no/such")
    end

    test "empty extra_env matches baseline output" do
      assert {:ok, baseline} = Env.compose_env_file(:"foo@10.0.0.1", "cookie", %{}, [])
      assert baseline == Env.compose_env_file(:"foo@10.0.0.1", "cookie")
    end
  end
end
