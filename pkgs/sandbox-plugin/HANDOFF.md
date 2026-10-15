# Session Handoff: Multi-Agent Claude Code Sandbox for nix-darwin
- **OS Isolation:** Per-agent macOS users (`_claude_<name>`) with strict `0700` homes.
- **Seatbelt MAC (`claude-sandbox.sb`):** Default-deny profile blocking other users' dotfiles, `.git/hooks`, `.claude/settings.local.json`, Secure Enclave Mach services (`com.apple.ctkd.token-client`), and direct internet access.
- **Network Filtering:** Per-agent `tinyproxy` launchd daemons on dedicated localhost ports enforcing regex domain allowlists.
- **Ephemeral ACLs:** Wrapper grants POSIX ACLs on `pwd -P` at launch, tracks PIDs in `/tmp/.claude-acl-locks/` for SIGKILL recovery, and strips ACLs on exit.
- **Hardware Secrets (`claude-agent-init`):** Supports per-agent Secure Enclave P-256 keys (`age-plugin-se` with Touch ID `any-biometry`) and HKDF-SHA256 key derivation from a single Secure Enclave-encrypted 256-bit master seed.

## Review in progress (2026-10-14, Liet on arrakis, with Pedro)

Method, at Pedro's pace ("método pedagógico"): one section of
`claude-sandbox.sb` per turn: explain it, test it with `sandbox-exec`
(one thing that should pass, one that shouldn't), fix, test again. Pedro
watches denials live in another tmux session:

    log stream --style compact --predicate 'sender == "Sandbox"'

Test harness (scratch dirs, never real ones):

    sandbox-exec -f pkgs/sandbox-plugin/claude-sandbox.sb \
      -D TARGET_DIR=<dir> -D AGENT_HOME=<dir> -D TMP_DIR=<dir> -D PROXY_PORT=8888 <cmd>

Proposed next: `pkgs/sandbox-plugin/probe.sh`, running each test and
printing PASSES / BLOCKED next to the expected result, for Pedro to run.

Done:
- Header: the `# vim:` line made the whole profile fail to load (`#` isn't
  a comment in SBPL; `;` is). Pedro had both editor comments removed; the
  profile loads now.

Found, not fixed yet (in section order):
1. Processes: `claude --version` fails inside the profile ("An unknown
   error occurred"), and so does `/bin/sh` ("Unable to determine rootless
   status"). Suspect `(deny dynamic-code-generation)` for claude (JS JIT);
   the `log stream` above will name what's denied. Tests of section 4/5
   writes were inconclusive because sh didn't start.
3. Reading: `~/.ssh` of pplanel is blocked (good).
4. Writing: Seatbelt matches real paths; a TMP_DIR given as /tmp/... won't
   match (/tmp is /private/tmp). Pass resolved paths.
5. Hook escapes not covered: `.envrc` (direnv runs it as Pedro on cd),
   `.claude/settings.json` / `.claude/agents` / `.claude/skills` /
   `.mcp.json` (project hooks and MCP run by Pedro's own Claude), `.nvim.lua`
   (exrc). Only `.git/hooks`, `.git/config`, `.claude/commands` and
   `.claude/settings.local.json` are denied today.
6. Network: line `(allow network-outbound (remote ip "localhost:*"))` opens
   every local port, not just the agent's proxy. Verified: reached
   claude-mesh serve on 127.0.0.1:7480, which serves every synced
   transcript and memory with no authentication (a claude-mesh issue too).
   Other agents' proxies and the nixcache proxies are reachable the same
   way. Also: mDNSResponder allowed means DNS lookups, a possible
   exfiltration channel; with a proxy the client doesn't need DNS.

Still to discuss: flake.nix (users, tinyproxy, ACL wrapper, keys).
Enclave lessons from 2026-10-12 apply to `claude-agent-init`: an enclave
key works only in the context it was created in (session vs daemon), and
`any-biometry` blocks anything unattended.
