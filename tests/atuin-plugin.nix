# The atuin plugin's script with a fake atuin (prints the author, its
# arguments and the stdin it got) and a fake hostname, against transcripts
# built here; then the module, to check it takes home-manager's atuin.
{
  lib,
  pkgs,
  runCommand,
  writeShellScriptBin,
  writeShellScript,
  callPackage,
}: let
  fakeAtuin = writeShellScriptBin "atuin" ''
    echo "author=$ATUIN_HISTORY_AUTHOR"
    echo "args=$*"
    echo "stdin=$(cat)"
  '';
  plugin = callPackage ../pkgs/atuin-plugin {
    atuin = fakeAtuin;
    hostnameCommand = "${writeShellScript "hostname" "echo testhost"}";
  };

  # The module with home-manager's programs.atuin stubbed, and `instances`
  # stubbed to the field the module sets.
  eval = lib.evalModules {
    modules = [
      ../modules/atuin.nix
      {
        options.programs.atuin = {
          enable = lib.mkOption {type = lib.types.bool;};
          package = lib.mkOption {type = lib.types.package;};
        };
        options.programs.claude-code-nix.instances = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule {
            options.plugins = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [];
            };
          });
          default = {};
        };
        config = {
          _module.args = {inherit pkgs;};
          programs.atuin = {
            enable = true;
            package = fakeAtuin;
          };
          programs.claude-code-nix.atuin.instances = ["personal"];
        };
      }
    ];
  };
  modulePlugins = eval.config.programs.claude-code-nix.instances.personal.plugins;
  moduleScript = "${builtins.head modulePlugins}/scripts/atuin-author.sh";
in
  runCommand "atuin-plugin-test" {} ''
    failed=0
    ok() { echo "ok   $1"; }
    fail() { echo "FAIL $1"; echo "  got: $2"; failed=1; }
    script=${plugin}/scripts/atuin-author.sh
    export TMPDIR=$PWD/tmp && mkdir -p $TMPDIR
    t=$PWD/transcript.jsonl && : > $t

    # Runs the hook for session $1 with the transcript, as agent $2 (empty:
    # unset), and prints the author atuin got.
    run() {
      if [ -n "$2" ]; then export CLAUDE_AGENT_NAME="$2"; else unset CLAUDE_AGENT_NAME; fi
      printf '{"session_id":"%s","transcript_path":"%s","tool_name":"Bash"}' "$1" "$3" |
        $script | sed -n 's/^author=//p'
    }
    check() { [ "$2" = "$3" ] && ok "$1: $2" || fail "$1 (want $3)" "$2"; }

    check "no title yet" "$(run s1 Liet $t)" "Liet"
    echo '{"type":"user","message":"hi"}' >> $t
    echo '{"type":"custom-title","customTitle":"first title","sessionId":"s1"}' >> $t
    check "a title" "$(run s1 Liet $t)" "Liet/first title"
    echo '{"type":"custom-title","customTitle":"renamed","sessionId":"s1"}' >> $t
    check "after /rename" "$(run s1 Liet $t)" "Liet/renamed"
    printf '{"type":"custom-title","customTitle":"half' >> $t
    check "a line still being written" "$(run s1 Liet $t)" "Liet/renamed"
    echo ' written","sessionId":"s1"}' >> $t
    check "the same line, finished" "$(run s1 Liet $t)" "Liet/half written"
    check "no agent name: the host" "$(run s1 "" $t)" "testhost/half written"
    u=$PWD/u.jsonl
    echo '{"type":"custom-title","customTitle":"say \"hi\" é","sessionId":"s2"}' > $u
    check "quotes and accents" "$(run s2 Liet $u)" 'Liet/say "hi" é'
    check "no transcript" "$(run s3 Liet /nonexistent)" "Liet"

    res=$(printf '{"session_id":"s1","transcript_path":"%s","x":1}' $t | CLAUDE_AGENT_NAME=Liet $script)
    echo "$res" | grep -qx 'args=hook claude-code' && ok "runs atuin hook claude-code" || fail "args" "$res"
    echo "$res" | grep -qF "stdin={\"session_id\":\"s1\",\"transcript_path\":\"$t\",\"x\":1}" &&
      ok "hands the JSON on unchanged" || fail "stdin" "$res"

    grep -q '${fakeAtuin}' ${moduleScript} &&
      ok "module: runs home-manager's atuin" || fail "module atuin" "$(grep -o '/nix/store/[^ ]*atuin[^ ]*' ${moduleScript})"
    [ ${toString (builtins.length modulePlugins)} = 1 ] && ok "module: plugin in the listed instance" ||
      fail "module plugins" "${toString (builtins.length modulePlugins)}"

    [ "$failed" = 0 ] && touch $out
  ''
