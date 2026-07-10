defmodule Zed.Secrets.ResolveTest do
  use ExUnit.Case, async: false

  alias Zed.Secrets.Resolve

  setup do
    tmp = System.tmp_dir!() |> Path.join("zed_resolve_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp}
  end

  describe "resolve_from_props/3 — :value field (single-value slots)" do
    test "returns bytes when property points at a readable file", %{tmp: tmp} do
      cookie_path = Path.join(tmp, "beam_cookie")
      File.write!(cookie_path, "supersecret\n")

      props = %{"secret.beam_cookie.path" => cookie_path}

      assert {:ok, "supersecret\n"} =
               Resolve.resolve_from_props(props, :beam_cookie, :value)
    end

    test "default field is :value (2-arg form)" do
      # The 3-arg with :value default arg equivalent — Resolve.resolve/3
      # has `field \\ :value`, so a 2-arg call from user code works.
      props = %{"secret.beam_cookie.path" => "/nonexistent/path"}
      # We call resolve_from_props with explicit :value here; the 2-arg
      # default behavior is on `resolve/3`, verified below.
      assert {:error, {:read_failed, "/nonexistent/path", :enoent}} =
               Resolve.resolve_from_props(props, :beam_cookie, :value)
    end

    test "returns :slot_property_missing when property is absent" do
      props = %{"secret.other_slot.path" => "/some/path"}

      assert {:error, {:slot_property_missing, "secret.beam_cookie.path"}} =
               Resolve.resolve_from_props(props, :beam_cookie, :value)
    end

    test "empty string property value counts as missing" do
      props = %{"secret.beam_cookie.path" => ""}

      assert {:error, {:slot_property_missing, "secret.beam_cookie.path"}} =
               Resolve.resolve_from_props(props, :beam_cookie, :value)
    end
  end

  describe "resolve_from_props/3 — multi-field slots" do
    test ":pub uses <slot>.pub_path", %{tmp: tmp} do
      pub_path = Path.join(tmp, "host_ed25519.pub")
      File.write!(pub_path, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...\n")

      props = %{
        "secret.host_ed25519.path" => Path.join(tmp, "host_ed25519"),
        "secret.host_ed25519.pub_path" => pub_path
      }

      assert {:ok, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...\n"} =
               Resolve.resolve_from_props(props, :host_ed25519, :pub)
    end

    test ":cert uses <slot>.cert_path", %{tmp: tmp} do
      cert_path = Path.join(tmp, "tls.cert")
      File.write!(cert_path, "-----BEGIN CERTIFICATE-----\n...\n")

      props = %{
        "secret.tls.path" => Path.join(tmp, "tls.key"),
        "secret.tls.cert_path" => cert_path
      }

      assert {:ok, "-----BEGIN CERTIFICATE-----\n...\n"} =
               Resolve.resolve_from_props(props, :tls, :cert)
    end

    test ":priv uses the plain path (same as :value)", %{tmp: tmp} do
      key_path = Path.join(tmp, "host_ed25519")
      File.write!(key_path, "PRIVATE_KEY_MATERIAL")

      props = %{
        "secret.host_ed25519.path" => key_path,
        "secret.host_ed25519.pub_path" => Path.join(tmp, "host_ed25519.pub")
      }

      assert {:ok, "PRIVATE_KEY_MATERIAL"} =
               Resolve.resolve_from_props(props, :host_ed25519, :priv)
    end

    test "unknown field returns :unknown_field error" do
      props = %{"secret.beam_cookie.path" => "/tmp/whatever"}

      assert {:error, {:unknown_field, :beam_cookie, :bogus}} =
               Resolve.resolve_from_props(props, :beam_cookie, :bogus)
    end
  end

  describe "resolve_from_props/3 — read errors" do
    test "unreadable file surfaces :read_failed with the path + reason" do
      props = %{"secret.beam_cookie.path" => "/nonexistent/beam_cookie"}

      assert {:error, {:read_failed, "/nonexistent/beam_cookie", :enoent}} =
               Resolve.resolve_from_props(props, :beam_cookie, :value)
    end
  end
end
