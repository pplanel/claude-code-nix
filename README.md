# claude-code-nix

Claude Code's native binary, pinned in nix, and a home-manager module that runs it as several named commands, each with its own account, config dir and rules.

## Package

```sh
nix build .#claude-code && ./result/bin/claude --version
```

`pkgs/claude-code/manifest.json` pins the version: Anthropic's release manifest, cut down to the mac and Linux platforms. The wrapper turns off the auto-updater, so a version only changes when the pin does.

The wrapper also sets these to 1. They are only defaults, so any of them can be overridden for a single run:
- `DISABLE_TELEMETRY`
- `DISABLE_ERROR_REPORTING`
- `DISABLE_FEEDBACK_COMMAND`
- `CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY`
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`

Updating the pin:

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
  selfManagement.repo = "~/.config/nix-darwin";   # named in the built-in rule and skill
  shared = {                                      # every instance gets these
    rules.machines = ./claude/rules/machines.md;
    skills.deploy = ./claude/skills/deploy;       # a skill's whole folder
  };
  instances = {
    claude = {};                                  # default ~/.claude
    claude-personal = {
      configDir = "src/${config.home.username}/.claude";  # relative to $HOME
      apiKeyEnv = "CLAUDE_PERSONAL_API_KEY";      # else ANTHROPIC_API_KEY is unset
      agents.reviewer = ./claude/agents/reviewer.md;
      skills.deploy = null;                       # drop a shared entry here
    };
  };
};
```

Each instance becomes a command on `PATH`, named after the instance.

### What goes in a config dir

Each kind is a module in `modules/instance/`. An entry can be a path or the text itself.

| Option | Linked as |
|---|---|
| `rules.<name>` | `<configDir>/rules/<name>.md`, which loads in every session with no `@imports` |
| `skills.<name>` | `<configDir>/skills/<name>`. A path links the whole folder; text becomes its `SKILL.md`. |
| `agents.<name>` | `<configDir>/agents/<name>.md` |
| `commands.<name>` | `<configDir>/commands/<name>.md` |
| `memory` | `<configDir>/CLAUDE.md`. Unset by default, so `CLAUDE.md` stays hand-written and `/memory` can edit it. |

`shared` holds the same options. An instance adds to those entries, overrides one, or drops one by setting it to `null`.

Only the entries themselves are linked. The config dir and `rules/`, `skills/` and the other folders stay ordinary writable folders. That leaves room for hand-made rules and skills next to the managed ones, and `settings.json`, `projects/` and memory stay untouched.

### The built-in rule and skill

Every instance gets `rules/claude-code-nix.md` and `skills/claude-code-nix/`. They tell Claude:
- which command, config dir and version it is
- that it must not update itself
- which files are nix-managed
- how to change the setup or bump the version

`selfManagement.repo` and `selfManagement.apply` fill in where the setup lives and how a change gets applied. Drop them with `selfManagement.enable = false`, or for one instance with `rules.claude-code-nix = null;`.

### Editable links: `checkout`

Set `checkout` to the absolute path of a checkout of the consuming flake, for example `~/.config/nix-darwin` written out in full. Entries given as paths inside that flake then link to the checkout instead of the nix store, so Claude can edit them and the edit shows up as a diff there. Set it only on machines that have that checkout.

### Symlinks and permissions

See <https://code.claude.com/docs/en/permissions#symlinks>. Claude Code checks both a symlink and the file it points to:
- **Reading a managed file with the Read tool prompts,** because it resolves into `/nix/store`, outside the working directory. Loading rules and skills at startup isn't affected.
- **Edit and Write refuse to write to a path that is itself a symlink.** Checkout-linked files are therefore edited at their real path (`readlink -f`), which is outside the working directory and so prompts too.

Allow rules for `/nix/store` reads and checkout edits belong in the upcoming `settings` option.

### Layout

`programs.claude-code-nix.layout` gives `{ <name> = { command; configDir; }; }`, with absolute paths, for tools that need to know where each account lives, such as claude-handoff.

The option is called `claude-code-nix` because home-manager already has its own `programs.claude-code`, which manages a single config.
