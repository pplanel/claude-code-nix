# The atuin plugin: records every Bash command Claude runs in atuin's
# history, authored "<agent>/<session title>" (see atuin-author.sh). Loaded
# with --plugin-dir from the store (instances' `plugins`), never published,
# so it needs no change to settings.json.
#   scripts/atuin-author.sh  PreToolUse, PostToolUse, PostToolUseFailure on
#                            Bash: sets ATUIN_HISTORY_AUTHOR, then runs
#                            `atuin hook claude-code`
{
  lib,
  runCommand,
  writeText,
  jq,
  atuin,
  # How the script asks for the host's name; a test can swap it. Not
  # `hostname`: callPackage would fill that with pkgs.hostname.
  hostnameCommand ? "/bin/hostname",
}: let
  script = writeText "atuin-author.sh" (builtins.replaceStrings
    ["@JQ@" "@ATUIN@" "@HOSTNAME@"]
    [(lib.getExe jq) (lib.getExe atuin) hostnameCommand]
    (builtins.readFile ./atuin-author.sh));

  hook = {
    matcher = "Bash";
    hooks = [
      {
        type = "command";
        command = "${placeholder "out"}/scripts/atuin-author.sh";
        timeout = 5;
      }
    ];
  };
  hooks = builtins.toJSON {
    # atuin pairs each command's start with its end, failed or not.
    hooks = lib.genAttrs ["PreToolUse" "PostToolUse" "PostToolUseFailure"] (_: [hook]);
  };
  manifest = builtins.toJSON {
    name = "atuin";
    version = "1.0.0";
    description = "Records every Bash command Claude runs in atuin's history, authored <agent>/<session title>.";
    author.name = "claude-code-nix";
  };
in
  runCommand "claude-code-atuin-plugin" {
    passAsFile = ["hooks" "manifest"];
    inherit hooks manifest;
  } ''
    mkdir -p $out/.claude-plugin $out/hooks $out/scripts
    cp $manifestPath $out/.claude-plugin/plugin.json
    cp $hooksPath $out/hooks/hooks.json
    install -m755 ${script} $out/scripts/atuin-author.sh
    if grep -rn '@[A-Z_]*@' $out; then echo "unfilled placeholders" >&2; exit 1; fi
  ''
