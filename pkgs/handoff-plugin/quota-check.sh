#!/bin/bash
# UserPromptSubmit / PostToolBatch hook: tells Claude when the account's plan
# usage nears its limit, from the rate limits the status line saved
# (statusline.sh -> <claude config dir>/quota/state.json).
# `/handoff [host]` typed by the user: hands the skill the session details and
# the target (the named host, else this Mac's default target).
#   >= WARN_AT : one warning per session and limit window
#   >= HANDOFF_AT: "hand off now" after every prompt and tool batch, until
#                  <claude config dir>/quota/handed-off/<session> exists
# Silent when there's no fresh data. Never blocks anything (always exits 0).
# QUOTA_STATE overrides the state file and QUOTA_HOST this host's name (tests).
# Part of the handoff plugin (claude-code-nix); @...@ are filled in by nix.
JQ=@JQ@
DATE=@DATE@
WARN_AT=70
HANDOFF_AT=80
HOSTS="@HOSTS@"
MAX_AGE=900 # ignore a state file older than this (seconds)

dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/quota"
state="${QUOTA_STATE:-$dir/state.json}"
input=$(cat)

here=${QUOTA_HOST:-$(hostname -s)}
# Who takes over automatically from this Mac.
case $here in
@TARGETS@
  *) TARGET="" ;;
esac
[ -f "$dir/disabled" ] && exit 0

session=$(printf '%s' "$input" | $JQ -r '.session_id // empty')
transcript=$(printf '%s' "$input" | $JQ -r '.transcript_path // empty')
event=$(printf '%s' "$input" | $JQ -r '.hook_event_name // empty')
cwd=$(printf '%s' "$input" | $JQ -r '.cwd // empty')
prompt=$(printf '%s' "$input" | $JQ -r '.prompt // empty')
[ -n "$session" ] && [ -n "$event" ] || exit 0

say() {
  $JQ -n --arg event "$event" --arg text "$1" \
    '{hookSpecificOutput: {hookEventName: $event, additionalContext: $text}}'
}

# `/handoff [host]` typed by the user: give the skill the session it can't see
# itself, and where to go.
if [ "$event" = UserPromptSubmit ] && [[ $prompt == /handoff* ]]; then
  read -r _ asked _ <<<"$prompt"
  target=${asked:-$TARGET}
  if [ -z "$target" ] || [[ " $HOSTS " != *" $target "* ]] || [ "$target" = "$here" ]; then
    say "Handoff requested by the user, but \"$target\" isn't another Mac (choose from: ${HOSTS/$here/}). Tell the user; don't hand off."
    exit 0
  fi
  say "Handoff requested by the user. target=$target session_id=$session transcript=$transcript cwd=$cwd"
  exit 0
fi
[ -n "$TARGET" ] && [ "$here" != "$TARGET" ] || exit 0

[ -e "$dir/handed-off/$session" ] && exit 0
[ -f "$state" ] || exit 0

now=$($DATE +%s)
# The fullest window still in force: "<name> <percent> <resets_at>".
read -r window pct resets < <($JQ -r --argjson now "$now" --argjson max "$MAX_AGE" '
  select(($now - (.written_at // 0)) <= $max)
  | .rate_limits | to_entries
  | map(select(.key == "five_hour" or .key == "seven_day")
        | select(.value.used_percentage != null and (.value.resets_at // 0) > $now))
  | max_by(.value.used_percentage) // empty
  | "\(.key) \(.value.used_percentage | floor) \(.value.resets_at)"' "$state" 2>/dev/null)
[ -n "$window" ] || exit 0

case $window in
  five_hour) label="5-hour session limit" ;;
  seven_day) label="weekly limit" ;;
esac
when=$($DATE -d "@$resets" '+%a %H:%M')

if [ "$pct" -ge "$HANDOFF_AT" ]; then
  say "QUOTA HANDOFF NOW: this account's $label is at $pct% (resets $when). Stop the current work immediately and run the \`handoff\` skill to move this session to $TARGET: target=$TARGET session_id=$session transcript=$transcript cwd=$cwd. Don't start anything else first."
elif [ "$pct" -ge "$WARN_AT" ]; then
  mark="$dir/warned/$session-$window-$resets"
  [ -e "$mark" ] && exit 0
  mkdir -p "$dir/warned" && : >"$mark"
  say "Quota warning: this account's $label is at $pct% (resets $when). Keep steps small and commit often; at $HANDOFF_AT% this session hands off to $TARGET."
fi
exit 0
