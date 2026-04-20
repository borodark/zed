defmodule Zed.BootstrapIntegrationTest do
  @moduledoc """
  Integration tests for Zed.Bootstrap against real ZFS.

  Runs against the jail-delegated subtree `jeff/zed-test/*`. Each test
  gets a unique `jeff/zed-test/bootstrap-test-<int>` base + its own
  temp mountpoint; on exit the base is destroyed recursively and the
  mountpoint directory is removed.

  Tagged `:zfs_live`; excluded from default runs. Require root on
  FreeBSD to mount the encrypted dataset.

  Run with: `sudo mix test --include zfs_live`
  """

  use ExUnit.Case, async: false
  @moduletag :zfs_live

  alias Zed.Bootstrap
  alias Zed.Secrets.{Catalog, Store}
  alias Zed.ZFS
  alias Zed.ZFS.Property

  @parent "jeff/zed-test"

  setup do
    unique = :erlang.unique_integer([:positive])
    base = "#{@parent}/bootstrap-test-#{unique}"
    mountpoint = Path.join(System.tmp_dir!(), "zed-btest-#{unique}")
    passphrase = "test-passphrase-#{unique}"

    on_exit(fn ->
      # Unmount, unload key, destroy recursively. -f forces unmount.
      _ = ZFS.cmd(["destroy", "-rf", base])
      _ = File.rm_rf(mountpoint)
    end)

    {:ok, base: base, mountpoint: mountpoint, passphrase: passphrase}
  end

  describe "init/2" do
    test "creates <base>/zed and <base>/zed/secrets datasets", ctx do
      assert {:ok, _} =
               Bootstrap.init(ctx.base,
                 passphrase: ctx.passphrase,
                 mountpoint: ctx.mountpoint
               )

      assert {:ok, _} = ZFS.cmd(["list", "-H", "-o", "name", "#{ctx.base}/zed"])
      assert {:ok, _} = ZFS.cmd(["list", "-H", "-o", "name", "#{ctx.base}/zed/secrets"])
    end

    test "secrets dataset is encrypted with aes-256-gcm", ctx do
      {:ok, _} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)

      {:ok, enc} =
        ZFS.cmd([
          "get",
          "-H",
          "-o",
          "value",
          "encryption",
          "#{ctx.base}/zed/secrets"
        ])

      assert enc == "aes-256-gcm"
    end

    test "generates all slots in the catalog on first run", ctx do
      {:ok, result} =
        Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)

      slot_names = Enum.map(result.generated, & &1.slot)
      assert Enum.sort(slot_names) == Enum.sort(Catalog.slots())
      refute Enum.any?(result.generated, & &1.skipped)
    end

    test "slot files exist under mountpoint with mode 0400", ctx do
      {:ok, _} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)

      for slot <- [:beam_cookie, :admin_passwd, :ssh_host_ed25519] do
        path = Path.join(ctx.mountpoint, Atom.to_string(slot))
        assert File.regular?(path), "expected #{path} to exist"
        {:ok, stat} = File.stat(path)
        assert Bitwise.band(stat.mode, 0o777) == 0o400, "#{slot} mode should be 0400"
      end

      # pubkey file should exist with readable mode
      pub = Path.join(ctx.mountpoint, "ssh_host_ed25519.pub")
      assert File.regular?(pub)
      {:ok, pub_stat} = File.stat(pub)
      assert Bitwise.band(pub_stat.mode, 0o777) == 0o444
    end

    test "fingerprints stamped in com.zed:secret.<slot>.fingerprint props", ctx do
      {:ok, _} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)
      props = Property.get_all("#{ctx.base}/zed")

      for slot <- Catalog.slots() do
        key = "secret.#{slot}.fingerprint"
        assert Map.has_key?(props, key), "missing fingerprint property for #{slot}"
        assert props[key] =~ ~r/^sha256:[0-9a-f]{64}$/
      end
    end

    test "algo/consumers/created_at/rotation_count also stamped", ctx do
      {:ok, _} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)
      props = Property.get_all("#{ctx.base}/zed")

      assert props["secret.beam_cookie.algo"] == "random_256_b64"
      assert props["secret.beam_cookie.rotation_count"] == "0"
      assert props["secret.beam_cookie.consumers"] == "beam"
      assert props["secret.admin_passwd.consumers"] == "zed_web"
      assert props["secret.ssh_host_ed25519.consumers"] == "sshd"

      # created_at is RFC3339-ish
      assert props["secret.beam_cookie.created_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
    end

    test "creates bootstrap-<ts> snapshot on <base>/zed", ctx do
      {:ok, result} =
        Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)

      assert result.snapshot =~ ~r|^#{Regex.escape(ctx.base)}/zed@bootstrap-\d{8}T\d{6}$|
      {:ok, _} = ZFS.cmd(["list", "-t", "snapshot", "-H", "-o", "name", result.snapshot])
    end

    test "idempotent: second init is a no-op (all slots skipped)", ctx do
      {:ok, _first} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)
      {:ok, second} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)

      assert Enum.all?(second.generated, & &1.skipped)
    end

    test "supplied admin_passwd is hashed and roundtrips in banner", ctx do
      plaintext = "my-chosen-password-#{:rand.uniform(999_999)}"

      {:ok, result} =
        Bootstrap.init(ctx.base,
          passphrase: ctx.passphrase,
          mountpoint: ctx.mountpoint,
          admin_passwd: plaintext
        )

      # banner should carry the exact plaintext we supplied
      assert Enum.any?(result.banner, fn
               {:admin_passwd, :plaintext_once, ^plaintext} -> true
               _ -> false
             end)

      # stored file is a PHC-formatted hash, not the plaintext
      {:ok, hash_file} = File.read(Path.join(ctx.mountpoint, "admin_passwd"))
      refute hash_file =~ plaintext
      assert hash_file =~ ~r/^\$pbkdf2-sha256\$i=\d+\$/
    end
  end

  describe "DIAGNOSTIC — stamped path vs filesystem reality" do
    test "stamped path property matches write-time path exactly", ctx do
      {:ok, _} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)

      IO.puts("\n=== DIAGNOSTIC BEGIN ===")
      IO.puts("  System.tmp_dir!() = #{System.tmp_dir!()}")
      IO.puts("  TMPDIR env         = #{inspect(System.get_env("TMPDIR"))}")
      IO.puts("  ctx.mountpoint     = #{ctx.mountpoint}")
      IO.puts("  ctx.base           = #{ctx.base}")

      {mount_out, _} = System.cmd("mount", [], stderr_to_stdout: true)
      IO.puts("  relevant `mount` lines:")

      for line <- String.split(mount_out, "\n"),
          String.contains?(line, "zed-btest") or String.contains?(line, ctx.base) do
        IO.puts("    #{line}")
      end

      {zfs_get_mp, _} =
        System.cmd("zfs", ["get", "-H", "-o", "value", "mountpoint", "#{ctx.base}/zed/secrets"])

      IO.puts("  zfs get mountpoint  = #{String.trim(zfs_get_mp)}")

      props = Zed.ZFS.Property.get_all("#{ctx.base}/zed")

      for slot <- Zed.Secrets.Catalog.slots() do
        stamped = props["secret.#{slot}.path"]
        expected = Path.join(ctx.mountpoint, Atom.to_string(slot))
        status_char = if stamped == expected, do: "OK", else: "MISMATCH"
        exists_char = if stamped && File.regular?(stamped), do: "exists", else: "MISSING"

        IO.puts(
          "  slot=#{slot}  stamped=#{stamped}  expected=#{expected}  #{status_char} file=#{exists_char}"
        )

        if stamped do
          ls_target = Path.dirname(stamped)
          {ls_out, _} = System.cmd("ls", ["-la", ls_target], stderr_to_stdout: true)
          IO.puts("    ls -la #{ls_target}:\n#{indent(ls_out, "      ")}")
        end
      end

      IO.puts("=== DIAGNOSTIC END ===\n")
    end

    defp indent(string, prefix) do
      string
      |> String.split("\n")
      |> Enum.map(&(prefix <> &1))
      |> Enum.join("\n")
    end
  end

  describe "status/1" do
    test "reports all slots with file_present=true after init", ctx do
      {:ok, _} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)

      rows = Bootstrap.status(ctx.base)
      by_slot = Map.new(rows, &{&1.slot, &1})

      for slot <- Catalog.slots() do
        row = by_slot[slot]
        assert row.fingerprint =~ ~r/^sha256:[0-9a-f]{64}$/
        assert row.file_present == true
        assert row.algo == Catalog.algo(slot)
      end
    end

    test "ssh_host_ed25519 requires both priv and pub files for file_present", ctx do
      {:ok, _} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)

      pub = Path.join(ctx.mountpoint, "ssh_host_ed25519.pub")
      File.rm!(pub)

      rows = Bootstrap.status(ctx.base)
      ssh_row = Enum.find(rows, &(&1.slot == :ssh_host_ed25519))
      assert ssh_row.file_present == false
    end
  end

  describe "verify/1" do
    test "returns :ok for every slot after fresh init", ctx do
      {:ok, _} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)

      results = Bootstrap.verify(ctx.base)
      for r <- results, do: assert(r.status == :ok, "expected :ok for #{r.slot}, got #{inspect(r)}")
    end

    test ":drift when file contents no longer match stamped fingerprint", ctx do
      {:ok, _} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)

      path = Path.join(ctx.mountpoint, "beam_cookie")
      File.chmod!(path, 0o600)
      File.write!(path, "tampered")

      results = Bootstrap.verify(ctx.base)
      cookie = Enum.find(results, &(&1.slot == :beam_cookie))
      assert cookie.status == :drift
      assert cookie.expected =~ "sha256:"
      assert cookie.actual == Store.fingerprint("tampered")
    end

    test ":file_missing when file is gone but fingerprint is stamped", ctx do
      {:ok, _} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)

      File.rm!(Path.join(ctx.mountpoint, "beam_cookie"))

      results = Bootstrap.verify(ctx.base)
      cookie = Enum.find(results, &(&1.slot == :beam_cookie))
      assert cookie.status == :file_missing
    end
  end

  describe "export_pubkey/2" do
    test "returns {:ok, bytes} for ssh_host_ed25519", ctx do
      {:ok, _} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)

      assert {:ok, pub} = Bootstrap.export_pubkey(ctx.base, :ssh_host_ed25519)
      assert byte_size(pub) == 32
    end

    test "returns {:error, :no_pubkey} for single-value slot", ctx do
      {:ok, _} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)
      assert {:error, :no_pubkey} = Bootstrap.export_pubkey(ctx.base, :beam_cookie)
    end
  end
end
