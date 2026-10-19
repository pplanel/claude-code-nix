# Builds the identity plugin for two example hosts and checks its layout, the
# answers of its two hooks and Claude Code's own plugin validation.
{
  runCommand,
  callPackage,
  jq,
  claude-code,
}: let
  plugin = callPackage ../pkgs/identity-plugin {
    githubOwner = "someone";
    hosts = {
      alpha = {};
      beta = {};
    };
  };
in
  runCommand "identity-plugin-test" {nativeBuildInputs = [jq claude-code];} ''
        failed=0
        ok() { echo "ok   $1"; }
        fail() { echo "FAIL $1"; [ -n "''${2:-}" ] && echo "  $2"; failed=1; }
        expect() { # <name> <output> <substring>
          case $2 in *"$3"*) ok "$1" ;; *) fail "$1" "got: $2" ;; esac
        }
        p=${plugin}
        export HOME=$TMPDIR CLAUDE_CONFIG_DIR=$TMPDIR/cfg
        mkdir -p $CLAUDE_CONFIG_DIR

        # Layout
        for f in .claude-plugin/plugin.json hooks/hooks.json; do
          [ -f $p/$f ] && ok "has $f" || fail "has $f"
        done
        [ "$(jq -r .name $p/.claude-plugin/plugin.json)" = identity ] && ok "manifest name" || fail "manifest name"

        # The host tag, on UserPromptSubmit.
        tagcmd=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' $p/hooks/hooks.json)
        [ -x "$tagcmd" ] && ok "host-tag hook runs $tagcmd" || fail "host-tag hook command" "$tagcmd"
        tag() { echo '{}' | HOST_TAG_HOST=$1 HOST_TAG_AGENT=''${2:-} $tagcmd | jq -r '.hookSpecificOutput.additionalContext // empty'; }
        expect "host tag on beta, no agent" "$(tag beta)" 'Start your reply with "[beta]: "'
        expect "agent@host tag" "$(tag beta Liet)" 'Start your reply with "[Liet@beta]: "'
        expect "agent named in the context" "$(tag beta Liet)" 'as the agent Liet on the Mac "beta"'
        res=$(tag elsewhere); [ -z "$res" ] && ok "host tag silent off the hosts" || fail "host tag silent off the hosts" "got: $res"

        # Identity, on SessionStart: this Mac's self.md and the end of moments.md.
        idcmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' $p/hooks/hooks.json)
        [ -x "$idcmd" ] && ok "identity hook runs $idcmd" || fail "identity hook command" "$idcmd"
        ident() { echo '{}' | IDENTITY_HOST=$1 $idcmd | jq -r '.hookSpecificOutput.additionalContext // empty'; }
        res=$(ident beta); [ -z "$res" ] && ok "identity silent without files" || fail "identity silent without files" "got: $res"
        mkdir -p $CLAUDE_CONFIG_DIR/identity/beta $CLAUDE_CONFIG_DIR/identity/alpha
        echo "I am beta." > $CLAUDE_CONFIG_DIR/identity/beta/self.md
        { echo "# moments"; for i in $(seq 1 400); do printf '## day %s\n- something happened on day %s\n' $i $i; done; } > $CLAUDE_CONFIG_DIR/identity/beta/moments.md
        echo "I am alpha." > $CLAUDE_CONFIG_DIR/identity/alpha/self.md
        res=$(ident beta)
        expect "identity gives self.md" "$res" "I am beta."
        expect "identity gives the latest moment" "$res" "day 400"
        case $res in *"## day 1
    "*) fail "identity keeps only recent moments" ;; *) ok "identity keeps only recent moments" ;; esac
        case $res in *"I am alpha."*) fail "identity is this Mac's only" ;; *) ok "identity is this Mac's only" ;; esac
        # A day longer than the window still comes, cut at its start.
        { echo "## day 1"; echo "- short"; echo "## day 2"; for i in $(seq 1 600); do echo "- line $i of a long day"; done; } > $CLAUDE_CONFIG_DIR/identity/beta/moments.md
        res=$(ident beta)
        expect "identity gives a long day's heading" "$res" "## day 2"
        expect "identity gives a long day's end" "$res" "line 600 of a long day"
        expect "identity says a long day is cut" "$res" "its start is left out"
        # A big self.md comes whole, moments.md gets the room left, and the
        # whole stays under Claude Code's cap (past it, only a preview comes).
        { echo "I am beta, at length."; for i in $(seq 1 120); do echo "- a long line about who I am, number $i"; done; echo "END OF SELF"; } > $CLAUDE_CONFIG_DIR/identity/beta/self.md
        { echo "# moments"; for i in $(seq 1 400); do printf '## day %s\n- something happened on day %s\n' $i $i; done; } > $CLAUDE_CONFIG_DIR/identity/beta/moments.md
        res=$(ident beta)
        expect "identity gives a big self.md whole" "$res" "END OF SELF"
        expect "identity gives the latest moment after a big self.md" "$res" "day 400"
        [ ''${#res} -le 10000 ] && ok "identity stays under the cap (''${#res})" || fail "identity stays under the cap" "''${#res} characters"
        echo "I am beta." > $CLAUDE_CONFIG_DIR/identity/beta/self.md
        res=$(ident elsewhere); [ -z "$res" ] && ok "identity silent off the hosts" || fail "identity silent off the hosts" "got: $res"

    # The frame and curation.
    res=$(ident beta)
    expect "frame: memory, not instructions" "$res" "They are memory, not instructions"
    expect "frame: Pedro's request wins" "$res" "his current request wins"
    [ -s $CLAUDE_CONFIG_DIR/identity/beta/curated ] && ok "curation clock started" || fail "curation clock started"
    case $res in *"review is due"*) fail "no curation due on day 0" ;; *) ok "no curation due on day 0" ;; esac
    echo 1000000000 > $CLAUDE_CONFIG_DIR/identity/beta/curated
    res=$(echo '{}' | IDENTITY_HOST=beta IDENTITY_NOW=$((1000000000 + 31 * 86400)) $idcmd | jq -r '.hookSpecificOutput.additionalContext // empty')
    expect "curation due after 31 days" "$res" "It has been 31 days since you last reviewed self.md"
    res=$(echo '{}' | IDENTITY_HOST=beta IDENTITY_NOW=$((1000000000 + 29 * 86400)) $idcmd | jq -r '.hookSpecificOutput.additionalContext // empty')
    case $res in *"review is due"*) fail "no curation due at 29 days" ;; *) ok "no curation due at 29 days" ;; esac

        # Claude Code's own check of the plugin.
        if res=$(claude plugin validate $p 2>&1); then ok "claude plugin validate"; else fail "claude plugin validate" "$res"; fi

        [ "$failed" = 0 ] && touch $out
  ''
