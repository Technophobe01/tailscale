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

`just check` prints the running daemon's `--state`/`--socket`. The justfile defaults
to the common macOS layout (`/var/lib/tailscale/tailscaled.state`,
`/var/run/tailscaled.socket`); if `check` shows different paths, set `state_file` /
`socket_file` at the top of the justfile to match — otherwise the patched daemon comes
up logged out (in which case just run `./bin/tailscale up` once).

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
- **State must match.** The patched daemon reuses your identity only if `state_file`
  matches your current daemon's `--state` (see `just check`). If in doubt,
  `./bin/tailscale up` re-authenticates.
- **Trademark.** Do not redistribute the compiled binaries under the Tailscale name or
  logo. Share the source/branch and let people build their own.
- **Security.** The local DNS listener binds to `127.0.0.1` only (not network-exposed).
  It delegates all DNS logic to Tailscale's existing resolver. The resolver-file writer
  uses `os.Root` for path-traversal safety and only removes files it wrote.
- **Don't burden upstream.** If something here breaks, it's this fork's responsibility,
  not Tailscale's.

## License

Same as upstream: BSD-3-Clause. See `LICENSE`. Copyright (c) Tailscale Inc & contributors.
