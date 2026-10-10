# The rule every instance gets: short, always loaded.
{
  instances,
  version,
  repo,
  apply,
  checkout,
}: let
  list = builtins.concatStringsSep ", " (map (i: "`${i.command}` (config dir `${i.configDir}`)") instances);
  where =
    if repo != null
    then "in `${repo}`"
    else "in the nix config that imports claude-code-nix (ask the user where it is)";
in ''
  # Claude Code here is managed by nix (claude-code-nix)

  Claude Code ${version} is installed here by the claude-code-nix flake, as: ${list}. You are the one whose config dir is `$CLAUDE_CONFIG_DIR`, or `~/.claude` when that's unset.

  - **No self-updates.** The version is pinned, and the auto-updater is off. Don't run `claude update` or install another copy (brew, npm, the install script). The version changes only when the pin is bumped.
  - **Nix-managed files are symlinks.** In `rules/`, `skills/`, `agents/` and `commands/`, and `CLAUDE.md` when it's a symlink, entries that link into `/nix/store` are read-only and get replaced on the next rebuild. Don't edit, delete or replace them in place. Change them ${where}, then apply.${
    if checkout != null
    then " Entries that resolve into `${checkout}` (check with `readlink -f`) are editable at that real path, since Edit and Write won't write through a symlink. That edit is a change to that repo, so it needs committing."
    else ""
  }${
    if apply != null
    then " Applying: ${apply}."
    else ""
  }
  - **Never write under `/nix`.** Settings deny `Edit(//nix/**)`.
  - **Everything else in the config dir is ordinary and writable.** That covers a `CLAUDE.md` that isn't a symlink, hand-made rules and skills, `projects/` and memory. `settings.json` is writable too, but keys nix sets in it come back on every rebuild.
  - **This build sets telemetry, error reporting, the feedback command and survey, and nonessential traffic off by default.**
  - **To change this setup, use the `claude-code-nix` skill.** That covers adding a rule, skill, agent or command, and bumping the version.
''
