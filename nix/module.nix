# NixOS module for ZeroClaw system service
#
# Runs ZeroClaw as an isolated system user with systemd hardening.
#
# Example:
#   services.zeroclaw = {
#     enable = true;
#     apiKeyFile = config.age.secrets.zeroclaw-api-key.path;
#     telegram = {
#       enable = true;
#       botTokenFile = config.age.secrets.zeroclaw-telegram-token.path;
#       allowedUsers = [ "8593807304" ];
#     };
#   };

{ config, lib, pkgs, ... }:

let
  cfg = config.services.zeroclaw;

  # Packages included when enableDefaultTools is true.
  # These complement the implicit NixOS systemd deps (coreutils, findutils, gnugrep, gnused).
  defaultToolPackages = with pkgs; [
    git gawk bash curl wget jq
    gnutar gzip zip unzip
    diffutils file which tree patch
  ];

  defaultToolCommands = [
    "git" "awk" "bash" "sh" "curl" "wget" "jq"
    "tar" "gzip" "gunzip" "zip" "unzip"
    "diff" "file" "which" "tree" "patch"
  ];

  # All packages on the service PATH
  allPackages =
    (lib.optionals cfg.enableDefaultTools defaultToolPackages) ++ cfg.extraPackages;

  # All allowed commands for the [autonomy] section
  allExtraCommands =
    (lib.optionals cfg.enableDefaultTools defaultToolCommands) ++ cfg.extraAllowedCommands;

  toTomlList = xs: "[${lib.concatMapStringsSep ", " (c: ''"${c}"'') xs}]";

  # Build config.toml content.
  # Only required field is default_temperature. Everything else is Optional or #[serde(default)].
  # workspace_dir and config_path are #[serde(skip)] — set via ZEROCLAW_WORKSPACE env var instead.
  # Secrets use placeholders replaced at runtime by the wrapper script.
  configToml = ''
    default_provider = "${cfg.provider}"
    default_model = "${cfg.model}"
    default_temperature = 0.7

    [gateway]
    port = ${toString cfg.gatewayPort}
    host = "${cfg.gatewayHost}"
    require_pairing = false
    allow_public_bind = false

    [channels_config]
    cli = ${lib.boolToString cfg.enableCli}
  '' + lib.optionalString (allExtraCommands != []) (
    let
      # Merge with zeroclaw's built-in defaults so we extend rather than replace.
      defaultCmds = [ "git" "npm" "cargo" "ls" "cat" "grep" "find" "echo" "pwd" "wc" "head" "tail" ];
      allCmds = lib.unique (defaultCmds ++ allExtraCommands);
      defaultPaths = [ "/etc" "/root" "/home" "/usr" "/bin" "/sbin" "/lib" "/opt" "/boot" "/dev" "/proc" "/sys" "/var" "/tmp" "~/.ssh" "~/.gnupg" "~/.aws" "~/.config" ];
    in ''

    [autonomy]
    level = "supervised"
    workspace_only = true
    block_high_risk_commands = ${lib.boolToString cfg.blockHighRiskCommands}
    allowed_commands = ${toTomlList allCmds}
    forbidden_paths = ${toTomlList defaultPaths}
    max_actions_per_hour = 20
    max_cost_per_day_cents = 500
  '') + lib.optionalString cfg.telegram.enable ''

    [channels_config.telegram]
    bot_token = "@TELEGRAM_BOT_TOKEN@"
    allowed_users = [${lib.concatMapStringsSep ", " (u: ''"${u}"'') cfg.telegram.allowedUsers}]
    mention_only = ${lib.boolToString cfg.telegram.mentionOnly}
  '';

  configFile = pkgs.writeText "zeroclaw-config.toml" configToml;

  # Wrapper script that injects secrets at runtime
  wrapper = pkgs.writeShellScriptBin "zeroclaw-wrapped" ''
    set -euo pipefail

    CONFIG_DIR="${cfg.stateDir}/.zeroclaw"
    CONFIG_FILE="$CONFIG_DIR/config.toml"
    mkdir -p "$CONFIG_DIR"

    # Start from the Nix-generated config
    cp --no-preserve=mode "${configFile}" "$CONFIG_FILE"

    # Inject Telegram bot token into config
    ${lib.optionalString (cfg.telegram.enable && cfg.telegram.botTokenFile != null) ''
    TELEGRAM_TOKEN="$(cat "${cfg.telegram.botTokenFile}")"
    if [ -z "$TELEGRAM_TOKEN" ]; then
      echo "Telegram bot token file is empty: ${cfg.telegram.botTokenFile}" >&2
      exit 1
    fi
    ${pkgs.gnused}/bin/sed -i "s|@TELEGRAM_BOT_TOKEN@|$TELEGRAM_TOKEN|g" "$CONFIG_FILE"
    ''}

    # Load API key from file into env var (zeroclaw reads ZEROCLAW_API_KEY)
    ${lib.optionalString (cfg.apiKeyFile != null) ''
    ZEROCLAW_API_KEY="$(cat "${cfg.apiKeyFile}")"
    if [ -z "$ZEROCLAW_API_KEY" ]; then
      echo "API key file is empty: ${cfg.apiKeyFile}" >&2
      exit 1
    fi
    export ZEROCLAW_API_KEY
    ''}

    export ZEROCLAW_WORKSPACE="${cfg.stateDir}/workspace"

    exec "${cfg.package}/bin/zeroclaw" "$@"
  '';
in {
  options.services.zeroclaw = {
    enable = lib.mkEnableOption "ZeroClaw system service";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.zeroclaw;
      description = "ZeroClaw package to use.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "zeroclaw";
      description = "System user to run ZeroClaw.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "zeroclaw";
      description = "System group for ZeroClaw.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/zeroclaw";
      description = "State directory for ZeroClaw.";
    };

    provider = lib.mkOption {
      type = lib.types.str;
      default = "anthropic";
      description = "Default LLM provider.";
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "claude-sonnet-4-20250514";
      description = "Default model.";
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to file containing the API key (e.g. Anthropic).";
      example = "/run/agenix/zeroclaw-api-key";
    };

    gatewayPort = lib.mkOption {
      type = lib.types.int;
      default = 3000;
      description = "Gateway HTTP port.";
    };

    gatewayHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Gateway bind address (host only, port is set separately via gatewayPort).";
    };

    enableCli = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the interactive CLI channel.";
    };

    enableDefaultTools = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Include common Linux tools (git, curl, jq, tar, bash, etc.) on the
        service PATH and in allowed_commands.  These complement the implicit
        NixOS systemd deps (coreutils, findutils, gnugrep, gnused).
      '';
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      description = "Additional packages added to the service PATH (on top of default tools).";
    };

    extraAllowedCommands = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Extra command names to allow in autonomy.allowed_commands (merged with zeroclaw defaults).";
    };

    blockHighRiskCommands = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Block high-risk shell commands (curl, wget, ssh, etc.) even if allowlisted.
        Disable when the systemd sandbox already provides sufficient isolation.
      '';
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Extra environment variables for the systemd service.";
      example = { UV_PYTHON_PREFERENCE = "only-system"; };
    };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "2G";
      description = "Maximum memory (systemd MemoryMax). Kills the service on breach.";
      example = "4G";
    };

    cpuQuota = lib.mkOption {
      type = lib.types.str;
      default = "100%";
      description = "CPU quota (systemd CPUQuota). 100% = 1 core, 200% = 2 cores.";
      example = "200%";
    };

    tasksMax = lib.mkOption {
      type = lib.types.int;
      default = 64;
      description = "Maximum number of tasks/threads (systemd TasksMax).";
    };

    telegram = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable Telegram channel.";
      };

      botTokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Path to file containing Telegram bot token.";
        example = "/run/agenix/zeroclaw-telegram-token";
      };

      allowedUsers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Telegram user IDs or @usernames allowed to interact.";
      };

      mentionOnly = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Only respond when mentioned in groups.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.apiKeyFile != null;
        message = "services.zeroclaw.apiKeyFile must be set.";
      }
      {
        assertion = !cfg.telegram.enable || cfg.telegram.botTokenFile != null;
        message = "services.zeroclaw.telegram.botTokenFile must be set when Telegram is enabled.";
      }
      {
        assertion = !cfg.telegram.enable || (lib.length cfg.telegram.allowedUsers > 0);
        message = "services.zeroclaw.telegram.allowedUsers must be non-empty when Telegram is enabled.";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
      createHome = true;
      description = "ZeroClaw service user";
    };

    users.groups.${cfg.group} = {};

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.stateDir}/workspace 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.stateDir}/.zeroclaw 0750 ${cfg.user} ${cfg.group} -"
    ];

    systemd.services.zeroclaw = {
      description = "ZeroClaw daemon";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      path = allPackages;
      environment = cfg.extraEnvironment;

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = "${wrapper}/bin/zeroclaw-wrapped daemon";
        WorkingDirectory = cfg.stateDir;
        Restart = "always";
        RestartSec = "5s";

        # Hardening
        ProtectHome = true;
        ProtectSystem = "strict";
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        ProtectHostname = true;
        ProtectClock = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RemoveIPC = true;
        LockPersonality = true;

        # Filesystem
        ReadWritePaths = [ cfg.stateDir ];

        # Capabilities
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";

        # Network (only standard networking for Telegram polling + gateway)
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
        IPAddressDeny = "multicast";

        # Syscalls
        SystemCallFilter = [ "@system-service" ];
        SystemCallArchitectures = "native";

        # Native Rust binary — no JIT, so we can enforce W^X
        MemoryDenyWriteExecute = true;

        # Namespaces
        RestrictNamespaces = true;

        # Resource limits
        MemoryMax = cfg.memoryMax;
        CPUQuota = cfg.cpuQuota;
        TasksMax = cfg.tasksMax;

        # File creation mask
        UMask = "0027";
      };
    };
  };
}
