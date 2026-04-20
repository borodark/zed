defmodule ZedWeb.AdminHTML do
  use ZedWeb, :html

  def new_session(assigns) do
    ~H"""
    <div class="login-wrap">
      <h1>zed</h1>
      <p class="subtitle">admin login</p>

      <form method="post" action="/admin/login" class="login-form">
        <input type="hidden" name="_csrf_token" value={@csrf_token} />

        <%= if @error do %>
          <div class="error"><%= @error %></div>
        <% end %>

        <label>
          password
          <input
            type="password"
            name="password"
            autocomplete="current-password"
            autofocus
            required
          />
        </label>

        <button type="submit">sign in</button>
      </form>

      <p class="hint">
        Password was printed by <code>zed bootstrap init</code>.
        Scan the pairing QR in the bootstrap banner for a faster path.
      </p>
    </div>
    """
  end
end
