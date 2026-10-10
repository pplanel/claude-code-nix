#!/bin/bash
# Move a Claude Code session from this Mac to another and resume it there.
#
#   claude-handoff --session <id> --transcript <path> --cwd <dir> [--target <host>] [--dry-run]
#
# 1. Commits the changes to tracked files in <dir>'s repo (WIP, hooks skipped:
#    broken work is allowed) on handoff/<repo>-<date> and pushes it. Untracked
#    files are listed, never pushed: they may be scratch files or secrets.
# 2. On the target: clones the repo if missing, checks out the branch.
# 3. Copies the transcript (paths rewritten to the target's layout), its
#    subagent folder and the project's memory/ into the target's Claude config.
# 4. Opens tmux window handoff-<repo> in the target's `work` session running
#    `<claude> --resume <id>`, then tells it to carry on.
# 5. Marks the session handed off, so the quota hook stops asking.
# Run by the `handoff` skill. Part of the handoff plugin (claude-code-nix),
# which puts it on Claude's PATH; @...@ are filled in by nix.
set -euo pipefail

TMUX_SESSION=work
# Single quotes: $USER and $PATH expand on the target.
REMOTE_PATH='export PATH=/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH'

# This Mac's default target, used without --target.
case $(hostname -s) in
@TARGETS@
  *) TARGET="" ;;
esac

# Where each Mac keeps the user's sources and Claude config, and how it starts
# Claude: "<src dir> <claude config dir> <claude command>".
layout() {
  case $1 in
@LAYOUT@
    *) echo "unknown host $1" >&2; return 1 ;;
  esac
}
# Claude names a project's folder after its path, with / and . turned into -.
project_key() { printf '%s' "$1" | sed 's#[/.]#-#g'; }

session="" transcript="" cwd="" dry=0
while [ $# -gt 0 ]; do
  case $1 in
    --session) session=$2; shift 2 ;;
    --transcript) transcript=$2; shift 2 ;;
    --cwd) cwd=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) echo "usage: claude-handoff --session ID --transcript PATH --cwd DIR [--target HOST] [--dry-run]" >&2; exit 2 ;;
  esac
done
[ -n "$session" ] && [ -n "$transcript" ] && [ -n "$cwd" ] || { echo "missing --session, --transcript or --cwd" >&2; exit 2; }
[ -f "$transcript" ] || { echo "no transcript at $transcript" >&2; exit 1; }
[ "$(basename "$transcript")" = "$session.jsonl" ] || { echo "transcript doesn't belong to session $session" >&2; exit 1; }
here=$(hostname -s)
[ -n "$TARGET" ] || { echo "no --target, and $here has no default target" >&2; exit 2; }
[ "$here" != "$TARGET" ] || { echo "already on $TARGET" >&2; exit 1; }

read -r src_here _ _ < <(layout "$here")
read -r src_there claude_there claude_cmd < <(layout "$TARGET")
# A path under this Mac's sources maps to the same place under the target's.
there() { case $1 in "$src_here" | "$src_here"/*) printf '%s' "$src_there${1#"$src_here"}" ;; *) printf '%s' "$1" ;; esac; }

project_dir=$(dirname "$transcript")
cwd_there=$(there "$cwd")
project_there="$claude_there/projects/$(project_key "$cwd_there")"

step() { printf '==> %s\n' "$*"; }
run() { if [ "$dry" = 1 ]; then printf '    (dry run) %s\n' "$*"; else "$@"; fi; }
remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" "$REMOTE_PATH; $1"; }

# 1. Freeze the work.
branch="" repo="" repo_there="" name="" url="" untracked=""
if repo=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null); then
  name=$(basename "$repo")
  repo_there=$(there "$repo")
  url=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
  [[ $url == *github.com[:/]@OWNER@/* ]] ||
    { echo "$repo's origin ($url) isn't an @OWNER@ repo; $TARGET can't fetch it" >&2; exit 1; }
  branch="handoff/$name-$(date +%Y%m%d-%H%M)"
  step "commit and push $repo as $branch"
  run git -C "$repo" switch -q -c "$branch"
  run git -C "$repo" add -u
  untracked=$(git -C "$repo" ls-files --others --exclude-standard)
  if [ "$dry" = 1 ] || ! git -C "$repo" diff --cached --quiet; then
    run git -C "$repo" commit -q --no-verify -m "wip: handoff to $TARGET"
  fi
  run git -C "$repo" push -q --no-verify -u origin "$branch"
else
  step "$cwd isn't a git repo; moving the session only ($cwd_there must exist on $TARGET)"
fi

# 2. The same checkout on the target, in its layout.
if [ -n "$branch" ]; then
  step "check out $branch in $repo_there on $TARGET"
  run remote "set -e
    if [ ! -d '$repo_there/.git' ]; then mkdir -p \"\$(dirname '$repo_there')\"; git clone -q '$url' '$repo_there'; fi
    cd '$repo_there'
    if [ -n \"\$(git status --porcelain --untracked-files=no)\" ]; then echo '$repo_there has uncommitted changes on $TARGET; not switching' >&2; exit 1; fi
    git fetch -q origin '$branch'
    git switch -q '$branch'"
fi
run remote "test -d '$cwd_there'" || { echo "$cwd_there doesn't exist on $TARGET" >&2; exit 1; }

# 3. The conversation and the project's memory, in the target's Claude config.
step "copy session $session and memory to $TARGET:$project_there"
run remote "mkdir -p '$project_there'"
if [ "$cwd" = "$cwd_there" ]; then
  run rsync -a "$transcript" "$TARGET:$project_there/$session.jsonl"
else
  # Paths in the conversation point at this Mac's layout; rewrite them.
  from=${repo:-$cwd} to=${repo_there:-$cwd_there}
  if [ "$dry" = 1 ]; then
    printf '    (dry run) copy %s with %s rewritten to %s\n' "$transcript" "$from" "$to"
  else
    sed "s#$from#$to#g" "$transcript" | remote "cat > '$project_there/$session.jsonl'"
  fi
fi
if [ -d "$project_dir/$session" ]; then
  run rsync -a "$project_dir/$session/" "$TARGET:$project_there/$session/"
fi
if [ -d "$project_dir/memory" ]; then
  run rsync -a --update "$project_dir/memory/" "$TARGET:$project_there/memory/"
fi

# 4. Resume it in its own tmux window.
window="handoff-${name:-$(basename "$cwd")}"
step "resume it on $TARGET in tmux window $TMUX_SESSION:$window ($claude_cmd)"
start="zsh -lc '$claude_cmd --resume $session; exec zsh -l'"
run remote "tmux has-session -t $TMUX_SESSION 2>/dev/null || tmux new-session -d -s $TMUX_SESSION
  tmux new-window -d -t $TMUX_SESSION -n '$window' -c '$cwd_there' \"$start\""

note="Resumed on $TARGET after a quota handoff from $here."
[ -n "$branch" ] && note="$note Your work is on branch $branch, pushed and checked out at $repo_there."
[ "$cwd" = "$cwd_there" ] || note="$note Paths differ here: $src_here on $here is $src_there on $TARGET."
if [ -n "$untracked" ]; then
  count=$(printf '%s\n' "$untracked" | wc -l | tr -d ' ')
  some=$(printf '%s\n' "$untracked" | head -10 | tr '\n' ' ')
  note="$note $count untracked files on $here were not copied: $some$([ "$count" -gt 10 ] && echo "(+$((count - 10)) more)")."
fi
note="$note Continue autonomously from where the conversation stopped: commit and push after each step, open or update a draft PR when it makes sense, never merge."

if [ "$dry" = 1 ]; then
  printf '    (dry run) wait for its prompt, then send: %s\n' "$note"
else
  ready=0
  for _ in $(seq 1 30); do
    if remote "tmux capture-pane -p -t '$TMUX_SESSION:$window'" 2>/dev/null | grep -q '❯'; then ready=1; break; fi
    sleep 2
  done
  if [ "$ready" = 1 ]; then
    printf '%s' "$note" | remote "tmux load-buffer -b handoff - && tmux paste-buffer -p -d -b handoff -t '$TMUX_SESSION:$window' && sleep 1 && tmux send-keys -t '$TMUX_SESSION:$window' Enter"
  else
    echo "warning: $TMUX_SESSION:$window didn't show a prompt within 60 s; the note wasn't sent" >&2
  fi
fi

# 5. Done here.
marks="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/quota/handed-off"
run mkdir -p "$marks"
run touch "$marks/$session"
step "handed off: continue in $TARGET's tmux window $TMUX_SESSION:$window${branch:+ (branch $branch)}"
[ -z "$untracked" ] || printf 'not pushed (untracked here):\n%s\n' "$untracked"
