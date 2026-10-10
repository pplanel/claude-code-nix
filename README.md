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
| `settings` | merged into `<configDir>/settings.json` (see below) |
| `plugins` | not linked: the instance's command loads each with `--plugin-dir` (see below) |

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

### `settings`

`settings` (in `shared` or per instance) holds keys that are merged into `<configDir>/settings.json` on activation. The merge is `modules/settings-merge.jq`, and `nix flake check` tests it.

The file is never linked, so Claude, `/config` and permission prompts can still write to it. How the merge treats it:
- **Keys nix sets win over hand edits** on every activation.
- **The permission lists** (`allow`, `deny`, `ask`, `additionalDirectories`) are combined with what's there, with no duplicates.
- **Anything nix set last time and no longer sets is taken back out.** The previous set is kept in `<configDir>/.claude-code-nix/settings.json`.
- **Everything else is left alone.**

### Symlinks and permissions

Claude Code checks a symlink and every path it resolves through; see <https://code.claude.com/docs/en/permissions#symlinks>. A test with real sessions showed:
- **A Read through a link is allowed only when every path on the chain is allowed:** the link, home-manager's middle hop, and the target. Separate rules are fine. Here the hop and the target are both in `/nix/store`.
- **A write through a link whose target is outside the working directories counts as sensitive,** and no allow rule approves it. Edit and Write also refuse a path that is itself a symlink. So checkout-linked entries are edited at their real path (`readlink -f`), where `Edit(<checkout>/**)` does apply.
- **A deny on `Edit(...)` also blocks Write,** and deny wins over allow.

So `selfManagement.permissions`, on by default, adds these to every instance's settings:

| Rule | Why |
|---|---|
| allow `Read(<configDir>/{rules,skills,agents,commands}/**)` | the link side of managed entries |
| allow `Read(//nix/store/**)` | the hop and the target |
| allow `Read(<checkout>/**)` | when `checkout` is set |
| allow `Edit(<checkout>/**)` | only with `selfManagement.allowCheckoutEdits = true` |
| deny `Edit(//nix/**)` | nothing writes under `/nix` |

### Plugins

`plugins` (in `shared` or per instance) lists plugin folders, each with `.claude-plugin/plugin.json`. The instance's command passes each one to Claude Code with `--plugin-dir`, so:
- nothing is installed or published
- plugins load in place from the read-only store, and show up as `<name>@inline`
- they load only when Claude is started through that command, not from the desktop app or IDE extensions

### Handoff

`handoff` builds the handoff plugin (`pkgs/handoff-plugin`) with your hosts in it, and loads it in the instances you list:

```nix
programs.claude-code-nix.handoff = {
  enable = true;
  githubOwner = "me";                 # only github.com/me/* repos are handed off
  instances = ["claude-personal"];    # load the plugin and its status line
  hosts = {                           # every machine, by `hostname -s`
    laptop  = { src = "/Users/me/src"; configDir = "/Users/me/.claude"; command = "claude"; defaultTarget = "desktop"; };
    desktop = { src = "/Users/me/src"; configDir = "/Users/me/.claude"; command = "claude"; defaultTarget = "laptop"; };
  };
};
```

What it does:
- **`/handoff [host]`** (the `handoff` skill and `bin/claude-handoff`) moves the current session to another host. It commits and pushes the work on a `handoff/…` branch, checks it out there, copies the transcript and the project's memory into that host's config dir, and resumes the session in tmux (`work:handoff-<repo>`).
- **The quota hook** (`UserPromptSubmit` and `PostToolBatch`) warns at 70% of the 5-hour or weekly limit, and at 80% tells Claude to hand off to `defaultTarget`.
- **The status line** saves the rate limits that the hook reads. Plugins can't set `statusLine`, so the module sets it in the instance's `settings` instead.

The handoff copies only that one session. Config dirs are never synced between hosts.

`nix flake check` builds the plugin for example hosts, tests the hook's answers, and runs `claude plugin validate` on it.

### Layout

`programs.claude-code-nix.layout` gives `{ <name> = { command; configDir; }; }`, with absolute paths, for tools that need to know where each account lives, such as claude-handoff.

The option is called `claude-code-nix` because home-manager already has its own `programs.claude-code`, which manages a single config.
