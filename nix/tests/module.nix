{ meshLlmModule }:

{
  name = "mesh-llm-module";

  nodes.machine =
    { config, pkgs, ... }:
    {
      imports = [ meshLlmModule ];

      services.mesh-llm = {
        enable = true;
        settings = {
          version = 1;
          analytics.enabled = false;
        };
        bindPort = 7842;
        openFirewall = true;
      };

      environment.systemPackages = [
        config.services.mesh-llm.package
        pkgs.curl
      ];
      virtualisation.memorySize = 2048;
    };

  testScript = ''
    machine.wait_for_unit("mesh-llm.service")
    machine.wait_for_open_port(3131)
    machine.wait_for_open_port(9337)

    with subtest("console serves the embedded UI and status API"):
        machine.succeed("curl -sf http://127.0.0.1:3131/ | grep -qi '<html'")
        machine.succeed("curl -sf http://127.0.0.1:3131/api/status")

    with subtest("declarative settings are installed for the service user"):
        machine.succeed("grep -q 'enabled = false' /var/lib/mesh-llm/.mesh-llm/config.toml")
        machine.succeed("test \"$(stat -c %U /var/lib/mesh-llm/.mesh-llm/config.toml)\" = mesh-llm")

    with subtest("the bundled native runtime is discovered"):
        output = machine.succeed("sudo -u mesh-llm HOME=/var/lib/mesh-llm mesh-llm runtime list 2>&1")
        print(output)
        assert "meshllm-native-runtime-linux" in output, output

    with subtest("firewall opens the configured ports"):
        machine.succeed("iptables -S | grep -q 'dport 3131'")
        machine.succeed("iptables -S | grep -q 'dport 7842'")
  '';
}
