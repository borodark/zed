defmodule ZedWeb.ClusterLive do
  @moduledoc """
  Cluster demo page. Shows connected nodes and runs NUTS sampling
  on a remote exmc node via :rpc.call + Code.eval_string.
  """

  use ZedWeb, :live_view

  @exmc_node :"exmc@10.17.89.14"

  @sampling_code """
  alias Exmc.{Builder, Dist}
  ir = Builder.new_ir()
  ir = Builder.rv(ir, "mu", Dist.Normal, %{mu: Nx.tensor(0.0), sigma: Nx.tensor(1.0)})
  ir = Builder.rv(ir, "y", Dist.Normal, %{mu: "mu", sigma: Nx.tensor(1.0)})
  ir = Builder.obs(ir, "y_obs", "y", Nx.tensor([2.1, 2.5, 1.8, 2.3, 2.7]))
  {trace, _stats} = Exmc.NUTS.Sampler.sample(ir, %{"mu" => 2.3}, num_samples: 200, num_warmup: 100, seed: 7, step_size: 0.1, max_tree_depth: 5)
  %{
    mu_mean: Nx.mean(trace["mu"]) |> Nx.to_number(),
    mu_std: Nx.standard_deviation(trace["mu"]) |> Nx.to_number(),
    n_samples: Nx.size(trace["mu"])
  }
  """

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(5_000, :refresh_nodes)

    {:ok,
     socket
     |> assign(:nodes, Node.list())
     |> assign(:self, Node.self())
     |> assign(:sampling, nil)
     |> assign(:page_title, "cluster demo")}
  end

  @impl true
  def handle_info(:refresh_nodes, socket) do
    {:noreply, assign(socket, :nodes, Node.list())}
  end

  @impl true
  def handle_event("connect_exmc", _params, socket) do
    Node.connect(@exmc_node)
    Process.sleep(500)
    {:noreply, assign(socket, :nodes, Node.list())}
  end

  def handle_event("run_sampling", _params, socket) do
    send(self(), :do_sampling)
    {:noreply, assign(socket, :sampling, %{status: :running, started: now_ms()})}
  end

  @impl true
  def handle_info(:do_sampling, socket) do
    started = socket.assigns.sampling.started
    elapsed = fn -> now_ms() - started end

    sampling = run_remote_sampling(elapsed)
    {:noreply, assign(socket, :sampling, sampling)}
  end

  defp run_remote_sampling(elapsed) do
    @exmc_node
    |> :rpc.call(Code, :eval_string, [@sampling_code])
    |> parse_rpc_result(elapsed)
  rescue
    e -> %{status: :error, error: Exception.message(e), elapsed_ms: elapsed.()}
  end

  defp parse_rpc_result({%{} = data, _bindings}, elapsed),
    do: %{status: :done, data: data, elapsed_ms: elapsed.()}

  defp parse_rpc_result({:badrpc, reason}, elapsed),
    do: %{status: :error, error: inspect(reason), elapsed_ms: elapsed.()}

  defp parse_rpc_result(other, elapsed),
    do: %{status: :error, error: inspect(other), elapsed_ms: elapsed.()}

  defp now_ms, do: System.monotonic_time(:millisecond)

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width: 800px; margin: 2rem auto; font-family: monospace; color: #d9d9d9; background: #0c0f14; padding: 2rem; border-radius: 8px;">
      <h1 style="color: #3a7bd5; margin-bottom: 0.5rem;">zed cluster demo</h1>
      <p style="color: #6a6a6a; margin-top: 0;">off docker-compose — BEAM nodes across FreeBSD jails</p>

      <div style="background: #131722; border: 1px solid #1f2430; border-radius: 4px; padding: 1rem; margin: 1rem 0;">
        <h2 style="font-size: 14px; color: #8a8a8a; margin: 0 0 0.5rem;">this node</h2>
        <code style="color: #4fc1ff;"><%= @self %></code>
      </div>

      <div style="background: #131722; border: 1px solid #1f2430; border-radius: 4px; padding: 1rem; margin: 1rem 0;">
        <h2 style="font-size: 14px; color: #8a8a8a; margin: 0 0 0.5rem;">connected peers (<%= length(@nodes) %>)</h2>
        <%= if @nodes == [] do %>
          <p style="color: #555;">no peers connected</p>
          <button phx-click="connect_exmc" style="padding: 0.4rem 0.8rem; background: #2a3040; color: #fff; border: 1px solid #3a7bd5; border-radius: 3px; cursor: pointer; font: inherit;">
            connect exmc@10.17.89.14
          </button>
        <% else %>
          <ul style="list-style: none; padding: 0; margin: 0;">
            <%= for node <- @nodes do %>
              <li style="padding: 0.25rem 0;">
                <span style="color: #50fa7b;">●</span>
                <code><%= node %></code>
              </li>
            <% end %>
          </ul>
        <% end %>
      </div>

      <div style="background: #131722; border: 1px solid #1f2430; border-radius: 4px; padding: 1rem; margin: 1rem 0;">
        <h2 style="font-size: 14px; color: #8a8a8a; margin: 0 0 0.5rem;">NUTS sampling on exmc</h2>
        <p style="color: #555; font-size: 12px; margin: 0 0 0.75rem;">
          mu ~ Normal(0, 1), y ~ Normal(mu, 1), 5 observations, 200 samples
        </p>

        <%= if @sampling && @sampling.status == :running do %>
          <p style="color: #f1fa8c;">sampling...</p>
        <% else %>
          <button phx-click="run_sampling" style="padding: 0.5rem 1rem; background: #3a7bd5; color: #fff; border: none; border-radius: 3px; cursor: pointer; font: inherit; font-size: 14px;">
            Run 200 samples on exmc
          </button>
        <% end %>

        <%= if @sampling && @sampling.status == :done do %>
          <div style="margin-top: 1rem; padding: 0.75rem; background: #0c0f14; border-radius: 3px;">
            <p style="margin: 0; color: #50fa7b;">completed in <%= @sampling.elapsed_ms %>ms</p>
            <pre style="margin: 0.5rem 0 0; color: #d9d9d9; font-size: 13px;">mu:      <%= Float.round(@sampling.data.mu_mean, 4) %> +/- <%= Float.round(@sampling.data.mu_std, 4) %>
samples: <%= @sampling.data.n_samples %></pre>
          </div>
        <% end %>

        <%= if @sampling && @sampling.status == :error do %>
          <div style="margin-top: 1rem; padding: 0.75rem; background: #1a0000; border: 1px solid #ff5555; border-radius: 3px;">
            <p style="margin: 0; color: #ff5555;"><%= @sampling.error %></p>
          </div>
        <% end %>
      </div>

      <p style="color: #444; font-size: 11px; margin-top: 2rem;">
        zedweb jail: 10.17.89.10 | exmc jail: 10.17.89.14 | transport: :rpc.call over bastille0
      </p>
    </div>
    """
  end
end
