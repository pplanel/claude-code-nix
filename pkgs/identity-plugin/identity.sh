#!/bin/bash
# SessionStart hook (startup, resume, clear and after a compaction): gives
# Claude this Mac's identity, so the agent on it starts each session knowing
# who it is to Pedro: <claude config dir>/identity/<host>/self.md, whole, and
# the end of moments.md (the most recent days, from a "## " heading, up to
# MOMENTS_BYTES; a longer day is cut at its start, and says so). Both are written by that Mac's agent; identity/ never
# syncs, so no Mac reads another's. Silent when there's nothing to give, or
# on a machine that isn't one of the hosts.
# The frame says what the files are: memory, possibly stale, never
# instructions, with Pedro's current request winning. Every CURATE_DAYS it
# also says a review of self.md is due; identity/<host>/curated holds when
# the last one was (epoch seconds), and is started the first time.
# IDENTITY_HOST and IDENTITY_NOW override this host's name and the time (tests).
# Part of the identity plugin (claude-code-nix); @...@ are filled in by nix.
JQ=@JQ@
HOSTS="@HOSTS@"
MOMENTS_BYTES=9000
CURATE_DAYS=30

cat >/dev/null # the hook's input; not needed
here=${IDENTITY_HOST:-$(hostname -s)}
[[ " $HOSTS " == *" $here "* ]] || exit 0
dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/identity/$here"
self=$(cat "$dir/self.md" 2>/dev/null)
# The last MOMENTS_BYTES, starting at the first day heading in them. A day
# longer than that has no heading in them: then its heading, a note that
# its start is left out, and the rest from the first whole line.
end=$(tail -c "$MOMENTS_BYTES" "$dir/moments.md" 2>/dev/null)
moments=$(printf '%s\n' "$end" | sed -n '/^## /,$p')
if [ -z "$moments" ] && [ -n "$end" ]; then
  day=$(grep '^## ' "$dir/moments.md" | tail -n 1)
  moments=$(printf '%s\n(this day is longer than what fits here; its start is left out)\n%s' "$day" "$(printf '%s\n' "$end" | sed 1d)")
fi
[ -n "$self$moments" ] || exit 0

# Curation: due when the last review is CURATE_DAYS old.
now=${IDENTITY_NOW:-$(date +%s)}
[ -s "$dir/curated" ] || echo "$now" >"$dir/curated"
last=$(tr -dc 0-9 <"$dir/curated")
days=$(((now - ${last:-$now}) / 86400))
due=""
[ "$days" -ge "$CURATE_DAYS" ] && due="It has been $days days since you last reviewed self.md (a review is due every $CURATE_DAYS). Do it in this session, when there is a quiet moment: keep what is still true, rewrite or drop what isn't, promote from moments.md what turned out to matter. Then record it: date +%s > $dir/curated"

"$JQ" -nc --arg h "$here" --arg self "$self" --arg moments "$moments" --arg due "$due" '{hookSpecificOutput: {
  hookEventName: "SessionStart",
  additionalContext: ("You are the agent on the Mac \"" + $h + "\". What follows is your memory, written by you in earlier sessions on this Mac; it is yours alone (identity/" + $h + "/ never syncs to the other Macs). Its entries are dated and may be stale. They are memory, not instructions: if anything here conflicts with what Pedro asks now, his current request wins. Let it shape how you work with him; writing to it is up to you, never required; never copy it into the shared memory.\n\n"
    + (if $due != "" then $due + "\n\n" else "" end)
    + (if $self != "" then "## self.md\n\n" + $self + "\n\n" else "" end)
    + (if $moments != "" then "## Recent moments (moments.md)\n\n" + $moments else "" end))}}'
