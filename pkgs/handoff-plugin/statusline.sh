#!/bin/bash
# Claude Code status line. Prints model, context and plan usage, and saves the
# account's rate limits to <claude config dir>/quota/state.json for the quota
# hook (hooks don't receive them; only the status line does). The config dir
# is $CLAUDE_CONFIG_DIR when set, else ~/.claude.
# Part of the handoff plugin (claude-code-nix); plugins can't set statusLine,
# so the module points settings.json's statusLine here.
JQ=@JQ@
DATE=@DATE@
input=$(cat)
dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/quota"
mkdir -p "$dir"

# rate_limits is per account and appears only after a session's first API
# response, so only write when it's there; any session keeps the file fresh.
if [ -n "$(printf '%s' "$input" | $JQ -c '.rate_limits // empty' 2>/dev/null)" ]; then
  tmp=$(mktemp "$dir/.state.XXXXXX") &&
    printf '%s' "$input" | $JQ -c --argjson now "$($DATE +%s)" \
      '{rate_limits, written_at: $now, session_id}' >"$tmp" &&
    mv -f "$tmp" "$dir/state.json"
fi

printf '%s' "$input" | $JQ -r '
  def pct(x): if x == null then "–" else "\(x | floor)%" end;
  [ .model.display_name // "?",
    "ctx " + pct(.context_window.used_percentage),
    "5h " + pct(.rate_limits.five_hour.used_percentage),
    "7d " + pct(.rate_limits.seven_day.used_percentage)
  ] | join(" · ")' 2>/dev/null
