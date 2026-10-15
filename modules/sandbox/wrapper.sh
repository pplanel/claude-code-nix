# claude-<name>: runs Claude Code as the agent's own macOS user, inside the
# agent's Seatbelt profile, online only through the agent's proxy.
#
# default.nix puts a preamble above this file (writeShellApplication adds
# `set -euo pipefail`) that defines:
#   CLI_NAME AGENT_NAME AGENT_USER AGENT_HOME PROXY_PORT CLAUDE_BIN
#   WORKSPACE_MODE         clone | in-place
#   AUTH_KIND              api-key | oauth-token
#   ALLOW_RUNTIME_GRANTS   1 | 0
#   PROFILE_HEAD           claude-sandbox.sb (+ in-place.sb in in-place mode)
#   PROFILE_TAIL           sensitive.sb + the agent's home read
#   FIXED_READ_PATHS       array, `read.paths`
#   AGENT_ENV              array, the agent's whole environment (env -i)
#   resolve_key()          sets RESOLVED_API_KEY, per `auth.strategy`
#
# Usage: claude-<name> [--read <path>]... [claude arguments]
# See DESIGN.md for why each step is here.

die() {
  echo "$CLI_NAME: $*" >&2
  exit 1
}
note() { echo "[$CLI_NAME] $*" >&2; }

# ---------------------------------------------------------------- arguments
# `--read <path>` / `--read=<path>` (repeatable) grants read access to one of
# the owner's paths for this session. Everything else goes to claude.
READ_PATHS=("${FIXED_READ_PATHS[@]}")
CLAUDE_ARGS=()
RUNTIME_GRANTS=0
while (($#)); do
  case "$1" in
  --read)
    (($# >= 2)) || die "--read needs a path"
    READ_PATHS+=("$2")
    RUNTIME_GRANTS=1
    shift 2
    ;;
  --read=*)
    READ_PATHS+=("${1#--read=}")
    RUNTIME_GRANTS=1
    shift
    ;;
  *)
    CLAUDE_ARGS+=("$1")
    shift
    ;;
  esac
done
if ((RUNTIME_GRANTS)) && ((!ALLOW_RUNTIME_GRANTS)); then
  die "--read is turned off for this agent (read.allowRuntimeGrants = false)"
fi

# ---------------------------------------------------------------- helpers

# Writes stdin to a file the agent owns, mode 0600. Used for the session
# profile, the API key and bundles: the agent's session tmp is 0700 and the
# owner can't write there directly.
as_agent_write() {
  sudo -u "$AGENT_USER" /usr/bin/env /bin/sh -c 'umask 077 && cat > "$1"' sh "$1"
}

# Whether the agent's user can enter a directory (search permission).
agent_can_enter() {
  sudo -u "$AGENT_USER" /usr/bin/test -x "$1"
}

# Runs a command as the agent, inside the session profile, from directory $1.
# Every command run on the agent's files goes through here, git included: a
# hook or core.fsmonitor the agent planted in its clone must not run outside
# Seatbelt.
run_sandboxed() {
  local dir="$1"
  shift
  # Claude Code ignores TMPDIR for its own files (/tmp/claude-<uid>, outside
  # the profile) and takes CLAUDE_CODE_TMPDIR instead (tested).
  sudo -u "$AGENT_USER" /usr/bin/env -i "${AGENT_ENV[@]}" \
    TMPDIR="$SESSION_TMP" CLAUDE_CODE_TMPDIR="$SESSION_TMP" \
    /usr/bin/sandbox-exec -f "$SESSION_TMP/profile.sb" \
    -D TARGET_DIR="$WORK_TREE" \
    -D AGENT_HOME="$AGENT_HOME" \
    -D TMP_DIR="$SESSION_TMP" \
    -D PROXY_PORT="$PROXY_PORT" \
    /bin/sh -c 'cd "$1" && shift && exec "$@"' sh "$dir" "$@"
}

# ---------------------------------------------------------------- ACLs
# The owner's home is 0750, so the agent's user can't reach anything in it.
# In-place mode and read grants open single paths with ACLs, recorded in a
# lock file (one line per ACL: rule, -R or -, path) so they are removed on
# exit, or by the next run if this one is killed.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-sandbox"
LOCK_DIR="$STATE_DIR/locks"
mkdir -p "$LOCK_DIR"
chmod 700 "$STATE_DIR" "$LOCK_DIR"
LOCK_FILE="$LOCK_DIR/$AGENT_NAME-$$.acl"

remove_acls() {
  local rule rec path
  while IFS=$'\t' read -r rule rec path; do
    if [[ "$rec" == "-R" ]]; then
      /bin/chmod -R -a "$rule" "$path" 2>/dev/null || true
    else
      /bin/chmod -a "$rule" "$path" 2>/dev/null || true
    fi
  done <"$1"
}

# Locks left by sessions that died without cleaning up.
LIVE_ACL_SESSIONS=0
for lock in "$LOCK_DIR/$AGENT_NAME"-*.acl; do
  [[ -e "$lock" ]] || continue
  pid="${lock##*-}"
  pid="${pid%.acl}"
  if kill -0 "$pid" 2>/dev/null; then
    LIVE_ACL_SESSIONS=1
  else
    note "removing ACLs left by session $pid"
    remove_acls "$lock"
    rm -f "$lock"
  fi
done

# Adds an ACL entry and records it. $1 rule, $2 -R or -, $3 path.
acl_add() {
  if [[ "$2" == "-R" ]]; then
    /bin/chmod -R +a "$1" "$3"
  else
    /bin/chmod +a "$1" "$3"
  fi
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$LOCK_FILE"
}

# Lets the agent traverse (not list) every directory above $1 it can't
# enter already, from / down, so each test sees the entries added above it.
grant_traverse() {
  local dir="$1" parents=()
  while [[ "$dir" != "/" ]]; do
    dir="$(dirname "$dir")"
    parents=("$dir" "${parents[@]}")
  done
  for dir in "${parents[@]}"; do
    agent_can_enter "$dir" || acl_add "user:$AGENT_USER allow search" - "$dir"
  done
}

READ_RULE="user:$AGENT_USER allow list,search,read,readattr,readextattr,readsecurity,file_inherit,directory_inherit"
WRITE_RULE="user:$AGENT_USER allow list,add_file,search,delete,add_subdirectory,delete_child,read,write,append,readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit"

# ---------------------------------------------------------------- workspace
case "$WORKSPACE_MODE" in
clone)
  # The agent works in its own clone, in its home; the owner's tree gets no
  # ACL. Work goes in as a bundle of the owner's repo and comes back as a
  # bundle of the agent's branches (see cleanup).
  SRC="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    die "clone mode runs from inside a git repository"
  SRC="$(cd "$SRC" && pwd -P)"
  REL="$(git rev-parse --show-prefix)"
  SLUG="$(basename "$SRC")-$(printf '%s' "$SRC" | sha256sum | cut -c1-8)"
  WORK_TREE="$AGENT_HOME/workspaces/$SLUG"
  ;;
in-place)
  WORK_TREE="$(pwd -P)"
  REL=""
  if [[ "$WORK_TREE" == "/" || "$WORK_TREE" == "$HOME" ]]; then
    die "refusing to run in $WORK_TREE: cd into a project first"
  fi
  ;;
*) die "unknown workspace mode: $WORKSPACE_MODE" ;;
esac

# Each grant: resolved (Seatbelt matches real paths), checked, and turned
# into one SBPL rule for the session profile.
GRANT_RULES=""
GRANTS=()
# A path goes inside an SBPL string: no quote, backslash or control char.
UNSAFE='["\[:cntrl:]]'
for path in "${READ_PATHS[@]}"; do
  path="${path/#\~/$HOME}"
  real="$(realpath -e "$path")" || die "--read: no such path: $path"
  [[ "$real" == "/" || "$real" == "$HOME" ]] && die "--read: refusing to grant all of $real"
  [[ "$real" =~ $UNSAFE ]] && die "--read: unsupported characters in $real"
  GRANTS+=("$real")
  GRANT_RULES+="(allow file-read* (subpath-firmlink \"$real\"))"$'\n'
done

NEEDS_ACLS=0
[[ "$WORKSPACE_MODE" == "in-place" ]] && NEEDS_ACLS=1
((${#GRANTS[@]})) && NEEDS_ACLS=1
# Two sessions adding and removing the same ACLs would pull access from
# under each other.
if ((NEEDS_ACLS && LIVE_ACL_SESSIONS)); then
  die "another $CLI_NAME session holds ACLs (in-place or --read); one at a time"
fi

# ---------------------------------------------------------------- session
resolve_key

# /private/tmp, not /tmp: Seatbelt matches resolved paths, and a TMP_DIR
# under the /tmp symlink never matches (tested).
SESSION_TMP="$(sudo -u "$AGENT_USER" /usr/bin/mktemp -d "/private/tmp/claude-$AGENT_NAME.XXXXXX")"

# Hands the agent's branches back to the owner's repo, as
# refs/remotes/<cli name>/*. git on the agent's side runs sandboxed; the
# owner's fetch only reads the bundle, so nothing of the agent's runs as the
# owner.
hand_back() {
  [[ "$WORKSPACE_MODE" == "clone" ]] || return 0
  agent_can_enter "$WORK_TREE/.git" || return 0
  run_sandboxed "$WORK_TREE" git bundle create -q "$SESSION_TMP/agent.bundle" --branches || return 1
  local bundle
  bundle="$(mktemp "${TMPDIR:-/tmp}/$CLI_NAME.XXXXXX")"
  # The agent reads its bundle; the owner writes the copy into its own file.
  # shellcheck disable=SC2024
  sudo -u "$AGENT_USER" /bin/cat "$SESSION_TMP/agent.bundle" >"$bundle"
  git -C "$SRC" fetch -q "$bundle" "+refs/heads/*:refs/remotes/$CLI_NAME/*"
  rm -f "$bundle"
  note "the agent's branches are in $SRC as $CLI_NAME/*"
}

cleanup() {
  local exit_code=$?
  hand_back || note "couldn't fetch the agent's branches; they're still in its clone"
  [[ -f "$LOCK_FILE" ]] && remove_acls "$LOCK_FILE" && rm -f "$LOCK_FILE"
  sudo -u "$AGENT_USER" /bin/rm -rf "$SESSION_TMP" 2>/dev/null || true
  exit "$exit_code"
}
trap cleanup EXIT INT TERM HUP QUIT

# The session profile: the base and the mode's rules, this session's grants,
# then the sensitive-dotfile deny and the agent's home (see claude-sandbox.sb
# for why this order).
{
  cat "$PROFILE_HEAD"
  printf '%s' "$GRANT_RULES"
  cat "$PROFILE_TAIL"
} | as_agent_write "$SESSION_TMP/profile.sb"

# The credential never goes on a command line: sudo stays alive as root for
# the whole session, and any user reads its argv with `ps` (tested). It goes
# through stdin into a 0600 file of the agent's, deleted with the session
# tmp, and from there to Claude Code:
#   api-key      through apiKeyHelper (--settings), which cats the file
#   oauth-token  on file descriptor 3, opened inside the sandbox, named by
#                CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR: not in the
#                environment the agent's subprocesses inherit (tested: a
#                fake token is read and refused, "401 OAuth access token
#                is invalid", and fails at once instead of retrying)
KEY_FILE="$SESSION_TMP/.anthropic-key"
printf '%s' "$RESOLVED_API_KEY" | as_agent_write "$KEY_FILE"
unset RESOLVED_API_KEY

if [[ "$WORKSPACE_MODE" == "in-place" ]]; then
  grant_traverse "$WORK_TREE"
  acl_add "$WRITE_RULE" -R "$WORK_TREE"
fi
for real in "${GRANTS[@]}"; do
  grant_traverse "$real"
  acl_add "$READ_RULE" -R "$real"
done

if [[ "$WORKSPACE_MODE" == "clone" ]]; then
  # The owner's branches, tags and HEAD, read by the owner.
  git -C "$SRC" bundle create -q - HEAD --branches --tags |
    as_agent_write "$SESSION_TMP/owner.bundle"
  if agent_can_enter "$WORK_TREE/.git"; then
    # The owner's latest commits, without touching the agent's work.
    run_sandboxed "$WORK_TREE" git fetch -q "$SESSION_TMP/owner.bundle" \
      "+refs/heads/*:refs/remotes/owner/*" "+refs/tags/*:refs/tags/*"
  else
    note "cloning $SRC into the agent's $WORK_TREE"
    run_sandboxed "$SESSION_TMP" git clone -q --origin owner "$SESSION_TMP/owner.bundle" "$WORK_TREE"
  fi
fi

# Start where the owner was: the same subdirectory of the clone, if it exists.
START_DIR="$WORK_TREE"
if [[ -n "$REL" ]] && sudo -u "$AGENT_USER" /usr/bin/test -d "$WORK_TREE/$REL"; then
  START_DIR="$WORK_TREE/${REL%/}"
fi

# The owner's directory may be closed to the agent's user; sudo starts there.
cd /
case "$AUTH_KIND" in
api-key)
  run_sandboxed "$START_DIR" "$CLAUDE_BIN" \
    --settings "$(printf '{"apiKeyHelper":"/bin/cat %s"}' "$KEY_FILE")" "${CLAUDE_ARGS[@]}"
  ;;
oauth-token)
  # shellcheck disable=SC2016 # expanded by the sandboxed sh, not here
  run_sandboxed "$START_DIR" /bin/sh -c \
    'exec 3<"$1" && shift && CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3 exec "$@"' \
    sh "$KEY_FILE" "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}"
  ;;
*) die "unknown auth kind: $AUTH_KIND" ;;
esac
