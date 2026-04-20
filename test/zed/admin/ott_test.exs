defmodule Zed.Admin.OTTTest do
  use ExUnit.Case, async: false
  # async: false because OTT is a named GenServer + shared ETS table.
  # Tests issue their own tokens so they don't collide on content,
  # but sharing the singleton means parallel access isn't worth the
  # complexity for this iteration.

  alias Zed.Admin.OTT

  describe "issue/1" do
    test "returns an ott binary and expires_at unix timestamp" do
      {:ok, %{ott: ott, expires_at: exp}} = OTT.issue(ttl_seconds: 60)
      assert is_binary(ott)
      # 32 bytes → 43 chars base64url without padding
      assert byte_size(ott) == 43
      assert ott =~ ~r/^[A-Za-z0-9_\-]+$/

      now = :os.system_time(:second)
      assert exp >= now + 59
      assert exp <= now + 61
    end

    test "two calls produce distinct tokens" do
      {:ok, a} = OTT.issue()
      {:ok, b} = OTT.issue()
      refute a.ott == b.ott
    end

    test "honours :ttl_seconds option" do
      now = :os.system_time(:second)
      {:ok, %{expires_at: exp}} = OTT.issue(ttl_seconds: 600)
      assert exp >= now + 599
      assert exp <= now + 601
    end
  end

  describe "consume/1" do
    test "returns {:ok, meta} on first use; marks token used" do
      {:ok, %{ott: ott}} = OTT.issue()
      assert {:ok, meta} = OTT.consume(ott)
      assert meta.used == true
      assert meta.user == :admin
    end

    test "returns {:error, :used} on replay" do
      {:ok, %{ott: ott}} = OTT.issue()
      {:ok, _} = OTT.consume(ott)
      assert {:error, :used} = OTT.consume(ott)
    end

    test "returns {:error, :not_found} for an unknown ott" do
      assert {:error, :not_found} = OTT.consume("unknown-" <> Base.url_encode64(:crypto.strong_rand_bytes(16)))
    end

    test "returns {:error, :expired} for expired tokens" do
      # Issue with 0-second TTL; sleep a little to cross the boundary
      {:ok, %{ott: ott}} = OTT.issue(ttl_seconds: 0)
      Process.sleep(1_100)
      assert {:error, :expired} = OTT.consume(ott)
    end

    test "concurrent consume: exactly one wins" do
      {:ok, %{ott: ott}} = OTT.issue()

      tasks =
        for _ <- 1..10 do
          Task.async(fn -> OTT.consume(ott) end)
        end

      results = Enum.map(tasks, &Task.await/1)

      oks = Enum.count(results, &match?({:ok, _}, &1))
      useds = Enum.count(results, &(&1 == {:error, :used}))

      assert oks == 1
      assert oks + useds == 10
    end

    test "audit metadata survives the round-trip" do
      {:ok, %{ott: ott}} = OTT.issue(issued_by: :bootstrap, user: :admin, ttl_seconds: 300)
      {:ok, meta} = OTT.consume(ott)
      assert meta.issued_by == :bootstrap
      assert meta.user == :admin
      # created_at and expires_at are unix seconds, close to now
      assert_in_delta meta.created_at, :os.system_time(:second), 2
      assert meta.expires_at == meta.created_at + 300
    end
  end
end
