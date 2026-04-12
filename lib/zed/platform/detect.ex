defmodule Zed.Platform.Detect do
  @moduledoc """
  Runtime platform detection.
  """

  @doc "Return the platform module for the current OS."
  def current do
    case :os.type() do
      {:unix, :freebsd} -> Zed.Platform.FreeBSD
      {:unix, :sunos} -> Zed.Platform.Illumos
      {:unix, :linux} -> Zed.Platform.Linux
      other -> raise "Unsupported platform: #{inspect(other)}. Zed targets FreeBSD and illumos."
    end
  end
end
