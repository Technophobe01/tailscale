# MagicDNS for the macOS Homebrew / CLI `tailscaled` (unofficial build)

> **Unofficial community build. Not affiliated with, supported by, or endorsed by
> Tailscale, Inc.** "Tailscale" is a trademark of Tailscale, Inc. This is a
> build-it-yourself patch on top of the open-source `tailscale.com` tree for people
> who need MagicDNS on the Homebrew CLI variant today. **Please do not file issues
> about this build on the upstream `tailscale/tailscale` repo** — it is not theirs to
> support. File issues on this fork instead.

## What this is

A small set of patches to `net/dns` that make **MagicDNS work on macOS when you run
the Homebrew / CLI `tailscaled`** (the open-source variant, `brew install tailscale`),
rather than the GUI app. You build the binaries yourself and swap them in on your own
machine. No pre-built binaries are distributed.

## The problem it addresses

On macOS there are two practical ways to run Tailscale, and each is missing one feature:

| Variant | SSH **server** (host) | MagicDNS |
|---|---|---|
| Standalone / GUI (sandboxed system extension) | ❌ blocked by Apple sandbox | ✅ works |
| Homebrew CLI (`tailscaled`) | ✅ works | ❌ **broken — this is what we fix** |

So today you must choose between hosting SSH and having MagicDNS. This patch fixes the
**MagicDNS half for the Homebrew CLI variant**, so that variant can do both.

### Root cause (CLI variant)

1. `MatchDomains` was only set for iOS, not darwin, so `/etc/resolver/` files were never
   created for MagicDNS domains.
2. Split-DNS routes (domains with custom resolvers) were not included in `MatchDomains`.
3. macOS intercepts UDP port 53 before packets reach userspace listeners, so a local DNS
   listener on **127.0.0.1:5533** is used instead, and the `/etc/resolver` files point at
   it with a `port` directive.
4. A `dns.CleanUp` race on startup could delete resolver files belonging to an
   already-running instance; `Close()` now only removes files it wrote, and a watcher
   re-creates them if they disappear.

## Tailscale's preferred long-term direction

This patch is an **interim stopgap**, not a proposed replacement for Tailscale's own plan.
The maintainers' stated long-term direction for closing the macOS feature gap (see
[issue #4518](https://github.com/tailscale/tailscale/issues/4518), comment by `@agottardo`,
2025‑01‑28) is **not** a kernel driver. It is to bundle a **LaunchDaemon** acting as the
SSH server inside the **Standalone** variant, communicating over **XPC** with the existing
**system (Network) extension**, plus a root-escalation UI to install it. That work targets
the *other* half of the table above (SSH server in the Standalone variant) and is
acknowledged by Tailscale to be substantial, with no committed timeline.

This fork does not attempt that architecture and does not reopen the rejected pull request
([#18272](https://github.com/tailscale/tailscale/pull/18272)). It simply keeps the CLI
variant usable for MagicDNS in the meantime.

## Upstream convergence status (as of v1.102.2)

Tailscale is converging on its own fix for macOS CLI DNS. The work is tracked in
[#1338](https://github.com/tailscale/tailscale/issues/1338) (still **open** — the issue
thread is quiet, but the progress is in commits, not comments). In v1.102.2, Tailscale
landed two changes under "Updates #1338" (both by a core maintainer, 2026-06-28):

- `9013b6ec1` **net/dns: simplify split DNS compile path** — the unsandboxed darwin
  (CLI) path now sets `ocfg.MatchDomains = cfg.matchDomains()` like every other
  split-DNS-capable OS, instead of being excluded as "apple".
- `10672a63f` **net/dns: support global resolvers in macOS tailscaled** — adds a
  scutil / SystemConfiguration global resolver (`setGlobalDNS`) so that a tailnet using
  global DNS (default resolvers + MagicDNS) is served by pointing macOS at
  100.100.100.100 through the dynamic store. On current macOS this **works**.

Because of this, the fork was rebased onto v1.102.2 with a reduced patch set.

### What this patch no longer needs to do

- **Forcing `MatchDomains` for darwin in `compileConfig` (net/dns/manager.go).** The
  original patch added darwin-specific blocks that appended MagicDNS/`LocalDomains` and
  split routes to `MatchDomains`. Upstream's `9013b6ec1` now does the equivalent via the
  normal path (`cfg.matchDomains()`), and darwin returns before ever reaching those
  blocks. They were **dead code after the rebase and have been removed.**
- **A local listener for the global-DNS case.** When the tailnet uses global default
  resolvers (no split domains), upstream's `setGlobalDNS` (`10672a63f`) makes MagicDNS
  resolve on its own. The listener is not engaged for that configuration.

### What this patch still needs to do

- **Local DNS listener on 127.0.0.1 (net/dns/manager_darwin.go), plus the `SetResolver`
  hook and the `/etc/resolver` `port` directive.** Upstream still writes `/etc/resolver`
  files pointing at 100.100.100.100 for the **split-DNS** case (non-empty
  `MatchDomains`), and on the macOS CLI those packets do not reach userspace (see root
  cause above). The listener re-points those files at `127.0.0.1:<port>`. This is the
  part upstream has **not** adopted (see the rejection of #18272 — they prefer the scutil
  direction), so it remains necessary for split-DNS tailnets.
- **The `dns.CleanUp` race fix (net/dns/manager_darwin.go, `Close()` `hadFiles` guard).**
  [#18800](https://github.com/tailscale/tailscale/issues/18800) is still **open and
  unfixed upstream**; v1.102.2's `Close()` still unconditionally removes resolver files,
  which deletes files belonging to an already-running instance during a launchd
  KeepAlive restart. This fix is a plain bug fix (not the rejected "direction") and is
  still required. On rebase it was extended to also guard `removeGlobalDNS`.
- **The build/deploy tooling (`justfile`).** This is an unofficial, build-it-yourself
  patch; the tooling to build, run via launchd, and revert is still needed regardless of
  upstream code convergence.

### Net effect

For a **global-DNS** tailnet, MagicDNS now works largely on upstream v1.102.2 behavior,
and it is worth periodically re-testing whether the **stock Homebrew build** suffices for
your setup. For a **split-DNS** tailnet, and for the CleanUp race on launchd restarts,
this patch is still doing work upstream has not landed. The broader SSH-in-Standalone gap
([#4518](https://github.com/tailscale/tailscale/issues/4518)) — the reason to run the CLI
variant at all — remains open with no timeline.

## Prerequisites

- macOS, with the **Homebrew** Tailscale installed: `brew install tailscale`
- [`just`](https://github.com/casey/just): `brew install just`
- Xcode command-line tools (for the Go toolchain build): `xcode-select --install`
- No system Go needed — the repo's `./tool/go` wrapper downloads Tailscale's pinned Go.

## Get the code

```bash
git clone -b fix/macos-magicdns-homebrew https://github.com/Technophobe01/tailscale.git
cd tailscale
```

## Build

```bash
just build        # builds ./bin/tailscale and ./bin/tailscaled
```

## Test

```bash
just test-dns     # runs tailscale.com/net/dns/... (the area this patch touches)
just test ./...   # full suite (slower)
```

## Deploy (run the patched daemon via launchd)

This does **not** modify or copy over your Homebrew install. It installs a dedicated
launchd daemon (`/Library/LaunchDaemons/com.tailscale-patched.tailscaled.plist`) that
runs the patched binary from `./bin/tailscaled`, disables whatever currently runs
tailscaled, and starts the patched one — reusing your existing node identity (same
`--state`), so you don't have to log in again. Because it's a `KeepAlive` launchd
daemon, it survives reboots until you `just revert`.

```bash
just check    # show how your tailscaled is currently launched (state/socket + launchd jobs)
just deploy   # build + install the patched launchd daemon + start it (uses sudo)
```

`state_file` defaults to `auto`: the tooling detects your state file from an existing
LaunchDaemon's `--state` (e.g. a custom `com.tailscale.tailscaled`), or by probing the
common macOS locations (`/Library/Tailscale/tailscaled.state` on a stock Homebrew
install, `/var/lib/tailscale/...` for a custom setup). `just check` prints the
**Resolved state file** it will use. If detection is wrong for your machine, override it:

```bash
just state_file=/path/to/tailscaled.state deploy
```

If the patched daemon ever comes up logged out, the state path didn't match — re-check
with `just check`, override `state_file`, and redeploy (or run `./bin/tailscale up` once).

### macOS privacy (TCC) prompts

The Homebrew/CLI `tailscaled` is not the GUI Tailscale.app and has no Apple Developer ID
signature, so macOS TCC treats it as an unknown binary. When run as a root LaunchDaemon
it can land on consent prompts attributed to "tailscaled" for **Photo Library** and
**Google Drive / iCloud Drive** (the macOS File Provider Domain category). These are
**macOS prompts about path access, not Tailscale asking for your data** — nothing in
this fork's code reads photos or cloud-drive files.

`just deploy` minimizes these by:

- **Ad-hoc signing the binary** with a stable identifier (`com.tailscale.tailscaled-patched`)
  in `just build`, so Console/TCC logs have a consistent subject across rebuilds.
- **Sandboxing the daemon environment** in the LaunchDaemon plist:
  `WorkingDirectory=/var/empty`, `HOME=/var/empty`, `TMPDIR=/var/empty`. This stops any
  `$HOME`-derived path probing from landing inside `~/Pictures` or `~/Library/CloudStorage/`,
  which is what triggers the prompts.

If a prompt still appears on first deploy, **"Don't Allow" is safe.** MagicDNS, subnet
routing, and CLI Taildrop do not need access to Photos, iCloud Drive, or Google Drive;
the daemon will get `EPERM` for any such read and continue.

### Verify it works

Use the **patched CLI** from `./bin`:

```bash
just status                          # confirm the patched tailscaled is running
just dns-check                       # show the /etc/resolver files that were written
just dns-test myhost.tailnet.ts.net  # resolve a MagicDNS name via the local listener
./bin/tailscale status               # patched CLI talks to the patched daemon
ping myhost.tailnet.ts.net           # should resolve to a 100.x.x.x address
```

## Revert to the official daemon

```bash
just revert   # remove the patched launchd daemon and restart the official one
```

`just revert` boots out and deletes the patched LaunchDaemon, then re-enables your
official daemon (the stock `com.tailscale.tailscaled` LaunchDaemon if present, otherwise
the Homebrew `tailscale` service). Nothing in your Homebrew install was modified by
deploy, so there is nothing to reinstall — **unless** you had previously copied the
patched binary over Homebrew's, in which case run `brew reinstall tailscale` once.

## Caveats

- **Unsupported, dev build.** Built off an unstable dev tree; expect rough edges and
  rebuild as you pull updates. After pulling new commits, re-run `just deploy`.
- **Keep the repo in place.** The launchd daemon runs `./bin/tailscaled` by absolute
  path. If you move or delete the checkout, run `just revert` first (or the daemon will
  fail to start).
- **State must match.** The patched daemon reuses your identity only if its `--state`
  matches your current daemon's. `state_file=auto` detects this; verify with the
  **Resolved state file** line in `just check`, override `state_file` if needed, and if
  in doubt `./bin/tailscale up` re-authenticates.
- **Trademark.** Do not redistribute the compiled binaries under the Tailscale name or
  logo. Share the source/branch and let people build their own.
- **Security.** The local DNS listener binds to `127.0.0.1` only (not network-exposed).
  It delegates all DNS logic to Tailscale's existing resolver. The resolver-file writer
  uses `os.Root` for path-traversal safety and only removes files it wrote.
- **Don't burden upstream.** If something here breaks, it's this fork's responsibility,
  not Tailscale's.

## License

Same as upstream: BSD-3-Clause. See `LICENSE`. Copyright (c) Tailscale Inc & contributors.
