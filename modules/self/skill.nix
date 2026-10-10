# The skill every instance gets: the procedures behind the rule.
{
  name,
  dir,
  version,
  repo,
  apply,
  checkout,
}: let
  repoText =
    if repo != null
    then "`${repo}`"
    else "the nix config that imports claude-code-nix (ask the user where it is)";
  applyText =
    if apply != null
    then apply
    else "rebuild that config (for example `darwin-rebuild switch --flake <repo>`)";
in ''
  ---
  name: claude-code-nix
  description: How to change this machine's Claude Code setup, which nix manages through the claude-code-nix flake. Use when adding, editing or removing a Claude Code rule, skill, agent, slash command or CLAUDE.md; when bumping the Claude Code version; when a file in the Claude config dir turns out to be a read-only symlink; or when asked how Claude Code is installed here.
  ---

  # Changing this Claude Code setup (claude-code-nix)

  - **This instance:** the `${name}` command, config dir `${dir}`, Claude Code ${version}.
  - **Defined in:** ${repoText}, under `programs.claude-code-nix`.
  - **Applying a change:** ${applyText}.

  ## What nix manages

  Run `ls -l ${dir}/rules ${dir}/skills ${dir}/agents ${dir}/commands ${dir}/CLAUDE.md`, and `readlink -f` an entry to see where it really leads. Home-manager links go through `/nix/store/…-hm_*` first.
  - Entries that resolve into `/nix/store` belong to nix and are read-only.${
    if checkout != null
    then "\n  - Entries that resolve into `${checkout}` are nix-defined but editable. Edit the real path that `readlink -f` gives, because Edit and Write refuse to write through a symlink. That prompts for permission unless `selfManagement.allowCheckoutEdits` is on. The edit is a change to that repo, so commit it."
    else ""
  }
  - Everything else is hand-made, and nix leaves it alone.

  ## Add, change or remove a rule, skill, agent or command

  Edit ${repoText}. Under `programs.claude-code-nix`:
  - `shared.<kind>.<name>`: every instance gets it.
  - `instances.<instance>.<kind>.<name>`: one instance only. Setting it to `null` drops a shared entry, or the built-in `claude-code-nix` one, for that instance.

  What each kind takes:
  - `rules`, `agents` and `commands`: a path to a `.md` file, or the text itself.
  - `skills`: a path to the skill's folder (`SKILL.md` plus any scripts), or the `SKILL.md` text.
  - `memory`: that instance's `CLAUDE.md`, as a path or text. Leave it unset to keep `CLAUDE.md` hand-written.
  - `settings`: keys to merge into `settings.json`, which stays a normal, writable file.
    - Keys nix sets win over hand edits on every rebuild.
    - The permission lists (`allow`, `deny`, `ask`, `additionalDirectories`) are combined with what's there.
    - Removing a key from nix takes it back out of `settings.json`.
    - To change a nix-set key for good, change it in nix. A hand edit only lasts until the next rebuild.

  Nix already allows `Read` on the managed folders and on `/nix/store`, and denies `Edit(//nix/**)`, which also blocks Write. Never write under `/nix`.

  Then apply, check the new symlink with `ls -l`, and start a new session. Rules and `CLAUDE.md` load at session start, and `/context` lists them.

  If something is only needed on this machine, or only for now, it can be a plain file in `${dir}` instead. Nix leaves non-symlinks alone.

  ## Bump the Claude Code version

  The pin lives in the claude-code-nix repo, not in ${repoText}:
  1. In that repo, run `pkgs/claude-code/update.sh` for the stable release, or add `--latest`. Add `--dry-run` to only compare the versions.
  2. Check the build with `nix build .#claude-code && ./result/bin/claude --version`.
  3. Commit and push.
  4. In ${repoText}, run `nix flake update claude-code-nix`, then apply.
  5. Check that `${name} --version` prints the new version.

  Never update Claude Code any other way.
''
