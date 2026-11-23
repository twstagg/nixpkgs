{ ... }:
{
  name = "bindery";

  nodes.machine =
    { ... }:
    {
      services.bindery = {
        enable = true;
        # Exercises the disabled-path of the telemetry option, which upstream
        # expresses as a disabled-flag accepting only the exact literal "true".
        telemetry.enable = false;
      };
    };

  testScript =
    { nodes, ... }:
    let
      port = toString nodes.machine.services.bindery.port;
    in
    ''
      machine.wait_for_unit("bindery.service")
      machine.wait_for_open_port(${port})

      # The embedded SPA is served over plain HTTP.
      machine.wait_until_succeeds("curl -fsS -o /dev/null http://127.0.0.1:${port}/")

      # /api/v1/health is unauthenticated and returns a fixed JSON status, so it
      # proves the server is answering rather than just listening.
      machine.wait_until_succeeds(
          "curl -fsS http://127.0.0.1:${port}/api/v1/health | grep -q '\"status\":\"ok\"'"
      )

      # Both the database and the data directory live under stateDir, which the
      # module hands to systemd as StateDirectory.
      machine.succeed("test -f /var/lib/bindery/bindery.db")

      # tmpfiles creates the library root, so the service does not start with a
      # "library directory does not exist" warning.
      machine.succeed("test -d /var/lib/bindery/library")

      # telemetry.enable = false has to reach the process as the exact literal
      # upstream compares against; the package wrapper defaults it to true, so
      # the module's value must win in the unit environment.
      with subtest("telemetry disabled reaches the unit environment"):
          env = machine.succeed("systemctl show bindery.service --property=Environment").strip()
          assert "BINDERY_TELEMETRY_DISABLED=true" in env, env

      # The service runs unprivileged.
      with subtest("service runs as the bindery user"):
          user = machine.succeed("systemctl show bindery.service --property=User --value").strip()
          assert user == "bindery", user
    '';
}
