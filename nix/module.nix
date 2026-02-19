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

  # Build config.toml content.
  # Secrets use placeholders replaced at runtime by the wrapper script.
  telegramSection = lib.optionalString cfg.telegram.enable ''

    [channels_config.telegram]
    bot_token = "@TELEGRAM_BOT_TOKEN@"
    allowed_users = [${lib.concatMapStringsSep ", " (u: ''"${u}"'') cfg.telegram.allowedUsers}]
    mention_only = ${lib.boolToString cfg.telegram.mentionOnly}
  '';

  configToml = ''
    workspace_dir = "${cfg.stateDir}/workspace"
    default_provider = "${cfg.provider}"
    default_model = "${cfg.model}"

    [gateway]
    port = ${toString cfg.gatewayPort}
    host = "${cfg.gatewayHost}"
    require_pairing = false
    allow_public_bind = false
    ${telegramSection}
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
      default = "127.0.0.1:3000";
      description = "Gateway bind address.";
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

        # File creation mask
        UMask = "0027";
      };
    };
  };
}
