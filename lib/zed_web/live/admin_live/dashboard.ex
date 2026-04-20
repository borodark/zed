defmodule ZedWeb.AdminLive.Dashboard do
  @moduledoc """
  Admin dashboard landing page.

  For A2a, a single LiveView renders `Zed.Bootstrap.status/1` —
  enough to prove the plumbing round-trips IR state to the browser.
  A2b adds the pairing-QR generator. Later iterations grow this into
  pool / share / alert views.
  """

  use ZedWeb, :live_view

  alias Zed.Bootstrap

  @impl true
  def mount(_params, _session, socket) do
    base = Application.get_env(:zed, :base)
    rows = if base, do: Bootstrap.status(base), else: []

    {:ok,
     socket
     |> assign(:base, base)
     |> assign(:rows, rows)
     |> assign(:pairing, nil)
     |> assign(:page_title, "bootstrap status")}
  end

  @impl true
  def handle_event("regenerate_qr", _params, socket) do
    base = socket.assigns.base

    with true <- is_binary(base),
         {:ok, cert_fp} <- cert_fingerprint(base),
         {:ok, %{ott: ott, expires_at: exp}} <-
           Zed.Admin.OTT.issue(ttl_seconds: 120, issued_by: :admin_panel) do
      {host_ip, port} = current_bind()
      payload = Zed.QR.admin_payload(host_ip, port, cert_fp, ott, exp)

      {:noreply,
       assign(socket, :pairing, %{
         payload_text: Zed.QR.payload_bin(payload) |> IO.iodata_to_binary(),
         expires_at: exp
       })}
    else
      _ -> {:noreply, assign(socket, :pairing, %{error: "could not generate QR"})}
    end
  end

  def handle_event("clear_qr", _params, socket) do
    {:noreply, assign(socket, :pairing, nil)}
  end

  defp cert_fingerprint(base) do
    props = Zed.ZFS.Property.get_all("#{base}/zed")

    with path when is_binary(path) <- Map.get(props, "secret.tls_selfsigned.path"),
         {:ok, pem} <- File.read(path <> ".cert") do
      {:ok, Zed.Bootstrap.cert_der_fingerprint(pem)}
    else
      _ -> {:error, :no_cert}
    end
  end

  defp current_bind do
    endpoint_cfg = Application.get_env(:zed, ZedWeb.Endpoint, [])

    http_cfg = endpoint_cfg[:https] || endpoint_cfg[:http] || []
    port = http_cfg[:port] || 4040
    ip = http_cfg[:ip] || {127, 0, 0, 1}

    {ip, port}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>bootstrap status</h1>
    <p class="subtitle">
      base = <code><%= @base || "(not set)" %></code>
    </p>

    <%= if @base do %>
      <div style="margin: 1rem 0;">
        <button phx-click="regenerate_qr" style="padding: 0.4rem 0.8rem; background: #2a3040; color: #fff; border: 1px solid #3a7bd5; border-radius: 3px; cursor: pointer; font: inherit;">
          Generate pairing token
        </button>
        <%= if @pairing do %>
          <button phx-click="clear_qr" style="padding: 0.4rem 0.8rem; margin-left: 0.5rem; background: none; color: #8a8a8a; border: 1px solid #2a3040; border-radius: 3px; cursor: pointer; font: inherit;">
            clear
          </button>
        <% end %>
      </div>

      <%= if @pairing do %>
        <%= if Map.has_key?(@pairing, :error) do %>
          <div class="error"><%= @pairing.error %></div>
        <% else %>
          <div style="background: #131722; border: 1px solid #1f2430; border-radius: 4px; padding: 1rem; margin-bottom: 1rem;">
            <p style="margin: 0 0 0.5rem 0; color: #8a8a8a; font-size: 12px;">
              Paste into a zedz-compatible scanner. Valid until <%= format_exp(@pairing.expires_at) %>; single-use.
            </p>
            <pre style="margin: 0; padding: 0.75rem; background: #0c0f14; border-radius: 3px; overflow-x: auto; font-size: 11px; color: #d9d9d9;"><%= @pairing.payload_text %></pre>
          </div>
        <% end %>
      <% end %>

      <table>
        <thead>
          <tr>
            <th>slot</th>
            <th>algo</th>
            <th>fingerprint</th>
            <th>file</th>
            <th>created</th>
          </tr>
        </thead>
        <tbody>
          <%= for row <- @rows do %>
            <tr>
              <td><code><%= row.slot %></code></td>
              <td><code><%= row.algo %></code></td>
              <td class="mono"><%= row.fingerprint || "—" %></td>
              <td class={if row.file_present, do: "ok", else: "bad"}>
                <%= if row.file_present, do: "present", else: "missing" %>
              </td>
              <td class="mono"><%= row.created_at || "—" %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    <% else %>
      <p>
        No base configured. Start the server with
        <code>zed serve --base &lt;dataset&gt;</code>.
      </p>
    <% end %>
    """
  end

  defp format_exp(unix) do
    DateTime.from_unix!(unix) |> Calendar.strftime("%H:%M:%S UTC")
  end
end
