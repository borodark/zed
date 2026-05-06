defmodule ZedWeb.Layouts do
  use ZedWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta http-equiv="X-UA-Compatible" content="IE=edge" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>zed · <%= assigns[:page_title] || "admin" %></title>
        <style>
          :root { color-scheme: dark light; }
          html, body { margin: 0; padding: 0; font: 14px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }
          body { background: #0c0f14; color: #d9d9d9; min-height: 100vh; }
          main { max-width: 920px; margin: 0 auto; padding: 2rem; }
          h1 { font-weight: 600; letter-spacing: -0.02em; margin: 0 0 0.25rem 0; }
          .subtitle { margin: 0 0 1.5rem 0; color: #8a8a8a; }
          .login-wrap { max-width: 360px; margin: 6rem auto; padding: 2rem; background: #131722; border: 1px solid #1f2430; border-radius: 6px; }
          .login-form label { display: block; margin-bottom: 1rem; }
          .login-form input[type=password] { width: 100%; padding: 0.5rem 0.75rem; background: #0c0f14; border: 1px solid #2a3040; color: #fff; border-radius: 3px; font: inherit; }
          .login-form button { width: 100%; padding: 0.6rem; background: #3a7bd5; color: #fff; border: 0; border-radius: 3px; font: inherit; cursor: pointer; }
          .login-form button:hover { background: #4a8be5; }
          .error { background: #3b1e1e; color: #ffb3b3; padding: 0.5rem 0.75rem; border-radius: 3px; margin-bottom: 1rem; font-size: 12px; }
          .hint { margin-top: 1.5rem; color: #8a8a8a; font-size: 12px; }
          code { background: #1a1e28; padding: 0.1rem 0.3rem; border-radius: 2px; font-family: "SF Mono", Menlo, monospace; }
          table { width: 100%; border-collapse: collapse; margin-top: 1rem; }
          th, td { text-align: left; padding: 0.5rem 0.75rem; border-bottom: 1px solid #1f2430; font-size: 12px; }
          th { color: #8a8a8a; font-weight: 500; text-transform: uppercase; letter-spacing: 0.05em; }
          td.mono { font-family: "SF Mono", Menlo, monospace; font-size: 11px; color: #b0b0b0; }
          td.ok { color: #7bd57b; }
          td.warn { color: #e0b060; }
          td.bad { color: #ff8080; }
          header.topbar { display: flex; justify-content: space-between; align-items: baseline; border-bottom: 1px solid #1f2430; padding-bottom: 1rem; margin-bottom: 1rem; }
          header.topbar a { color: #8a8a8a; text-decoration: none; font-size: 12px; }
          header.topbar a:hover { color: #d9d9d9; }
        </style>
      </head>
      <body>
        <%= @inner_content %>
        <script type="module">
          import {Socket} from "https://cdn.jsdelivr.net/npm/phoenix@1.7.21/+esm";
          import {LiveSocket} from "https://cdn.jsdelivr.net/npm/phoenix_live_view@1.1.28/+esm";
          let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          let liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}});
          liveSocket.connect();
          window.liveSocket = liveSocket;
        </script>
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <main>
      <header class="topbar">
        <div>
          <strong>zed</strong>
          <span style="color:#8a8a8a; margin-left: 0.75rem;">admin</span>
        </div>
        <form method="post" action="/admin/logout" style="margin:0;">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <button
            type="submit"
            style="background:none; border:0; color:#8a8a8a; font:inherit; cursor:pointer;"
          >
            log out
          </button>
        </form>
      </header>
      <%= @inner_content %>
    </main>
    """
  end
end
