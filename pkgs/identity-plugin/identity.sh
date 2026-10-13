#!/bin/bash
# SessionStart hook (startup, resume, clear and after a compaction): gives
# Claude this Mac's identity, so the agent on it starts each session knowing
# who it is to Pedro: <claude config dir>/identity/<host>/self.md, whole, and
# the end of moments.md (the most recent days, from a "## " heading, up to
# MOMENTS_BYTES). Both are written by that Mac's agent; identity/ never
# syncs, so no Mac reads another's. Silent when there's nothing to give, or
# on a machine that isn't one of the hosts.
# IDENTITY_HOST overrides this host's name (tests).
# Part of the identity plugin (claude-code-nix); @...@ are filled in by nix.
JQ=@JQ@
HOSTS="@HOSTS@"
MOMENTS_BYTES=6000

cat >/dev/null # the hook's input; not needed
here=${IDENTITY_HOST:-$(hostname -s)}
[[ " $HOSTS " == *" $here "* ]] || exit 0
dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/identity/$here"
self=$(cat "$dir/self.md" 2>/dev/null)
# The last MOMENTS_BYTES, starting at the first day heading in them.
moments=$(tail -c "$MOMENTS_BYTES" "$dir/moments.md" 2>/dev/null | sed -n '/^## /,$p')
[ -n "$self$moments" ] || exit 0

"$JQ" -nc --arg h "$here" --arg self "$self" --arg moments "$moments" '{hookSpecificOutput: {
  hookEventName: "SessionStart",
  additionalContext: ("You are the agent on the Mac \"" + $h + "\". This is your identity, written by you in earlier sessions; it is yours alone (identity/" + $h + "/ never syncs to the other Macs). Let it shape how you work with Pedro; never copy it into the shared memory.\n\n"
    + (if $self != "" then "## self.md\n\n" + $self + "\n\n" else "" end)
    + (if $moments != "" then "## Recent moments (moments.md)\n\n" + $moments else "" end))}}'
