# Runs modules/settings-merge.jq on cases: input settings.json, what nix set
# last time (prev), what it sets now (new), and the expected result.
{
  lib,
  runCommand,
  jq,
}: let
  cases = {
    fresh-file = {
      input = {};
      prev = {};
      new = {
        model = "opus";
        permissions.allow = ["Read(//nix/store/**)"];
        permissions.deny = ["Edit(//nix/**)"];
      };
      expected = {
        model = "opus";
        permissions.allow = ["Read(//nix/store/**)"];
        permissions.deny = ["Edit(//nix/**)"];
      };
    };
    keeps-hand-edits = {
      input = {
        theme = "dark";
        permissions.allow = ["Bash(ls:*)" "Read(//nix/store/**)"];
        permissions.defaultMode = "acceptEdits";
      };
      prev = {permissions.allow = ["Read(//nix/store/**)"];};
      new = {permissions.allow = ["Read(//nix/store/**)"];};
      expected = {
        theme = "dark";
        permissions.allow = ["Bash(ls:*)" "Read(//nix/store/**)"];
        permissions.defaultMode = "acceptEdits";
      };
    };
    takes-back-dropped = {
      input = {
        model = "opus";
        theme = "dark";
        permissions.allow = ["Bash(ls:*)" "Read(//old/**)" "Read(//nix/store/**)"];
        permissions.deny = ["Edit(//nix/**)"];
      };
      prev = {
        model = "opus";
        permissions.allow = ["Read(//old/**)" "Read(//nix/store/**)"];
        permissions.deny = ["Edit(//nix/**)"];
      };
      new = {permissions.allow = ["Read(//nix/store/**)"];};
      expected = {
        theme = "dark";
        permissions.allow = ["Bash(ls:*)" "Read(//nix/store/**)"];
      };
    };
    no-duplicates = {
      input = {permissions.allow = ["Read(//nix/store/**)"];};
      prev = {};
      new = {permissions.allow = ["Read(//nix/store/**)" "Read(//x/**)"];};
      expected = {permissions.allow = ["Read(//nix/store/**)" "Read(//x/**)"];};
    };
    nix-key-wins = {
      input = {model = "sonnet";};
      prev = {model = "opus";};
      new = {model = "opus";};
      expected = {model = "opus";};
    };
    nothing-managed = {
      input = {
        theme = "dark";
        permissions.allow = ["Bash(ls:*)"];
      };
      prev = {};
      new = {};
      expected = {
        theme = "dark";
        permissions.allow = ["Bash(ls:*)"];
      };
    };
  };

  json = builtins.toJSON;
  check = name: c: ''
    echo ${lib.escapeShellArg (json c.input)} > in.json
    echo ${lib.escapeShellArg (json c.prev)} > prev.json
    echo ${lib.escapeShellArg (json c.new)} > new.json
    got=$(jq -S . <(jq --slurpfile prev prev.json --slurpfile new new.json -f ${../modules/settings-merge.jq} in.json))
    want=$(echo ${lib.escapeShellArg (json c.expected)} | jq -S .)
    if [ "$got" = "$want" ]; then
      echo "ok   ${name}"
    else
      echo "FAIL ${name}"; echo "  got:  $(jq -c . <<<"$got")"; echo "  want: $(jq -c . <<<"$want")"; failed=1
    fi
  '';
in
  runCommand "settings-merge-test" {nativeBuildInputs = [jq];} ''
    failed=0
    ${lib.concatStrings (lib.mapAttrsToList check cases)}
    [ "$failed" = 0 ] && touch $out
  ''
