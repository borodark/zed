defmodule ZedWeb.AdminQRControllerTest do
  use ZedWeb.ConnCase, async: false
  # async: false because OTT is a shared GenServer + the rate limiter
  # uses a shared ETS table.

  alias Zed.Admin.OTT

  describe "POST /admin/qr-login" do
    test "redeems a valid OTT and returns {ok: true, redirect: \"/admin\"}", %{conn: conn} do
      {:ok, %{ott: ott}} = OTT.issue(ttl_seconds: 60)

      conn = post(conn, ~p"/admin/qr-login", %{"ott" => ott})

      assert %{"ok" => true, "redirect" => "/admin"} = json_response(conn, 200)
    end

    test "rejects a replay with 401 + token_used", %{conn: conn} do
      {:ok, %{ott: ott}} = OTT.issue(ttl_seconds: 60)

      # first consume succeeds
      _ = post(conn, ~p"/admin/qr-login", %{"ott" => ott})

      # second should fail
      conn2 = post(build_conn(), ~p"/admin/qr-login", %{"ott" => ott})

      assert %{"ok" => false, "error" => "token_used"} = json_response(conn2, 401)
    end

    test "rejects an unknown OTT with 401 + invalid_token", %{conn: conn} do
      bogus = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      conn = post(conn, ~p"/admin/qr-login", %{"ott" => bogus})
      assert %{"error" => "invalid_token"} = json_response(conn, 401)
    end

    test "rejects missing ott param with 401 + ott_required", %{conn: conn} do
      conn = post(conn, ~p"/admin/qr-login", %{})
      assert %{"error" => "ott_required"} = json_response(conn, 401)
    end

    test "rate-limits after 10 requests per 60s from one IP", %{conn: conn} do
      # Fire 11 requests with invalid OTTs. The 11th should 429.
      bogus = fn ->
        Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      end

      results =
        for _ <- 1..11 do
          conn
          |> Map.put(:remote_ip, {10, 250, 250, 250})
          |> post(~p"/admin/qr-login", %{"ott" => bogus.()})
          |> Map.get(:status)
        end

      # First 10 should be 401 (auth fail), 11th should be 429
      {first_ten, [eleventh]} = Enum.split(results, 10)
      assert Enum.all?(first_ten, &(&1 == 401))
      assert eleventh == 429
    end
  end
end
