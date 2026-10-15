# services.claude-sandbox (nix-darwin): Claude Code agents isolated from their
# owner. Each agent is its own macOS user, runs inside a Seatbelt profile, and
# reaches the network only through its own filtering proxy. The design, the
# defaults and what testing taught are in ./DESIGN.md.
#
# Files here:
#   claude-sandbox.sb  the base Seatbelt profile, shared by every agent
#   in-place.sb        write denies appended in in-place mode
#   sensitive.sb       the read deny on credentials, appended after grants
#   wrapper.sh         the claude-<name> command (Nix adds a preamble)
self: {
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.services.claude-sandbox;

  agentSubmodule = {
    name,
    config,
    ...
  }: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to create this agent.";
      };
      user = mkOption {
        type = types.str;
        default = "_claude_${name}";
        description = "The agent's macOS user (and group).";
      };
      uid = mkOption {
        type = types.int;
        description = "The agent user's uid. Pick one no other user has.";
      };
      gid = mkOption {
        type = types.int;
        default = config.uid;
        description = "The agent group's gid.";
      };
      cliName = mkOption {
        type = types.str;
        default = "claude-${name}";
        description = "The command that starts this agent.";
      };
      extraPackages = mkOption {
        type = types.listOf types.package;
        default = [];
        description = "Added to the agent's PATH, after claude, git, ripgrep, fd and nodejs.";
      };
      extraEnv = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Added to the agent's environment, which otherwise starts empty.";
      };

      git = {
        name = mkOption {
          type = types.str;
          default = config.cliName;
          description = "Author and committer name for the agent's commits.";
        };
        email = mkOption {
          type = types.str;
          default = "${config.user}@localhost";
          description = "Author and committer email for the agent's commits.";
        };
      };

      workspace.mode = mkOption {
        type = types.enum ["clone" "in-place"];
        default = "clone";
        description = ''
          Where the agent works.
          - clone: in its own clone of the repository, in its home. The
            owner's tree gets no ACL and the agent's user can reach nothing of
            the owner's. Work comes back as `refs/remotes/<cliName>/*` in the
            owner's repo when the session ends.
          - in-place: in the owner's tree, through ACLs on it and on the
            directories above it, removed at the end. .git, .claude and hook
            files (.envrc, .mcp.json, .nvim.lua, .exrc) are write-denied, since
            the owner's tools run them. Seatbelt is then the only barrier
            between the agent and anything in the owner's home it can name.
        '';
      };

      read = {
        paths = mkOption {
          type = types.listOf types.str;
          default = [];
          example = ["~/src/shared-docs"];
          description = ''
            The owner's paths this agent may always read (~ is the owner's
            home), opened with ACLs and a Seatbelt rule for each session.
            Credentials stay denied (sensitive.sb).
          '';
        };
        allowRuntimeGrants = mkOption {
          type = types.bool;
          default = true;
          description = "Allow `<cliName> --read <path>` to grant one more read for one session.";
        };
      };

      homeReadScope = mkOption {
        type = types.enum ["full" "state-only"];
        default = "full";
        description = ''
          What the agent reads of its own home.
          - full: all of it. In clone mode that includes the clones of every
            project this agent worked on.
          - state-only: Claude Code's state (.claude, .claude.json,
            .config/claude, .cache, .npm) and the current workspace. For real
            separation between projects, prefer one agent per project.
        '';
      };

      # Everything here is closed by default; the agent's proxy is its only
      # way out. SBPL filters network rules by port, with the host either
      # "localhost" or "*": no rule can name one LAN host or one interface
      # (awdl0, en0, utun*). Each option below says exactly what it opens.
      network = {
        localhostPorts = mkOption {
          type = types.listOf types.port;
          default = [];
          example = [5432];
          description = "Local ports the agent may connect to (TCP and UDP), e.g. a database. Not the owner's services: claude-mesh, other agents' proxies…";
        };
        listenPorts = mkOption {
          type = types.listOf types.port;
          default = [];
          example = [3000];
          description = "Local ports the agent may listen on, and connect to, e.g. a dev server it tests.";
        };
        directPorts = mkOption {
          type = types.listOf types.port;
          default = [];
          description = ''
            Ports the agent may reach on ANY host, without the proxy: the LAN,
            Tailscale, AWDL peers and the internet alike. Peer-to-peer traffic
            (AWDL, LAN) needs this; prefer proxy.allowedDomains for anything
            that has a host name.
          '';
        };
        bonjour = mkOption {
          type = types.bool;
          default = false;
          description = ''
            mDNS/DNS-SD: mDNSResponder's socket, the dnssd service, and UDP
            5353 out, in and bound, to any host. mDNSResponder also serves
            every DNS lookup, so this reopens DNS, an exfiltration channel.
          '';
        };
        unixSockets = mkOption {
          type = types.listOf types.str;
          default = [];
          description = ''
            Unix sockets the agent may connect to, by real path
            (/private/var/run/…, not /var/run/…). A daemon socket can be a way
            out of the sandbox: the nix daemon builds what it's asked
            (fixed-output derivations download outside the proxy), docker runs
            containers. Don't list those.
          '';
        };
        extraRules = mkOption {
          type = types.lines;
          default = "";
          description = "Raw SBPL appended to the profile, after the base and the options above.";
        };
      };

      proxy = {
        port = mkOption {
          type = types.port;
          description = "The agent's tinyproxy port on 127.0.0.1, its only way out.";
        };
        allowedDomains = mkOption {
          type = types.listOf types.str;
          default = ["^(.*\\.)?anthropic\\.com$" "^(.*\\.)?claude\\.ai$"];
          description = "Extended regexes of the hosts the proxy lets through (CONNECT to 443 only).";
        };
      };

      auth = {
        strategy = mkOption {
          type = types.enum ["secure-enclave" "hkdf-derived" "keychain" "sops-file"];
          default = "secure-enclave";
          description = "Where the wrapper gets the agent's API key at each start.";
        };
        seIdentityFile = mkOption {
          type = types.str;
          default = "$HOME/.config/claude-se/${name}.key";
          description = "secure-enclave: the age-plugin-se identity (made by claude-agent-init).";
        };
        encryptedSecretFile = mkOption {
          type = types.str;
          default = "$HOME/.config/claude-se/${name}-anthropic.key.age";
          description = "secure-enclave and hkdf-derived: the encrypted API key.";
        };
        keychainService = mkOption {
          type = types.str;
          default = "anthropic-api-key-${name}";
          description = "keychain: the generic password's service name, in the owner's keychain.";
        };
        sopsSecretPath = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "sops-file: a decrypted secret the agent's user can read.";
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

  # The agent's own home, read after sensitive.sb so its own ~/.config stays
  # readable (see the order in claude-sandbox.sb).
  homeRead = {
    full = ''
      ;; The agent's own home (homeReadScope = "full").
      (allow file-read* (subpath-firmlink (param "AGENT_HOME")))
    '';
    state-only = ''
      ;; Claude Code's state in the agent's home (homeReadScope = "state-only").
      (allow file-read*
        (subpath-firmlink (string-append (param "AGENT_HOME") "/.claude"))
        (subpath-firmlink (string-append (param "AGENT_HOME") "/.config/claude"))
        (subpath-firmlink (string-append (param "AGENT_HOME") "/.cache"))
        (subpath-firmlink (string-append (param "AGENT_HOME") "/.npm"))
        (literal-firmlink (string-append (param "AGENT_HOME") "/.claude.json")))
    '';
  };

  # The agent's `network` options as SBPL, one rule per port (SBPL takes no
  # port ranges).
  networkRules = agent: let
    n = agent.network;
    rules = kind: ports: lib.concatMapStrings (p: "  (${kind} \"${toString p}\")\n") ports;
    quoted = p:
      assert lib.assertMsg (!lib.hasInfix "\"" p && !lib.hasInfix "\\" p)
      "services.claude-sandbox: network.unixSockets: no quotes or backslashes in ${p}"; ''"${p}"'';
  in
    lib.concatStrings [
      (lib.optionalString (n.localhostPorts != []) ''
        ;; network.localhostPorts
        (allow network-outbound
        ${rules "remote ip" (map (p: "localhost:${toString p}") n.localhostPorts)})
      '')
      (lib.optionalString (n.listenPorts != []) ''
        ;; network.listenPorts: listen, accept, and connect to test them
        (allow network-bind network-inbound
        ${rules "local ip" (map (p: "localhost:${toString p}") n.listenPorts)})
        (allow network-outbound
        ${rules "remote ip" (map (p: "localhost:${toString p}") n.listenPorts)})
      '')
      (lib.optionalString (n.directPorts != []) ''
        ;; network.directPorts: any host, without the proxy
        (allow network-outbound
        ${rules "remote ip" (map (p: "*:${toString p}") n.directPorts)})
      '')
      (lib.optionalString n.bonjour ''
        ;; network.bonjour (also reopens DNS: mDNSResponder serves both)
        (allow network-outbound
          (literal "/private/var/run/mDNSResponder")
          (remote udp "*:5353"))
        (allow network-bind network-inbound (local udp "*:5353"))
        (allow mach-lookup (global-name "com.apple.dnssd.service"))
      '')
      (lib.optionalString (n.unixSockets != []) ''
        ;; network.unixSockets
        (allow network-outbound
        ${lib.concatMapStrings (p: "  (literal ${quoted p})\n") n.unixSockets})
      '')
      (lib.optionalString (n.extraRules != "") ''
        ;; network.extraRules
        ${n.extraRules}
      '')
    ];

  # The profile is head + this session's grants + tail; the wrapper joins
  # them, since grants come from the command line.
  profileHead = name: agent:
    pkgs.writeText "claude-sandbox-${name}-head.sb" (
      builtins.readFile ./claude-sandbox.sb
      + lib.optionalString (agent.workspace.mode == "in-place") ("\n" + builtins.readFile ./in-place.sb)
      + lib.optionalString (networkRules agent != "") ("\n" + networkRules agent)
      + "\n;; Read grants (read.paths, --read), added by the wrapper:\n"
    );
  profileTail = name: agent:
    pkgs.writeText "claude-sandbox-${name}-tail.sb" (
      "\n" + builtins.readFile ./sensitive.sb + "\n" + homeRead.${agent.homeReadScope}
    );

  # Chosen at build time: a bash `case` on a constant fails shellcheck.
  resolveKey = agent:
    {
      "secure-enclave" = ''
        note "Touch ID required to unlock the Secure Enclave key"
        RESOLVED_API_KEY="$(age --decrypt -i "${agent.auth.seIdentityFile}" "${agent.auth.encryptedSecretFile}" | tr -d '\n\r')"
      '';
      "hkdf-derived" = ''
        note "Touch ID required to derive the key"
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
    }
    .${
      agent.auth.strategy
    };

  mkAgentWrapper = name: agent: let
    home = "/Users/${agent.user}";
    proxyUrl = "http://127.0.0.1:${toString agent.proxy.port}";
    agentPath = lib.makeBinPath ([cfg.package pkgs.git pkgs.ripgrep pkgs.fd pkgs.nodejs] ++ agent.extraPackages);
    # The agent's whole environment: the wrapper starts it with env -i.
    agentEnv =
      {
        HOME = home;
        USER = agent.user;
        LOGNAME = agent.user;
        PATH = "${agentPath}:/usr/bin:/bin";
        HTTP_PROXY = proxyUrl;
        HTTPS_PROXY = proxyUrl;
        http_proxy = proxyUrl;
        https_proxy = proxyUrl;
        NO_PROXY = "localhost,127.0.0.1";
        GIT_AUTHOR_NAME = agent.git.name;
        GIT_AUTHOR_EMAIL = agent.git.email;
        GIT_COMMITTER_NAME = agent.git.name;
        GIT_COMMITTER_EMAIL = agent.git.email;
      }
      // agent.extraEnv;
  in
    pkgs.writeShellApplication {
      name = agent.cliName;
      runtimeInputs = [pkgs.coreutils pkgs.git pkgs.age pkgs.age-plugin-se pkgs.openssl pkgs.xxd];
      text =
        ''
          # ---- generated by modules/sandbox/default.nix for agent "${name}"
          CLI_NAME=${lib.escapeShellArg agent.cliName}
          AGENT_NAME=${lib.escapeShellArg name}
          AGENT_USER=${lib.escapeShellArg agent.user}
          AGENT_HOME=${lib.escapeShellArg home}
          PROXY_PORT=${toString agent.proxy.port}
          CLAUDE_BIN=${lib.escapeShellArg (lib.getExe cfg.package)}
          WORKSPACE_MODE=${agent.workspace.mode}
          ALLOW_RUNTIME_GRANTS=${
            if agent.read.allowRuntimeGrants
            then "1"
            else "0"
          }
          PROFILE_HEAD=${profileHead name agent}
          PROFILE_TAIL=${profileTail name agent}
          FIXED_READ_PATHS=(${lib.escapeShellArgs agent.read.paths})
          AGENT_ENV=(${lib.escapeShellArgs (lib.mapAttrsToList (k: v: "${k}=${v}") agentEnv)} "TERM=''${TERM:-xterm-256color}")
          resolve_key() {
            ${resolveKey agent}
          }
          # ---- end of generated preamble
        ''
        + builtins.readFile ./wrapper.sh;
    };

  agentInitHelper = pkgs.writeShellApplication {
    name = "claude-agent-init";
    runtimeInputs = [pkgs.age pkgs.age-plugin-se pkgs.openssl pkgs.xxd pkgs.coreutils];
    text = ''
      # Stores an agent's API key for the secure-enclave (--se, default) or
      # hkdf-derived (--hkdf) strategy, in ~/.config/claude-se. Run it in a
      # login session: an enclave key works only in the context that made it.
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
    enable = lib.mkEnableOption "Claude Code agents as isolated macOS users in Seatbelt";
    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.claude-code;
      defaultText = lib.literalExpression "claude-code-nix's pinned claude-code";
      description = "The Claude Code the agents run.";
    };
    masterHkdf = {
      seIdentityFile = mkOption {
        type = types.str;
        default = "$HOME/.config/claude-se/master.key";
        description = "hkdf-derived: the master Secure Enclave identity.";
      };
      encryptedMasterSeedFile = mkOption {
        type = types.str;
        default = "$HOME/.config/claude-se/master-seed.age";
        description = "hkdf-derived: the encrypted 256-bit master seed.";
      };
    };
    agents = mkOption {
      type = types.attrsOf (types.submodule agentSubmodule);
      default = {};
      description = "The agents, by name.";
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

    # workspaces/ must exist: a sandboxed `git clone` may write only inside
    # its target, not create the parent.
    system.activationScripts.postActivation.text = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (_: a: ''
        mkdir -p "/Users/${a.user}/.claude" "/Users/${a.user}/.config" "/Users/${a.user}/.cache" "/Users/${a.user}/workspaces"
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

    # The wrapper runs as the owner (an admin) and acts as the agent through
    # these. /usr/bin/env takes any command, so this is "admins may run
    # anything as the agent": the agent is the less privileged side.
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
