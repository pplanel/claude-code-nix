# claude-sandbox: design

A nix-darwin module (`darwinModules.sandbox`) that runs Claude Code agents
isolated from their owner: each agent is its own macOS user, runs inside a
Seatbelt profile, and reaches the network only through its own filtering
proxy. It's meant for other people too, so every choice below is an option
with a safe default.

## Layers

Two independent barriers, so a hole in one doesn't expose the owner:

1. **The OS user.** Each agent is `_claude_<name>` with a `0700` home. The
   owner's home (`/Users/<owner>`, `0750` by default) is closed to it: tested,
   another user can't even list it.
2. **Seatbelt** (SBPL version 3, default deny). The agent reads the system, its
   workspace, its own home and what it was granted; writes its workspace, its
   session tmp and Claude Code's state; talks only to its proxy.

Plus the **proxy**: one tinyproxy per agent on `127.0.0.1:<port>`, with a
domain allowlist, `CONNECT` to 443 only, default deny.

## Files

| File | What it is |
|---|---|
| `default.nix` | the options, the profile pieces, the users, proxies and sudoers |
| `claude-sandbox.sb` | the base profile, shared by every agent |
| `in-place.sb` | write denies appended in in-place mode |
| `sensitive.sb` | the read deny on credentials, appended after grants |
| `wrapper.sh` | the `claude-<name>` command; `default.nix` adds a preamble |

## Options (per agent)

```nix
services.claude-sandbox = {
  enable = true;
  agents.liet = {
    uid = 601;                       # one no other user has
    proxy.port = 8801;
    proxy.allowedDomains = [ "^(.*\\.)?anthropic\\.com$" ];
    workspace.mode = "clone";        # default; or "in-place"
    read.paths = [ "~/src/docs" ];   # always readable, besides --read
    read.allowRuntimeGrants = true;  # default
    homeReadScope = "full";          # default; or "state-only"
    git = { name = "liet"; email = "liet@localhost"; };
    network.listenPorts = [ 3000 ];  # everything network is closed by default
    auth.kind = "oauth-token";         # or "api-key" (default)
    auth.strategy = "secure-enclave";  # or hkdf-derived, keychain, sops-file
  };
};
```

### `workspace.mode`

- **`clone`** (default). The agent works in its own clone,
  `~_claude_<name>/workspaces/<repo>-<hash of its path>`. The owner's tree gets
  no ACL, and the agent's user has no access to anything of the owner's, so
  the two layers are truly independent.
  - At start, the wrapper bundles the owner's repo (`HEAD`, branches, tags) and
    hands it over: the agent clones it the first time, then fetches into
    `refs/remotes/owner/*` without touching its own work.
  - At exit, the agent bundles its branches and the wrapper fetches them into
    the owner's repo as `refs/remotes/<cliName>/*`. The owner reviews and
    merges like any other branch.
  - Every git command on the agent's clone runs inside the sandbox: a hook or
    `core.fsmonitor` the agent planted must not run outside it. The owner's
    side only reads a bundle, so nothing of the agent's runs as the owner.
  - The agent may commit, and may write `.git`, `.claude` and hook files in its
    clone: nothing the owner runs reads them. A change to them reaches the
    owner only through a merge, like any code.
  - Runs from inside a git repository with at least one commit; the agent
    starts in the same subdirectory.
- **`in-place`**. The agent works in the owner's tree, for working on the same
  tree at the same time.
  - The wrapper grants the agent `search` (traverse, not list) on each
    directory above the workspace it can't enter, read/write inside it, and
    removes all of it at exit.
  - `.git`, `.claude`, and `.envrc`, `.mcp.json`, `.nvim.lua`, `.exrc` at any
    depth are write-denied (`in-place.sb`), since the owner's tools run them.
    The agent can't commit.
  - Cost: Seatbelt becomes the only barrier between the agent and any file in
    the owner's home it can name and that is readable by others.

### `read.paths` and `--read`

The owner's files are invisible by default. A grant opens one path,
read-only, for one session: fixed in config (`read.paths`, `~` is the owner's
home) or on the command line (`claude-<name> --read <path>`, repeatable,
turned off with `read.allowRuntimeGrants = false`).

Each grant is resolved (`realpath`), refused if it's `/` or the whole home,
and opened twice: ACLs (`search` on each parent the agent can't enter, read
inside) and one `(allow file-read* (subpath …))` in the session profile.
Credentials stay denied whatever the grant (`sensitive.sb` comes after).

### `network`

Closed by default: the agent's proxy is its only way out. SBPL filters
network rules by port, with the host either `localhost` or `*`; no rule can
name one LAN host or one interface (`awdl0`, `en0`, `utun*`). So each option
opens exactly this, and the tests check it (the `net` test agent has all of
them on):

| Option | Opens |
|---|---|
| `localhostPorts` | connecting to those local ports (TCP and UDP) |
| `listenPorts` | listening on those local ports, and connecting to them |
| `directPorts` | those ports on **any** host, without the proxy: LAN, Tailscale, AWDL peers, the internet. Peer-to-peer traffic needs this. |
| `bonjour` | mDNSResponder's socket, `com.apple.dnssd.service`, UDP 5353 in and out to any host. mDNSResponder also serves every DNS lookup, so this **reopens DNS**; and UDP 5353 reaches AWDL peers too. |
| `unixSockets` | those sockets, by real path (`/private/var/run/…`) |
| `extraRules` | raw SBPL, appended after the above |

Not offered: anything that would let the agent reach the owner's own
services (claude-mesh, airshell-proxy, other agents' proxies) except by
listing their port or socket explicitly; and Wi-Fi/Bluetooth daemons
(`airportd`, `wirelessproxd`, BLE), which give scanning and control, not
traffic, and have no tested use (`extraRules` can add them). A daemon socket
in `unixSockets` can be a way out of the sandbox: the nix daemon builds what
it's asked (fixed-output derivations download outside the proxy), docker
runs containers.

The owner's infrastructure isn't meant to run in this profile: airshell-proxy
needs AWDL, Bonjour, listening and its control socket; claude-mesh listens on
7480 and reads the whole Claude config dir. A profile per service, as
defense in depth, is a separate idea. claude-mesh's 7480 answering any local
process without authentication is pplanel/claude-mesh#1.

### `auth`

`auth.kind` says what the stored credential is; `auth.strategy` where it's
kept (Secure Enclave by default, `claude-agent-init` stores it).

- **`api-key`** (default): an Anthropic API key. Claude Code gets it through
  `apiKeyHelper` (`--settings '{"apiKeyHelper":"/bin/cat <file>"}'`).
- **`oauth-token`**: a long-lived token from `claude setup-token`, so the
  agent runs on the owner's Claude subscription (and its usage limits).
  Claude Code gets it on file descriptor 3, opened by a `sh` inside the
  sandbox, and named by `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`: the token
  is in no environment and on no command line. Tested: with no credential
  Claude Code says "Not logged in"; with a fake token on the descriptor it
  reads it and the API answers "401 OAuth access token is invalid", at once
  (no retry loop, unlike `apiKeyHelper`).

Either way the credential reaches the agent's session tmp through stdin, as
a `0600` file of the agent's, deleted with the tmp; the agent's own processes
can read it, as they can use it.

### `homeReadScope`

The home is the agent's own, so it reads all of it (`full`). In clone mode the
home holds every workspace of that agent, so one session can read another
project's clone of the same agent. `state-only` limits reads to Claude Code's
state (`.claude`, `.claude.json`, `.config/claude`, `.cache`, `.npm`) plus the
current workspace. For real separation between projects, use one agent per
project.

## The session profile

The wrapper writes it into the session tmp, in this order (SBPL applies the
last matching rule, so the order is the policy):

1. `claude-sandbox.sb`, the base
2. `in-place.sb`, in in-place mode, and the `network` options' rules
3. the read grants, one rule per path
4. `sensitive.sb`: credentials, after the grants so no grant reopens them
5. the agent's home read (`homeReadScope`), after 4 so the agent still reads
   its own `~/.config` (the regex in 4 matches every `/Users/*/.config`)

Every parameter comes with `-D`, as a resolved path; a missing one fails to
compile, so the profile fails closed.

## The wrapper, step by step

1. Parse `--read`; everything else goes to claude.
2. Remove ACLs left by sessions that died (lock files in
   `~/.local/state/claude-sandbox/locks`, one line per ACL entry). Refuse to
   start a session that needs ACLs while another session of the same agent
   holds some: they would pull access from under each other.
3. Get the API key (`auth.strategy`; Touch ID for the enclave strategies).
4. Make the session tmp under `/private/tmp`, owned by the agent, and set the
   exit trap.
5. Write the session profile and the key file into it (through stdin, as the
   agent, mode `0600`).
6. Add the ACLs (in-place workspace, grants), each recorded in the lock file.
7. Clone mode: hand the owner's repo over.
8. Start claude as the agent: `sudo -u <agent> env -i <agent env>
   sandbox-exec -f <profile> -D … sh -c 'cd <dir> && exec claude …'`, with
   `--settings {"apiKeyHelper": …}` (api-key) or the token on fd 3
   (oauth-token).
9. At exit: hand the agent's branches back (clone), remove the ACLs, delete
   the session tmp (and the key with it).

The agent's environment is built from nothing (`env -i`): `HOME`, `USER`,
`PATH` (claude, git, ripgrep, fd, nodejs, `extraPackages`), the proxy
variables, git's author and committer, `TERM`, `extraEnv`.

## Concurrency and subagents

Untested; this is the expected behavior, to check in the end-to-end test.

- **Sessions of different agents** never interfere: each has its own user,
  ACLs, lock files and proxy.
- **Sessions of the same agent** run side by side in clone mode without
  `--read`: they use no ACL. Only one session per agent at a time may hold
  ACLs (in-place, or any `--read`), even in different projects: the ACLs that
  matter are on the shared parents (`/Users/<owner>`, `~/src`…), and one
  session's cleanup would remove them from under the other. A reference count
  per ACL would lift this, at the cost of shared state with locking
  (macOS has no `flock(1)`) and the risk of ACLs left behind in the owner's
  home.
- **`--read` as a copy** instead of ACLs is an option to weigh: the wrapper,
  as the owner, copies each granted path into the session tmp, read-only. No
  ACL touches the owner's home, the user layer stays independent, and only
  in-place would need the one-session limit. Cost: a snapshot from the
  session's start (later changes don't show), and time and space for big
  paths.
- **Subagents** (Claude Code's Agent tool) run inside the session that spawned
  them, as the same process or its children. Seatbelt is inherited and can't
  be left, so they have the session's user, profile and grants, and nothing
  more: they don't go through the wrapper, add no ACL, take no lock, and
  can't widen access (the agent's user has no sudo, and the sandbox wouldn't
  allow it). Only the owner decides grants, when the session starts.
- **Subagents with `isolation: worktree`** create a git worktree, writing
  `.git/worktrees/` and the worktree's files (possibly under `.claude/`).
  Expected to work in clone mode, where both are writable; expected to fail
  in in-place mode, where `.git` and `.claude` are write-denied on purpose.
- **Parallel subagents share the agent's proxy**, whose `MaxClients` is 25.
- **One agent delegating to another** (claude-liet asking claude-outro) has no
  path, on purpose: it would cross users. If ever wanted, it needs its own
  design (a channel the owner controls), not a hole in the sandbox.

## Tests

`modules/sandbox/tests/run.sh`, by hand, on a Mac, after any change to the
`.sb` files or to how `default.nix` composes them. Not part of
`nix flake check`: nix builds run inside a sandbox, and `sandbox-exec` can't
nest.

- `agents.nix` builds the wrappers for three test agents (clone + full home
  + no network option; in-place + state-only; net, with every network
  option on); `run.sh` composes their session profiles the way
  `wrapper.sh` does, in a scratch tree under `/private/tmp`.
- **File cases**: `claude -p` starting, network enumeration, workspace writes, `.envrc`/`.git` allowed in clone and
  denied in in-place (with the `mv` bypass), grants, credentials winning over
  a grant of the whole home, both home scopes, `claude --version`.
- **Network cases** (`net-probe.py`): every way out, run outside the sandbox
  first as a control, then inside the clone profile (only the proxy passes)
  and the net profile (exactly what its options open passes). A target unreachable even outside is skipped; a refused
  connection counts as reachable outside and as let through inside, so only
  a real denial passes. Targets are found on the machine (gateway, a
  Tailscale peer, the Unix sockets that exist).
- Exit status is the number of wrong results.
- It runs as the owner, so it tests Seatbelt alone; the agent's user is a
  second barrier in real use.
- Checked against mutations: reopening `localhost:*` gives 2 wrong results,
  allowing `net.routetable` 3, dropping `CLAUDE_CODE_TMPDIR` 1.

Last run (arrakis, 2026-10-15): 59 ok, 0 wrong, 2 skipped (no `~/.aws`,
`~/.gnupg`).

## What the tests taught (SBPL)

Tested with `sandbox-exec` on macOS 26, watching denials with
`log stream --predicate 'sender == "Sandbox"'`.

- `#` is not a comment; `;` is. One `# vim:` line kept the profile from loading.
- Seatbelt matches **resolved** paths. `/tmp/x` is `/private/tmp/x`; a rule
  on `/tmp/...` never matches. Every `-D` path must be resolved (`pwd -P`,
  `/private/tmp`, `realpath`). Symlinked system paths too:
  `/System/Cryptexes/OS` is really `/System/Volumes/Preboot/Cryptexes/OS`,
  and `/var/lib/sops-nix` is `/private/var/lib/sops-nix`.
- Rules match **each operation's own path**. A deny on `.git/hooks` was
  bypassed with `mv .git .gitx`, write `.gitx/hooks/pre-commit`,
  `mv .gitx .git`. Deny the whole directory (`subpath .git`) instead.
  Renaming onto a denied file name is denied (the destination is checked).
- Version 3 default-denies what version 1 left open. Needed so far:
  `syscall-unix`, `syscall-mach`, `file-test-existence`, `system-fcntl`,
  `system-mac-syscall` (AMFI, Sandbox), `socket-option-get/set`,
  `file-map-executable` on `/nix/store` (nix binaries load store dylibs), and
  the `security.mac.lockdown_mode_state` sysctl. Syscalls and fcntl are
  allowed whole for now; narrowing them is future work.
- SBPL takes one port or `*` in network addresses, not a range.
- `(param "X")` without `-D X=` fails to compile. `(regex (string-append …))`
  compiles, so regexes can include parameters.
- Claude Code is Bun (JavaScriptCore) and needs JIT
  (`dynamic-code-generation`). Denying it adds nothing: the agent can already
  write and run binaries.
- Claude Code reads its working directory at start; outside the allowed
  paths it fails. The wrapper always starts it inside the workspace.
- The process changes names (`sandbox-exec` → `bash` → `claude` →
  `.claude-wrapped`); log filters must include all of them.
- `localhost:*` outbound reached claude-mesh (127.0.0.1:7480, unauthenticated)
  and every other local service. DNS through mDNSResponder is an exfiltration
  channel, and with a proxy the client doesn't need it. Both are closed;
  outbound is the proxy port only.
- Every other way out is closed by `(deny default)` alone (tested with a
  Python probe inside the clone profile, and outside as a control, where all
  but one target were reachable): other localhost TCP and UDP ports,
  listening on localhost, the LAN, Tailscale peers, the internet (TCP and
  UDP), DNS, mDNS/Bonjour multicast, AWDL (`ff02::1%awdl0`), and Unix sockets:
  `nix-daemon`, `tailscaled`, `determinate-nixd`, `mDNSResponder`, `portmap`,
  airshell-proxy's control socket, tmux. The nix-daemon and tailscaled
  sockets are `rw-rw-rw-`, so for them Seatbelt is the only barrier: the
  daemon would build for the agent (fixed-output derivations download outside
  the proxy), and tailscaled's local API sends files and lists peers.
- `sysctl net.routetable` (allowed by an early draft) lists every interface,
  the routes (Tailscale's included) and the ARP table with the LAN's MAC
  addresses: no packet leaves, but it maps the owner's network. Claude Code
  runs without it, so it's denied; `if_nameindex`, `netstat -rn` and `arp -an`
  fail. `ifconfig`'s ioctls were already denied (`socket-ioctl`). Wi-Fi,
  AWDL, Bluetooth and NetworkExtension daemons (airportd, sharingd,
  bluetoothd, nehelper…) need no rule: `(deny default)` covers every
  `mach-lookup` not in section 2's list.
- Claude Code ignores `TMPDIR` for its own files: it opens `/tmp/claude-<uid>`,
  outside the profile, unless `CLAUDE_CODE_TMPDIR` is set. The wrapper sets
  both to the session tmp.
- Reading another process's arguments from inside the sandbox is denied by
  `(allow process-info* (target same-sandbox))` (`process-info-pidinfo
  others`), even through a direct `sysctl KERN_PROCARGS2`. Outside the
  sandbox any user reads any process's arguments.

The end-to-end test on caladan (a real agent user, 2026-10-15) found what
no profile test could:

- `/usr/bin/test` doesn't exist on macOS (`/bin/test` does): every "can the
  agent enter this directory?" answered no, so a second session would clone
  over its own clone, and grants would add ACLs on every parent. The sudoers
  entry named the wrong path too.
- macOS has no `_nobody` user; tinyproxy runs as `nobody`.
- tinyproxy's `BindSame yes` bound the outgoing connection to the address
  the request came in on, `127.0.0.1`, so the proxy could reach nothing:
  "Could not establish a connection to api.anthropic.com:443", `curl -x`
  through it got a 500. Removed. `FilterExtended` is deprecated in tinyproxy
  1.11; `FilterType ere` instead.
- Every `sudo -u <agent>` started in the owner's directory, which the agent
  can't read, and its shell printed `getcwd: Permission denied`. The wrapper
  `cd /`s once all paths are resolved.
- Working, as designed: the owner can't enter the agent's home (`0700`); the
  owner's repo reached the agent's clone through a bundle, cloned sandboxed;
  the subscription token was read from the keychain and handed over.

And outside SBPL:

- macOS ACLs: `chmod -R +a` with `file_inherit,directory_inherit` maps `list`
  to `read` and `search` to `execute` on files; files created later inherit
  the entry; `chmod -R -a` with the same rule removes the inherited copies too.
- `apiKeyHelper` given through `--settings` works (also under `--bare`). On a
  401 Claude Code calls the helper again and retries with backoff, without
  end: a revoked key hangs the agent instead of failing.

## Resolved

1. **The API key showed in `ps`.** The wrapper passed `ANTHROPIC_API_KEY=…` as
   an argument to `sudo … env -i`; `sudo` stays alive as root for the whole
   session, and any user (tested: `nobody`) read it with `ps -axww`. It now
   goes through stdin into a `0600` file in the agent's session tmp, read by
   `apiKeyHelper`; it's deleted with the tmp. Preferred over `env_keep`, which
   would leave the key in every subprocess's environment.
2. **The session tmp was unresolved** (`/tmp/…`), so the agent couldn't write
   it. Now `/private/tmp`.
3. **Claude Code came from nixpkgs**, not the pinned build. The module now
   lives in the root flake with a `package` option defaulting to the pin.
4. **The `.config` deny also hid the agent's own `~/.config`.** The home read
   now comes after it.
5. **ACL lock files lived in `/tmp`**, where another user could create them
   first. Now in `~/.local/state/claude-sandbox`, `0700`.
6. **The wrapper had never built**: shellcheck rejected bash conditions on
   values Nix had already filled in. Those choices are made in Nix now.
7. **`claude-agent-init --se` always failed**: `\vert{}` where `|` belonged.

## Open

1. **End-to-end test**: a real agent user, a real tinyproxy, and claude
   reaching the API through it; then clone mode's hand-over and hand-back,
   in-place ACLs and `--read` as the agent's user. Needs the module enabled on
   a machine. Tested so far: the composed profiles (15 cases, both modes), the
   ACL rules (apply, inherit, remove), the key handling, the build.
2. The `hkdf-derived` strategy uses AES-CBC with a zero IV.
3. Secure Enclave keys work only in the context that created them (login
   session vs daemon), and `any-biometry` blocks anything unattended.
4. The sudoers entry lets admins run anything as the agent (`/usr/bin/env`
   takes any command). That direction is fine (the agent is the less
   privileged side), but the list of other commands is decoration.
5. Clone mode bundles every branch at every start and exit; incremental
   bundles would do for big repositories.
6. `in-place` and `--read` sessions of the same agent run one at a time (see
   Concurrency and subagents: reference counts, or `--read` as a copy).
7. Narrow `syscall-unix`, `syscall-mach` and `system-fcntl` to what Claude
   Code and its tools use.
