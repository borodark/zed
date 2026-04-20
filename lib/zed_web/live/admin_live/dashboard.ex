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
     |> assign(:page_title, "bootstrap status")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>bootstrap status</h1>
    <p class="subtitle">
      base = <code><%= @base || "(not set)" %></code>
    </p>

    <%= if @base do %>
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
end
