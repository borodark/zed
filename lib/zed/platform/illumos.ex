defmodule Zed.Platform.Illumos do
  @moduledoc """
  illumos/SmartOS platform backend.

  Service management via SMF. Isolation via zones.
  Packages via pkgsrc/pkgin. Boot environments via beadm.
  """

  @behaviour Zed.Platform

  @impl true
  def service_start(name) do
    fmri = fmri(name)

    case System.cmd("svcadm", ["enable", "-s", fmri], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end

  @impl true
  def service_stop(name) do
    fmri = fmri(name)

    case System.cmd("svcadm", ["disable", "-s", fmri], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end

  @impl true
  def service_restart(name) do
    fmri = fmri(name)

    case System.cmd("svcadm", ["restart", fmri], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end

  @impl true
  def service_status(name) do
    fmri = fmri(name)

    case System.cmd("svcs", ["-H", "-o", "state", fmri], stderr_to_stdout: true) do
      {"online\n", 0} -> :running
      {_, 0} -> :stopped
      {_, _} -> {:error, :not_found}
    end
  end

  @impl true
  def service_enable(name) do
    fmri = fmri(name)

    case System.cmd("svcadm", ["enable", fmri], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end

  @impl true
  def service_install(name, config) do
    manifest = generate_smf_manifest(name, config)
    path = "/var/svc/manifest/application/#{name}.xml"

    with :ok <- File.write(path, manifest) do
      case System.cmd("svccfg", ["import", path], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {out, _} -> {:error, out}
      end
    end
  end

  defp fmri(name), do: "svc:/application/#{name}:default"

  defp generate_smf_manifest(name, config) do
    user = config[:user] || name
    command = config[:command] || "/opt/#{name}/current/bin/#{name}"
    env_file = config[:env_file]

    env_line =
      if env_file do
        """
            <method_environment>
              <envvar name="ENV_FILE" value="#{env_file}"/>
            </method_environment>
        """
      else
        ""
      end

    """
    <?xml version="1.0"?>
    <!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
    <service_bundle type="manifest" name="#{name}">
      <service name="application/#{name}" type="service" version="1">
        <create_default_instance enabled="true"/>
        <single_instance/>

        <dependency name="network" grouping="require_all" restart_on="error" type="service">
          <service_fmri value="svc:/milestone/network:default"/>
        </dependency>

        <exec_method type="method" name="start"
          exec="#{command} daemon" timeout_seconds="60">
          <method_context>
            <method_credential user="#{user}"/>
    #{env_line}      </method_context>
        </exec_method>

        <exec_method type="method" name="stop"
          exec="#{command} stop" timeout_seconds="30">
          <method_context>
            <method_credential user="#{user}"/>
          </method_context>
        </exec_method>

        <stability value="Evolving"/>
      </service>
    </service_bundle>
    """
  end
end
