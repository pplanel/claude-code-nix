#!/usr/bin/env bash
# Regression tests for the sandbox profiles. macOS only, run by hand after
# any change to the .sb files or to how default.nix composes them:
#
#   modules/sandbox/tests/run.sh
#
# Not part of `nix flake check`: nix builds already run inside a sandbox, and
# sandbox-exec can't nest. The tests run as you, so Seatbelt is the only
# barrier being tested (the agent's own user adds a second one in real use).
#
# It builds the module's wrappers for two test agents (tests/agents.nix),
# composes their session profiles the way wrapper.sh does, and runs:
#   - file cases: workspace, grants, credentials, home scopes, both modes
#   - network cases: tests/net-probe.py outside the sandbox (what's reachable
#     on this machine) and inside (what the profile lets through)
# Exit status: the number of wrong results.
set -u

here="$(cd "$(dirname "$0")" && pwd -P)"
repo="$(cd "$here/../../.." && pwd -P)"
wrappers="$(nix build --impure --no-link --print-out-paths \
  -f "$here/agents.nix" --argstr flake "$repo")" || exit 1
python="$wrappers/bin/python3"

# A scratch tree, under /private/tmp: Seatbelt matches resolved paths.
work="$(mktemp -d /private/tmp/claude-sandbox-tests.XXXXXX)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work"/{target,home/.claude,tmp,granted,ungranted}
git -C "$work/target" init -q
echo state >"$work/home/.claude/state"
echo other >"$work/home/other"
echo granted >"$work/granted/file"
echo ungranted >"$work/ungranted/file"
cp "$here/net-probe.py" "$work/target/"

# The session profile, as wrapper.sh composes it: head, grants, tail.
compose() { # <agent command> <granted path>...
  local w="$wrappers/bin/$1"
  shift
  cat "$(grep -o '/nix/store/[^ ]*-head.sb' "$w")"
  local g
  for g in "$@"; do printf '(allow file-read* (subpath-firmlink "%s"))\n' "$g"; done
  cat "$(grep -o '/nix/store/[^ ]*-tail.sb' "$w")"
}
compose claude-clone "$work/granted" >"$work/clone.sb"
compose claude-clone "$HOME" >"$work/clone-home.sb"
compose claude-inplace >"$work/inplace.sb"

PORT=18901
sandboxed() { # <profile> <shell command>
  sandbox-exec -f "$1" -D TARGET_DIR="$work/target" -D AGENT_HOME="$work/home" \
    -D TMP_DIR="$work/tmp" -D PROXY_PORT="$PORT" /bin/sh -c "cd '$work/target' && $2"
}

ok=0 wrong=0 skipped=0
report() { # <result: ok|WRONG|skip> <name> <want> <got> [detail]
  case "$1" in ok) ok=$((ok + 1)) ;; WRONG) wrong=$((wrong + 1)) ;; *) skipped=$((skipped + 1)) ;; esac
  printf '%-5s %-46s want %-5s got %-5s %s\n' "$1" "$2" "$3" "$4" "${5:-}"
}
check() { # <name> <want PASS|BLOCK> <profile> <shell command>
  local got=BLOCK
  sandboxed "$3" "$4" >/dev/null 2>&1 && got=PASS
  if [[ "$got" == "$2" ]]; then report ok "$1" "$2" "$got"; else report WRONG "$1" "$2" "$got"; fi
}

echo "== files: clone mode, one grant ($work/granted)"
check "sh runs" PASS "$work/clone.sb" 'echo ok'
check "claude --version" PASS "$work/clone.sb" 'claude --version'
check "write the workspace" PASS "$work/clone.sb" 'echo x > README.md'
check "write workspace .envrc (clone: allowed)" PASS "$work/clone.sb" 'echo x > .envrc'
check "write workspace .git (clone: allowed)" PASS "$work/clone.sb" 'echo x > .git/probe'
check "write outside the workspace" BLOCK "$work/clone.sb" "echo x > '$work/ungranted/new'"
check "read the granted path" PASS "$work/clone.sb" "cat '$work/granted/file'"
check "read an ungranted path" BLOCK "$work/clone.sb" "cat '$work/ungranted/file'"
check "read the agent's home (full)" PASS "$work/clone.sb" "cat '$work/home/other'"

echo "== files: clone mode, the whole owner home granted"
check "list the owner's home" PASS "$work/clone-home.sb" "ls '$HOME'"
for dot in .ssh .aws .gnupg .config; do
  if [[ -d "$HOME/$dot" ]]; then
    check "list ~/$dot (credentials win)" BLOCK "$work/clone-home.sb" "ls '$HOME/$dot'"
  else
    report skip "list ~/$dot" BLOCK - "(no ~/$dot here)"
  fi
done

echo "== files: in-place mode, homeReadScope state-only"
check "write the workspace" PASS "$work/inplace.sb" 'echo x > README.md'
check "write .envrc" BLOCK "$work/inplace.sb" 'echo x > .envrc.new && mv .envrc.new .envrc'
check "write a nested .mcp.json" BLOCK "$work/inplace.sb" 'mkdir -p sub && echo x > sub/.mcp.json'
check "write .git/hooks" BLOCK "$work/inplace.sb" 'echo x > .git/hooks/pre-commit'
check "mv .git away" BLOCK "$work/inplace.sb" 'mv .git .gitx'
check "write .claude" BLOCK "$work/inplace.sb" 'mkdir -p .claude/skills && echo x > .claude/skills/x.md'
check "read .git (git status)" PASS "$work/inplace.sb" 'git status --short'
check "read the agent's .claude" PASS "$work/inplace.sb" "cat '$work/home/.claude/state'"
check "read the rest of its home" BLOCK "$work/inplace.sb" "cat '$work/home/other'"

echo "== network: reachable outside, then inside the clone profile"
gateway="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')"
peer="-"
command -v tailscale >/dev/null &&
  peer="$(tailscale status 2>/dev/null | awk '$1 ~ /^100\./ && !/offline/ {print $1}' | sed -n 2p)"
socks=()
for s in /var/run/nix-daemon.socket /var/run/tailscaled.socket /var/run/determinate-nixd.socket \
  /var/run/mDNSResponder /var/run/portmap.socket "/private/tmp/tmux-$(id -u)/default"; do
  [[ -S "$s" ]] && socks+=("$s")
done
probe=(net-probe.py "$PORT" "${gateway:-127.0.0.2}" "${peer:--}" "${socks[@]}")

# Listeners on the proxy port and the one next to it, so "another
# localhost port" has something on the other end. nc exits after one
# connection, so they start again for the inside run.
listeners() {
  /usr/bin/nc -l 127.0.0.1 "$PORT" >/dev/null 2>&1 &
  /usr/bin/nc -l 127.0.0.1 "$((PORT + 1))" >/dev/null 2>&1 &
  sleep 0.5
}
listeners
(cd "$work/target" && "$python" -I "${probe[@]}") >"$work/outside"
kill %1 %2 2>/dev/null
listeners
sandboxed "$work/clone.sb" "$python -I ${probe[*]}" >"$work/inside"
kill %1 %2 2>/dev/null

# A refused connection means the network path exists: outside, the target
# counts as reachable; inside, the profile let it through (PASS). Only a
# denial (PermissionError) counts as BLOCK inside.
while IFS=$'\t' read -r name out why; do
  in="$(awk -F'\t' -v n="$name" '$1 == n {print $2}' "$work/inside")"
  in_why="$(awk -F'\t' -v n="$name" '$1 == n {print $3}' "$work/inside")"
  [[ "$in_why" == *ConnectionRefused* ]] && in=PASS
  want=BLOCK
  [[ "$name" == proxy* ]] && want=PASS
  if [[ "$out" == BLOCK && "$why" != *ConnectionRefused* ]]; then
    report skip "$name" "$want" "$in" "(unreachable here even outside)"
  elif [[ "$in" == "$want" ]]; then
    report ok "$name" "$want" "$in"
  else
    report WRONG "$name" "$want" "$in"
  fi
done <"$work/outside"

echo "== $ok ok, $wrong wrong, $skipped skipped"
exit "$wrong"
