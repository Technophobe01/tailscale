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

## Deploy (swap in your locally built binaries)

```bash
just install-preview   # show exactly what would be overwritten — no changes
just deploy            # build + install over Homebrew binaries + restart tailscaled
```

`deploy` copies `./bin/tailscale[d]` over your Homebrew binaries (auto-detecting
`/opt/homebrew` on Apple Silicon or `/usr/local` on Intel) and restarts the daemon.

The default `stop`/`start`/`restart` recipes manage the Homebrew **tailscale service**
via `brew services` (the standard way most people run it). If you instead launch
`tailscaled` by hand, use the `*-manual` recipes (`just start-manual`, `just stop-manual`,
`just restart-manual`), which use the explicit state/socket paths defined in the justfile.

### Verify it works

```bash
just dns-check                       # show the /etc/resolver files that were written
just dns-test myhost.tailnet.ts.net  # resolve a MagicDNS name via the local listener
ping myhost.tailnet.ts.net           # should resolve to a 100.x.x.x address
```

## Revert to the official binaries

```bash
just revert       # brew reinstall tailscale (restores Tailscale's official binaries)
just restart
```

Note: a normal `brew upgrade tailscale` will also replace the patched binaries with the
official ones — re-run `just deploy` after upgrading if you want to keep the patch.

## Caveats

- **Unsupported, dev build.** Built off an unstable dev tree; expect rough edges and
  rebuild as you pull updates.
- **Trademark.** Do not redistribute the compiled binaries under the Tailscale name or
  logo. Share the source/branch and let people build their own.
- **Security.** The local DNS listener binds to `127.0.0.1` only (not network-exposed).
  It delegates all DNS logic to Tailscale's existing resolver. The resolver-file writer
  uses `os.Root` for path-traversal safety and only removes files it wrote.
- **Don't burden upstream.** If something here breaks, it's this fork's responsibility,
  not Tailscale's.

## License

Same as upstream: BSD-3-Clause. See `LICENSE`. Copyright (c) Tailscale Inc & contributors.
