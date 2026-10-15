# services.claude-sandbox (nix-darwin): Claude Code agents isolated from their
# owner, each its own macOS user, inside a Seatbelt profile, reaching the
# network only through its own filtering proxy. See ./DESIGN.md.
self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.claude-sandbox;
  sandboxProfile = pkgs.writeText "claude-sandbox.sb" (builtins.readFile ./claude-sandbox.sb);

  agentSubmodule = {
    name,
    config,
    ...
  }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "_claude_${name}";
      };
      uid = lib.mkOption {type = lib.types.int;};
      gid = lib.mkOption {
        type = lib.types.int;
        default = config.uid;
      };
      cliName = lib.mkOption {
        type = lib.types.str;
        default = "claude-${name}";
      };
      autoGrantWorkspaceACL = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      extraPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
      };
      extraEnv = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
      };

      proxy = {
        port = lib.mkOption {type = lib.types.port;};
        allowedDomains = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = ["^(.*\\.)?anthropic\\.com$" "^(.*\\.)?claude\\.ai$"];
        };
      };

      auth = {
        strategy = lib.mkOption {
          type = lib.types.enum ["secure-enclave" "hkdf-derived" "keychain" "sops-file"];
          default = "secure-enclave";
        };
        seIdentityFile = lib.mkOption {
          type = lib.types.str;
          default = "$HOME/.config/claude-se/${name}.key";
        };
        encryptedSecretFile = lib.mkOption {
          type = lib.types.str;
          default = "$HOME/.config/claude-se/${name}-anthropic.key.age";
        };
        keychainService = lib.mkOption {
          type = lib.types.str;
          default = "anthropic-api-key-${name}";
        };
        sopsSecretPath = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
      };
    };
  };

  enabledAgents = lib.filterAttrs (_: a: a.enable) cfg.agents;

  mkTinyproxyConf = name: agent: let
    filterFile = pkgs.writeText "claude-proxy-${name}.filter" (lib.concatStringsSep "\n" agent.proxy.allowedDomains);
  in
    pkgs.writeText "tinyproxy-claude-${name}.conf" ''
      User _nobody
      Group _nobody
      Port ${toString agent.proxy.port}
      Listen 127.0.0.1
      BindSame yes
      Timeout 600
      LogLevel Info
      MaxClients 25
      Filter "${filterFile}"
      FilterURLs Off
      FilterExtended On
      FilterCaseSensitive Off
      FilterDefaultDeny Yes
      ConnectPort 443
    '';

  mkAgentWrapper = name: agent: let
    aclRule = "user:${agent.user} allow list,add_file,search,delete,add_subdirectory,delete_child,readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit";
    extraEnvArgs = lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "${lib.escapeShellArg k}=${lib.escapeShellArg v}") agent.extraEnv);
    # Chosen at build time: a bash `case` on a constant fails shellcheck.
    resolveKey = {
      "secure-enclave" = ''
        echo "[${agent.cliName}] Touch ID required to unlock Secure Enclave key for '$AGENT_NAME'..." >&2
        RESOLVED_API_KEY="$(age --decrypt -i "${agent.auth.seIdentityFile}" "${agent.auth.encryptedSecretFile}" | tr -d '\n\r')"
      '';
      "hkdf-derived" = ''
        echo "[${agent.cliName}] Touch ID required to derive key for '$AGENT_NAME'..." >&2
        MASTER_SEED="$(age --decrypt -i "${cfg.masterHkdf.seIdentityFile}" "${cfg.masterHkdf.encryptedMasterSeedFile}" | xxd -p -c 64)"
        AGENT_HEX_KEY="$(openssl kdf -keylen 32 -kdfopt digest:SHA256 -kdfopt hexkey:"$MASTER_SEED" -kdfopt info:"claude-agent:$AGENT_NAME" HKDF | tr -d ':')"
        RESOLVED_API_KEY="$(openssl enc -d -aes-256-cbc -pbkdf2 -K "$AGENT_HEX_KEY" -iv 00000000000000000000000000000000 -in "${agent.auth.encryptedSecretFile}" | tr -d '\n\r')"
        unset MASTER_SEED AGENT_HEX_KEY
      '';
      "keychain" = ''
        RESOLVED_API_KEY="$(/usr/bin/security find-generic-password -s "${agent.auth.keychainService}" -w)"
      '';
      "sops-file" = ''
        RESOLVED_API_KEY="$(sudo -u "$AGENT_USER" /bin/cat "${toString agent.auth.sopsSecretPath}" | tr -d '\n\r')"
      '';
    };
  in
    pkgs.writeShellApplication {
      name = agent.cliName;
      runtimeInputs = [pkgs.coreutils cfg.package pkgs.age pkgs.age-plugin-se pkgs.openssl pkgs.xxd];
      text = ''
        set -euo pipefail
        TARGET_DIR="$(pwd -P)"
        AGENT_NAME="${name}"
        AGENT_USER="${agent.user}"
        AGENT_HOME="/Users/$AGENT_USER"
        ACL_RULE="${aclRule}"
        STALE_LOCK="/tmp/.claude-acl-locks"

        if [[ "$TARGET_DIR" == "/" || "$TARGET_DIR" == "$HOME" ]]; then
          echo "Error: Refusing to run ${agent.cliName} in$TARGET_DIR. cd into a project directory first." >&2
          exit 1
        fi

        mkdir -p "$STALE_LOCK"
        for lockfile in "$STALE_LOCK/$AGENT_NAME"-*.lock; do
          [[ -e "$lockfile" ]] || continue
          stale_pid="''${lockfile##*-}"
          stale_pid="''${stale_pid%.lock}"
          if ! kill -0 "$stale_pid" 2>/dev/null; then
            stale_dir="$(cat "$lockfile")"
            [[ -d "$stale_dir" ]] && /bin/chmod -R -a "$ACL_RULE" "$stale_dir" 2>/dev/null || true
            rm -f "$lockfile"
          fi
        done

        ${resolveKey.${agent.auth.strategy}}

        # /private/tmp, not /tmp: Seatbelt matches resolved paths, and a
        # TMP_DIR under the /tmp symlink never matches (tested).
        SESSION_TMP="$(sudo -u "$AGENT_USER" /usr/bin/mktemp -d "/private/tmp/claude-$AGENT_NAME.XXXXXX")"
        LOCK_FILE="$STALE_LOCK/$AGENT_NAME-$$.lock"

        cleanup() {
          local exit_code=$?
          ${lib.optionalString agent.autoGrantWorkspaceACL ''
          /bin/chmod -R -a "$ACL_RULE" "$TARGET_DIR" 2>/dev/null || true
          rm -f "$LOCK_FILE"
        ''}
          sudo -u "$AGENT_USER" /bin/rm -rf "$SESSION_TMP" 2>/dev/null || true
          exit "$exit_code"
        }
        trap cleanup EXIT INT TERM HUP QUIT

        # The key never goes on a command line: sudo stays alive as root for the
        # whole session, and any user reads its argv with `ps` (tested). It goes
        # through stdin into a 0600 file of the agent's, which Claude Code reads
        # through apiKeyHelper; the file goes away with the session tmp.
        KEY_FILE="$SESSION_TMP/.anthropic-key"
        printf '%s' "$RESOLVED_API_KEY" |
          sudo -u "$AGENT_USER" /usr/bin/env /bin/sh -c 'umask 077 && cat > "$1"' sh "$KEY_FILE"
        unset RESOLVED_API_KEY
        SETTINGS_JSON="$(printf '{"apiKeyHelper":"/bin/cat %s"}' "$KEY_FILE")"

        ${lib.optionalString agent.autoGrantWorkspaceACL ''
          echo "$TARGET_DIR" > "$LOCK_FILE"
          /bin/chmod -R +a "$ACL_RULE" "$TARGET_DIR" 2>/dev/null || true
        ''}

        PROXY_URL="http://127.0.0.1:${toString agent.proxy.port}"

        sudo -u "$AGENT_USER" -H \
          env -i \
              HOME="$AGENT_HOME" \
              USER="$AGENT_USER" \
              LOGNAME="$AGENT_USER" \
              TERM="''${TERM:-xterm-256color}" \
              TMPDIR="$SESSION_TMP" \
              PATH="${lib.makeBinPath ([cfg.package pkgs.git pkgs.ripgrep pkgs.fd pkgs.nodejs] ++ agent.extraPackages)}:/usr/bin:/bin" \
              HTTP_PROXY="$PROXY_URL" \
              HTTPS_PROXY="$PROXY_URL" \
              http_proxy="$PROXY_URL" \
              https_proxy="$PROXY_URL" \
              NO_PROXY="localhost,127.0.0.1" \
              ${extraEnvArgs} \
          /usr/bin/sandbox-exec \
            -f "${sandboxProfile}" \
            -D TARGET_DIR="$TARGET_DIR" \
            -D AGENT_HOME="$AGENT_HOME" \
            -D TMP_DIR="$SESSION_TMP" \
            -D PROXY_PORT="${toString agent.proxy.port}" \
            "${lib.getExe cfg.package}" --settings "$SETTINGS_JSON" "$@"
      '';
    };

  agentInitHelper = pkgs.writeShellApplication {
    name = "claude-agent-init";
    runtimeInputs = [pkgs.age pkgs.age-plugin-se pkgs.openssl pkgs.xxd pkgs.coreutils];
    text = ''
      set -euo pipefail
      AGENT_NAME="''${1:-}"
      MODE="''${2:---se}"
      [[ -z "$AGENT_NAME" ]] && { echo "Usage: claude-agent-init <agent-name> [--se | --hkdf]" >&2; exit 1; }

      SE_DIR="$HOME/.config/claude-se"
      mkdir -p "$SE_DIR" && chmod 700 "$SE_DIR"
      read -r -s -p "Enter ANTHROPIC_API_KEY for agent '$AGENT_NAME': " API_KEY
      echo ""

      if [[ "$MODE" == "--se" ]]; then
        KEY_FILE="$SE_DIR/$AGENT_NAME.key"
        CIPHERTEXT="$SE_DIR/$AGENT_NAME-anthropic.key.age"
        [[ ! -f "$KEY_FILE" ]] && age-plugin-se keygen --access-control any-biometry -o "$KEY_FILE" && chmod 600 "$KEY_FILE"
        RECIPIENT="$(grep -o 'age1se1[a-z0-9]*' "$KEY_FILE")"
        echo -n "$API_KEY" | age -r "$RECIPIENT" -o "$CIPHERTEXT" && chmod 600 "$CIPHERTEXT"
      elif [[ "$MODE" == "--hkdf" ]]; then
        MASTER_KEY="$SE_DIR/master.key"
        MASTER_SEED="$SE_DIR/master-seed.age"
        CIPHERTEXT="$SE_DIR/$AGENT_NAME-anthropic.key.age"
        [[ ! -f "$MASTER_KEY" ]] && age-plugin-se keygen --access-control any-biometry -o "$MASTER_KEY" && chmod 600 "$MASTER_KEY"
        if [[ ! -f "$MASTER_SEED" ]]; then
          RECIPIENT="$(grep -o 'age1se1[a-z0-9]*' "$MASTER_KEY")"
          openssl rand 32 | age -r "$RECIPIENT" -o "$MASTER_SEED" && chmod 600 "$MASTER_SEED"
        fi
        SEED_HEX="$(age --decrypt -i "$MASTER_KEY" "$MASTER_SEED" | xxd -p -c 64)"
        AGENT_HEX_KEY="$(openssl kdf -keylen 32 -kdfopt digest:SHA256 -kdfopt hexkey:"$SEED_HEX" -kdfopt info:"claude-agent:$AGENT_NAME" HKDF | tr -d ':')"
        echo -n "$API_KEY" | openssl enc -e -aes-256-cbc -pbkdf2 -K "$AGENT_HEX_KEY" -iv 00000000000000000000000000000000 -out "$CIPHERTEXT"
        chmod 600 "$CIPHERTEXT"
        unset SEED_HEX AGENT_HEX_KEY
      fi
    '';
  };
in {
  options.services.claude-sandbox = {
    enable = lib.mkEnableOption "Multi-agent isolated macOS users & Seatbelt sandboxes for Claude Code";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.claude-code;
      defaultText = lib.literalExpression "claude-code-nix's pinned claude-code";
      description = "The Claude Code the agents run.";
    };
    masterHkdf = {
      seIdentityFile = lib.mkOption {
        type = lib.types.str;
        default = "$HOME/.config/claude-se/master.key";
      };
      encryptedMasterSeedFile = lib.mkOption {
        type = lib.types.str;
        default = "$HOME/.config/claude-se/master-seed.age";
      };
    };
    agents = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule agentSubmodule);
      default = {};
    };
  };

  config = lib.mkIf (cfg.enable && enabledAgents != {}) {
    users = {
      knownUsers = lib.mapAttrsToList (_: a: a.user) enabledAgents;
      knownGroups = lib.mapAttrsToList (_: a: a.user) enabledAgents;
      groups = lib.mapAttrs' (_: a: lib.nameValuePair a.user {inherit (a) gid;}) enabledAgents;
      users = lib.mapAttrs' (_: a:
        lib.nameValuePair a.user {
          inherit (a) uid gid;
          home = "/Users/${a.user}";
          createHome = true;
          shell = "/bin/bash";
        })
      enabledAgents;
    };

    system.activationScripts.postActivation.text = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (_: a: ''
        mkdir -p "/Users/${a.user}/.claude" "/Users/${a.user}/.config" "/Users/${a.user}/.cache"
        chown -R "${a.user}:${a.user}" "/Users/${a.user}"
        chmod 700 "/Users/${a.user}"
      '')
      enabledAgents
    );

    launchd.daemons = lib.mapAttrs' (name: a:
      lib.nameValuePair "claude-sandbox-proxy-${name}" {
        serviceConfig = {
          Label = "org.nixos.claude-sandbox-proxy-${name}";
          ProgramArguments = ["${pkgs.tinyproxy}/bin/tinyproxy" "-d" "-c" "${mkTinyproxyConf name a}"];
          KeepAlive = true;
          RunAtLoad = true;
          StandardOutPath = "/var/log/claude-proxy-${name}.log";
          StandardErrorPath = "/var/log/claude-proxy-${name}.err";
        };
      })
    enabledAgents;

    environment.etc."sudoers.d/claude-sandbox".text = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (_: a: ''
        Defaults:${a.user} !lecture
        %admin ALL=(${a.user}) NOPASSWD: /usr/bin/mktemp, /bin/rm, /usr/bin/env, /usr/bin/test, /bin/cat
      '')
      enabledAgents
    );

    environment.systemPackages = (lib.mapAttrsToList mkAgentWrapper enabledAgents) ++ [agentInitHelper];
  };
}
