defmodule Zed.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :zed,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Zed.CLI],
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases(),
      description: "Declarative BEAM deployment on ZFS. FreeBSD and illumos."
    ]
  end

  # Two release targets bake the A5a privilege boundary into the
  # deploy unit. The same `:zed` application is built twice; the only
  # thing that differs is `ZED_ROLE`, exported via release env so
  # `Zed.Role.current/0` returns `:web` or `:ops` at boot. Modules are
  # identical across releases — the boundary is a process boundary.
  defp releases do
    [
      zedweb: [
        include_executables_for: [:unix],
        applications: [zed: :permanent],
        cookie: "zed_web_cookie_overridden_at_deploy"
      ],
      zedops: [
        include_executables_for: [:unix],
        applications: [zed: :permanent],
        cookie: "zed_ops_cookie_overridden_at_deploy"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :public_key, :ssl],
      mod: {Zed.Application, []}
    ]
  end

  defp deps do
    [
      # Web layer (A2a). Phoenix endpoint is not supervised by default —
      # Zed.Application leaves it out. `zed serve` starts it under its
      # own supervisor. This keeps one-shot CLI verbs (bootstrap init,
      # status, ...) free of web-process overhead.
      {:phoenix, "~> 1.7.17"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.15"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},

      # Path dep — probnik_qr lives alongside zed in the parent dir
      # (~/projects/learn_erl/probnik_qr). Exposes show_term/1,
      # render_term/1, payload_term/1 so zed can render its own
      # pairing terms (zed_admin OTT payload) without forking the
      # ANSI QR logic.
      {:probnik_qr, path: "../probnik_qr"},

      # Test
      {:propcheck, "~> 1.4", only: :test, runtime: false},
      {:floki, "~> 0.36", only: :test}
    ]
  end
end
