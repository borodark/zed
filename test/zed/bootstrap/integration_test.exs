defmodule Zed.BootstrapIntegrationTest do
  @moduledoc """
  Integration tests for Zed.Bootstrap against real ZFS.

  Runs against a delegated test subtree. Default `jeff/zed-test/*`
  matches the original NAS layout; on hosts with a different pool
  (e.g. Mac Pro running on `zroot`), set `ZED_TEST_DATASET` to the
  delegated parent before running:

      ZED_TEST_DATASET=zroot/zed-test doas mix test --include zfs_live

  Each test gets a unique `<parent>/bootstrap-test-<int>` base + its
  own temp mountpoint; on exit the base is destroyed recursively and
  the mountpoint directory is removed.

  Tagged `:zfs_live`; excluded from default runs. Requires root on
  FreeBSD to mount the encrypted dataset.
  """

  use ExUnit.Case, async: false
  @moduletag :zfs_live

  alias Zed.Bootstrap
  alias Zed.Secrets.{Catalog, Store}
  alias Zed.ZFS
  alias Zed.ZFS.Property

  # Test parent dataset, parametrised so the suite runs on any host
  # with a delegated test subtree. Aligns with the same env var the
  # other :zfs_live tests already use (zfs/integration_test.exs,
  # converge/integration_test.exs).
  defp parent_dataset do
    System.get_env("ZED_TEST_DATASET", "jeff/zed-test")
  end

  setup do
    unique = :erlang.unique_integer([:positive])
    base = "#{parent_dataset()}/bootstrap-test-#{unique}"
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

  describe "rotate/3" do
    test "rotates beam_cookie: file changes, fingerprint updates, archive carries old value",
         ctx do
      {:ok, _} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)

      cookie_path = Path.join(ctx.mountpoint, "beam_cookie")
      old_value = File.read!(cookie_path)

      props_before = Property.get_all("#{ctx.base}/zed")
      old_fp = props_before["secret.beam_cookie.fingerprint"]

      assert {:ok, result} = Bootstrap.rotate(ctx.base, :beam_cookie)
      assert result.slot == :beam_cookie
      assert result.prev_fingerprint == old_fp
      assert result.new_fingerprint =~ ~r/^sha256:[0-9a-f]{64}$/
      refute result.new_fingerprint == old_fp
      assert result.rotation_count == 1
      assert result.restart_plan == [:beam]

      # Live file is the new value, not the old one.
      new_value = File.read!(cookie_path)
      refute new_value == old_value

      # Archive directory exists with the old value intact.
      assert File.dir?(result.archive_path)
      archived = File.read!(Path.join(result.archive_path, "beam_cookie"))
      assert archived == old_value

      # Properties reflect the rotation.
      props_after = Property.get_all("#{ctx.base}/zed")
      assert props_after["secret.beam_cookie.fingerprint"] == result.new_fingerprint
      assert props_after["secret.beam_cookie.prev_fingerprint"] == old_fp
      assert props_after["secret.beam_cookie.rotation_count"] == "1"
      assert props_after["secret.beam_cookie.last_rotated_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
    end

    test "rotation_count keeps incrementing across multiple rotations", ctx do
      {:ok, _} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)

      assert {:ok, %{rotation_count: 1}} = Bootstrap.rotate(ctx.base, :beam_cookie)
      assert {:ok, %{rotation_count: 2}} = Bootstrap.rotate(ctx.base, :beam_cookie)
      assert {:ok, %{rotation_count: 3}} = Bootstrap.rotate(ctx.base, :beam_cookie)
    end

    test "creates pre/post snapshots on the zed dataset", ctx do
      {:ok, _} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)

      assert {:ok, %{snapshot_pre: pre, snapshot_post: post}} =
               Bootstrap.rotate(ctx.base, :beam_cookie)

      assert pre =~ ~r|@rotate-pre-beam_cookie-\d{8}T\d{6}$|
      assert post =~ ~r|@rotate-post-beam_cookie-\d{8}T\d{6}$|

      # Both snapshots exist on the zed dataset.
      {:ok, _} = ZFS.cmd(["list", "-t", "snapshot", "-H", "-o", "name", pre])
      {:ok, _} = ZFS.cmd(["list", "-t", "snapshot", "-H", "-o", "name", post])
    end

    test "rotates ssh_host_ed25519: archives both priv and pub", ctx do
      {:ok, _} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)

      priv_path = Path.join(ctx.mountpoint, "ssh_host_ed25519")
      pub_path = priv_path <> ".pub"
      old_priv = File.read!(priv_path)
      old_pub = File.read!(pub_path)

      assert {:ok, result} = Bootstrap.rotate(ctx.base, :ssh_host_ed25519)

      # Both files archived under the slot's archive directory.
      assert File.read!(Path.join(result.archive_path, "ssh_host_ed25519")) == old_priv
      assert File.read!(Path.join(result.archive_path, "ssh_host_ed25519.pub")) == old_pub

      # New keys are different.
      refute File.read!(priv_path) == old_priv
      refute File.read!(pub_path) == old_pub

      # Restart plan names sshd.
      assert result.restart_plan == [:sshd]
    end

    test "rotates admin_passwd with supplied :plaintext, hashes it, surfaces it once", ctx do
      {:ok, _} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)

      new_plaintext = "operator-chosen-rotation-#{:rand.uniform(999_999)}"

      assert {:ok, result} =
               Bootstrap.rotate(ctx.base, :admin_passwd, plaintext: new_plaintext)

      assert result.restart_plan == [:zed_web]

      # Banner carries the operator-supplied plaintext exactly once.
      assert Enum.any?(result.banner, fn
               {:admin_passwd, :plaintext_once, ^new_plaintext} -> true
               _ -> false
             end)

      # Stored file is the PHC hash, not the plaintext.
      stored = File.read!(Path.join(ctx.mountpoint, "admin_passwd"))
      refute stored =~ new_plaintext
      assert stored =~ ~r/^\$pbkdf2-sha256\$/
    end

    test "verify/1 returns :ok after rotate (post-condition)", ctx do
      {:ok, _} = Bootstrap.init(ctx.base, passphrase: ctx.passphrase, mountpoint: ctx.mountpoint)

      assert {:ok, _} = Bootstrap.rotate(ctx.base, :beam_cookie)

      results = Bootstrap.verify(ctx.base)
      cookie = Enum.find(results, &(&1.slot == :beam_cookie))
      assert cookie.status == :ok
    end

    test "unknown slot returns :unknown_slot", ctx do
      assert {:error, :unknown_slot} = Bootstrap.rotate(ctx.base, :elephant_passwd)
    end

    test ":slot_not_generated when nothing has been bootstrapped yet", ctx do
      # Don't init; rotate should refuse rather than minting a fresh
      # value (which would be init's job, not rotate's).
      {:ok, _} = Zed.ZFS.Dataset.create("#{ctx.base}/zed", %{canmount: "off"})

      assert {:error, :slot_not_generated} = Bootstrap.rotate(ctx.base, :beam_cookie)
    end
  end
end
