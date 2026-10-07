{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;
  cfg = config.services.mesh-llm;
  toml = pkgs.formats.toml { };
  configFile = toml.generate "mesh-llm-config.toml" cfg.settings;

  args = [
    "serve"
    "--port"
    (toString cfg.port)
    "--console"
    (toString cfg.consolePort)
  ]
  ++ lib.optional cfg.listenAll "--listen-all"
  ++ lib.optionals (cfg.bindPort != null) [
    "--bind-port"
    (toString cfg.bindPort)
  ]
  ++ lib.optionals (cfg.joinFile != null) [
    "--join-file"
    cfg.joinFile
  ]
  ++ cfg.extraArgs;
in
{
  options.services.mesh-llm = {
    enable = lib.mkEnableOption "the MeshLLM node";

    package = mkOption {
      type = types.package;
      description = ''
        The MeshLLM package. Its bundled native runtime decides the backend;
        use the mesh-llm-cuda or mesh-llm-vulkan variant for GPU serving.
      '';
    };

    settings = mkOption {
      inherit (toml) type;
      default = { };
      example = lib.literalExpression ''
        {
          models = [ { model = "Qwen3-8B-Q4_K_M"; } ];
        }
      '';
      description = ''
        Contents of ~/.mesh-llm/config.toml for the service user. When set,
        the file is replaced on every start, so changes made from the console
        do not persist. When empty, the file is left under MeshLLM's control.
        Do not put secrets here because the Nix store is world-readable.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 9337;
      description = "Port of the OpenAI-compatible API.";
    };

    consolePort = mkOption {
      type = types.port;
      default = 3131;
      description = "Port of the management console and API.";
    };

    listenAll = mkOption {
      type = types.bool;
      default = false;
      description = "Bind the API and console on all interfaces instead of localhost.";
    };

    bindPort = mkOption {
      type = types.nullOr types.port;
      default = null;
      description = "Fixed UDP port for mesh QUIC traffic, for example for port forwarding.";
    };

    joinFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/mesh-llm-invite";
      description = ''
        Absolute path of a file that holds a mesh invite token. MeshLLM
        rereads it on every rejoin, so a rotated token needs no restart.
      '';
    };

    environmentFiles = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Files with environment variables in systemd EnvironmentFile syntax,
        for example MESH_LLM_JOIN_FILE or HF_TOKEN. Prefix a path with - to
        make it optional.
      '';
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "--model"
        "Qwen3-8B-Q4_K_M"
        "--publish"
      ];
      description = "Extra arguments for `mesh-llm serve`.";
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = lib.optional config.hardware.nvidia.enabled config.hardware.nvidia.package.bin;
      defaultText = lib.literalExpression ''
        lib.optional config.hardware.nvidia.enabled config.hardware.nvidia.package.bin
      '';
      description = ''
        Packages on the service's PATH. MeshLLM discovers NVIDIA GPUs and
        their compute capability with nvidia-smi.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open the API and console TCP ports, and the QUIC UDP port when
        bindPort is set.
      '';
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/mesh-llm";
      description = ''
        Home directory of the service user. MeshLLM keeps its configuration,
        identity, model cache, and runtime state below it.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "mesh-llm";
      description = "User that runs MeshLLM.";
    };

    group = mkOption {
      type = types.str;
      default = "mesh-llm";
      description = "Group that runs MeshLLM.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.dataDir;
        message = "services.mesh-llm.dataDir must be an absolute path.";
      }
      {
        assertion = cfg.joinFile == null || lib.hasPrefix "/" cfg.joinFile;
        message = "services.mesh-llm.joinFile must be an absolute path.";
      }
    ];

    users.users = lib.mkIf (cfg.user == "mesh-llm") {
      mesh-llm = {
        isSystemUser = true;
        inherit (cfg) group;
        home = cfg.dataDir;
        # GPU device nodes are commonly restricted to these groups.
        extraGroups = [
          "render"
          "video"
        ];
      };
    };
    users.groups = lib.mkIf (cfg.group == "mesh-llm") { mesh-llm = { }; };

    systemd.tmpfiles.settings."10-mesh-llm".${cfg.dataDir}.d = {
      inherit (cfg) user group;
      mode = "0750";
    };

    systemd.services.mesh-llm = {
      description = "MeshLLM node";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      path = cfg.extraPackages;

      environment = {
        HOME = cfg.dataDir;
        XDG_CACHE_HOME = "${cfg.dataDir}/.cache";
        XDG_CONFIG_HOME = "${cfg.dataDir}/.config";
      };

      preStart = lib.optionalString (cfg.settings != { }) ''
        install -D -m 0600 ${configFile} "$HOME/.mesh-llm/config.toml"
      '';

      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} ${lib.escapeShellArgs args}";
        EnvironmentFile = cfg.environmentFiles;
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        Restart = "on-failure";
        RestartSec = 5;

        # GPU serving needs the host's device nodes, so devices stay visible.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [
        cfg.port
        cfg.consolePort
      ];
      allowedUDPPorts = lib.optional (cfg.bindPort != null) cfg.bindPort;
    };
  };
}
