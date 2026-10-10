# claude-code-nix

Claude Code's native binary, pinned in nix, and a home-manager module that runs it as several named commands, each with its own account, config dir and rules.

## Package

```sh
nix build .#claude-code && ./result/bin/claude --version
```

`pkgs/claude-code/manifest.json` pins the version: Anthropic's release manifest, cut down to the mac and Linux platforms. The wrapper turns off the auto-updater, so a version only changes when the pin does:

```sh
pkgs/claude-code/update.sh            # pin the current stable release
pkgs/claude-code/update.sh --latest   # or the latest one
pkgs/claude-code/update.sh --dry-run  # just show what would change
```

Then commit `manifest.json`, and bump this input wherever it's used.

## Instances

```nix
# flake inputs
claude-code-nix.url = "github:pplanel/claude-code-nix";
claude-code-nix.inputs.nixpkgs.follows = "nixpkgs";

# nix-darwin modules
claude-code-nix.darwinModules.default

# home-manager config
programs.claude-code-nix = {
  enable = true;
  instances = {
    claude = {};                              # default ~/.claude
    claude-personal = {
      configDir = "src/pplanel/.claude";      # relative to $HOME
      apiKeyEnv = "CLAUDE_PERSONAL_API_KEY";  # else ANTHROPIC_API_KEY is unset
      rules.machines = ./rules/machines.md;   # -> <configDir>/rules/machines.md
    };
  };
};
```

Each instance becomes a command on `PATH` named after it. Its rules go into `<configDir>/rules/`, which Claude Code loads in every session without `@imports`.

`programs.claude-code-nix.layout` gives `{ <name> = { command; configDir; }; }` (absolute paths) for tools that need to know where each account lives, such as claude-handoff.

The option is called `claude-code-nix` because home-manager already has its own `programs.claude-code`, which manages a single config.
