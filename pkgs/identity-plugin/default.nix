# The identity plugin: each Mac's agent knows which Mac it is and who it is
# there. Built per setup, with the hosts baked in, and loaded with
# --plugin-dir from the store (instances' `plugins`), never published.
#   scripts/identity.sh  SessionStart: this Mac's identity/<host>/self.md and
#                        its latest moments (moments.md)
#   scripts/host-tag.sh  UserPromptSubmit: replies start "[<host>]: ", so a
#                        synced transcript shows where each was written
{
  lib,
  runCommand,
  writeText,
  jq,
  # The machines, by name (programs.claude-code-nix.hosts); only the names
  # are used.
  hosts,
  # The plugin's author, github.com/<githubOwner>.
  githubOwner,
}: let
  fill = text:
    builtins.replaceStrings
    ["@JQ@" "@HOSTS@"]
    [(lib.getExe jq) (lib.concatStringsSep " " (builtins.attrNames hosts))]
    text;
  script = name: writeText name (fill (builtins.readFile ./${name}));

  hook = name: {
    type = "command";
    command = "${placeholder "out"}/scripts/${name}";
    timeout = 5;
  };
  hooks = builtins.toJSON {
    hooks = {
      # Every start: new, resumed, cleared, and after a compaction.
      SessionStart = [{hooks = [(hook "identity.sh")];}];
      UserPromptSubmit = [{hooks = [(hook "host-tag.sh")];}];
    };
  };
  manifest = builtins.toJSON {
    name = "identity";
    version = "1.0.0";
    description = "Each Mac's agent knows which Mac it runs on and who it is there: its self.md and recent moments at every start, and replies tagged with the Mac.";
    author.name = githubOwner;
  };
in
  runCommand "claude-code-identity-plugin" {
    passAsFile = ["hooks" "manifest"];
    inherit hooks manifest;
  } ''
    mkdir -p $out/.claude-plugin $out/hooks $out/scripts
    cp $manifestPath $out/.claude-plugin/plugin.json
    cp $hooksPath $out/hooks/hooks.json
    install -m755 ${script "identity.sh"} $out/scripts/identity.sh
    install -m755 ${script "host-tag.sh"} $out/scripts/host-tag.sh
    # Nothing may be left unfilled.
    if grep -rn '@[A-Z_]*@' $out; then echo "unfilled placeholders" >&2; exit 1; fi
  ''
