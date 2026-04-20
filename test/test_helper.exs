ExUnit.start(exclude: [:zfs_live])

# Endpoint must be running for LiveView/Plug tests. It's not in the
# application supervisor (see lib/zed/application.ex — we only start
# the endpoint from `zed serve`), so start it explicitly here.
{:ok, _} = ZedWeb.Endpoint.start_link()
