# Builds the handoff plugin for three example hosts and checks its layout, the
# quota hook's answers and Claude Code's own plugin validation.
{
  lib,
  runCommand,
  callPackage,
  jq,
  git,
  rsync,
  python3,
  claude-code,
}: let
  pytest = python3.withPackages (ps: [ps.pytest ps.rich]);
  plugin = callPackage ../pkgs/handoff-plugin {
    githubOwner = "someone";
    hosts = {
      alpha = {
        src = "/Users/u/src/u";
        configDir = "/Users/u/src/u/.claude";
        command = "claude-personal";
        defaultTarget = "gamma";
      };
      beta = {
        src = "/Users/u/src";
        configDir = "/Users/u/.claude";
        command = "claude";
        defaultTarget = "gamma";
      };
      gamma = {
        src = "/Users/u/src";
        configDir = "/Users/u/.claude";
        command = "claude";
      };
    };
  };
in
  runCommand "handoff-plugin-test" {nativeBuildInputs = [jq git rsync pytest claude-code];} ''
    failed=0
    ok() { echo "ok   $1"; }
    fail() { echo "FAIL $1"; [ -n "''${2:-}" ] && echo "  $2"; failed=1; }
    p=${plugin}

    # Layout
    for f in .claude-plugin/plugin.json hooks/hooks.json skills/handoff/SKILL.md; do
      [ -f $p/$f ] && ok "has $f" || fail "has $f"
    done
    for f in bin/claude-handoff scripts/quota-check.sh scripts/statusline.sh; do
      [ -x $p/$f ] && ok "$f is executable" || fail "$f is executable"
    done
    [ "$(jq -r .name $p/.claude-plugin/plugin.json)" = handoff ] && ok "manifest name" || fail "manifest name"
    for ev in UserPromptSubmit PostToolBatch; do
      cmd=$(jq -r ".hooks.$ev[0].hooks[0].command" $p/hooks/hooks.json)
      [ -x "$cmd" ] && ok "$ev hook runs $cmd" || fail "$ev hook command" "$cmd"
    done
    grep -qF '"alpha": {"command": "claude-personal", "configDir": "/Users/u/src/u/.claude", "defaultTarget": "gamma", "extraRoutes": [], "src": "/Users/u/src/u"}' $p/bin/claude-handoff \
      || grep -qF '"alpha":{"command":"claude-personal","configDir":"/Users/u/src/u/.claude","defaultTarget":"gamma","extraRoutes":[],"src":"/Users/u/src/u"}' $p/bin/claude-handoff \
      && ok "hosts table for alpha" || fail "hosts table for alpha"
    grep -q 'or "someone"' $p/bin/claude-handoff && ok "github owner" || fail "github owner"
    head -1 $p/bin/claude-handoff | grep -q '^#!/nix/store/.*python3$' && ok "runs on nix's python" || fail "runs on nix's python"
    $p/bin/claude-handoff --help >/dev/null && ok "claude-handoff --help" || fail "claude-handoff --help"

    # claude-handoff end to end: its pytest suite against the built script.
    mkdir pytests && cp ${../pkgs/handoff-plugin/test_claude_handoff.py} pytests/test_claude_handoff.py
    if HANDOFF_SCRIPT=$p/bin/claude-handoff python3 -m pytest -q -p no:cacheprovider --rootdir pytests pytests > pytest.log 2>&1; then
      ok "claude-handoff tests ($(tail -1 pytest.log))"
    else
      fail "claude-handoff tests" "$(tail -30 pytest.log)"
    fi
    grep -q 'alpha, beta, gamma' $p/skills/handoff/SKILL.md && ok "skill names the hosts" || fail "skill names the hosts"

    # The quota hook, as host alpha (default target gamma) unless QUOTA_HOST says otherwise.
    export HOME=$TMPDIR CLAUDE_CONFIG_DIR=$TMPDIR/cfg
    mkdir -p $CLAUDE_CONFIG_DIR/quota
    hook() { # <host> <event> <prompt> -> additionalContext
      jq -nc --arg e "$2" --arg p "$3" '{session_id: "s1", transcript_path: "/t/s1.jsonl", hook_event_name: $e, cwd: "/w", prompt: $p}' |
        QUOTA_HOST=$1 QUOTA_STATE=$TMPDIR/state.json $p/scripts/quota-check.sh | jq -r '.hookSpecificOutput.additionalContext // empty'
    }
    expect() { # <name> <output> <substring>
      case $2 in *"$3"*) ok "$1" ;; *) fail "$1" "got: $2" ;; esac
    }
    state() { # <percent>
      jq -nc --argjson pct $1 --argjson now $(date +%s) \
        '{written_at: $now, rate_limits: {five_hour: {used_percentage: $pct, resets_at: ($now + 3600)}}}' > $TMPDIR/state.json
    }
    expect "/handoff beta from alpha" "$(hook alpha UserPromptSubmit '/handoff beta')" "target=beta session_id=s1"
    expect "/handoff alone uses the default" "$(hook alpha UserPromptSubmit '/handoff')" "target=gamma"
    expect "/handoff to itself refused" "$(hook alpha UserPromptSubmit '/handoff alpha')" "isn't another Mac"
    expect "/handoff to unknown refused" "$(hook alpha UserPromptSubmit '/handoff zeta')" "isn't another Mac"
    state 85
    expect "85% hands off" "$(hook alpha PostToolBatch "")" "QUOTA HANDOFF NOW"
    expect "85% names the target" "$(hook alpha PostToolBatch "")" "target=gamma"
    res=$(hook gamma PostToolBatch ""); [ -z "$res" ] && ok "no default target: silent" || fail "no default target: silent" "got: $res"
    state 72
    expect "72% warns" "$(hook beta PostToolBatch "")" "Quota warning"
    res=$(hook beta PostToolBatch ""); [ -z "$res" ] && ok "72% warns once" || fail "72% warns once" "got: $res"
    state 40
    res=$(hook alpha PostToolBatch ""); [ -z "$res" ] && ok "40%: silent" || fail "40%: silent" "got: $res"

    # Claude Code's own check of the plugin.
    if res=$(claude plugin validate $p 2>&1); then ok "claude plugin validate"; else fail "claude plugin validate" "$res"; fi
    echo "$res" | sed 's/^/  validate: /'

    [ "$failed" = 0 ] && touch $out
  ''
