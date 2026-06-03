# Tailscale macOS CLI MagicDNS fix — build / test / deploy helper
#
# UNOFFICIAL community build. Not affiliated with or endorsed by Tailscale, Inc.
# This builds tailscale/tailscaled from source and runs the PATCHED tailscaled via a
# dedicated launchd daemon pointing at ./bin/tailscaled, reusing your existing node
# identity. It does NOT modify or copy over your Homebrew install. `just revert`
# removes the patched daemon and restores the official one.
# See MACOS_CLI_MAGICDNS.md for the full guide and caveats.
#
# Requires: just (https://github.com/casey/just) and a working Homebrew tailscale
# install. Most recipes use sudo. Run `just` with no arguments to list recipes.

# Repo root (this justfile lives at the top of the tailscale source tree).
project_dir := justfile_directory()
bin_dir := project_dir / "bin"

# The --state and --socket your tailscaled runs with. The patched daemon uses the
# SAME --state to reuse your node identity (no re-login). These defaults match the
# common macOS layout; if yours differ, run `just check` and override them.
state_file := "/var/lib/tailscale/tailscaled.state"
socket_file := "/var/run/tailscaled.socket"

# Where the patched daemon logs.
patched_log := "/var/log/tailscaled-patched.log"

# Our patched launchd daemon, and the stock label we disable while it runs.
plist_label := "com.tailscale-patched.tailscaled"
plist_path := "/Library/LaunchDaemons/" + plist_label + ".plist"
official_label := "com.tailscale.tailscaled"

# Show available recipes by default.
default:
    @just --list

# Show how tailscaled is currently launched (running process + launchd jobs).
check:
    @echo "Running tailscaled:"
    @ps -Ao pid,user,args | grep "/[t]ailscaled " || echo "  (none running)"
    @echo ""
    @echo "launchd jobs mentioning tailscale (needs sudo):"
    @sudo launchctl list 2>/dev/null | grep -i tailscale || echo "  (none)"
    @echo ""
    @echo "justfile is set to:  --state={{state_file}}  --socket={{socket_file}}"

# Build tailscale and tailscaled into ./bin using Tailscale's pinned Go toolchain.
build:
    cd {{project_dir}} && ./tool/go build -o bin/tailscale tailscale.com/cmd/tailscale
    cd {{project_dir}} && ./tool/go build -o bin/tailscaled tailscale.com/cmd/tailscaled
    @echo "Built binaries in {{bin_dir}}"

# Run the full test suite (pass package paths/flags as ARGS).
test *ARGS:
    cd {{project_dir}} && ./tool/go test {{ARGS}}

# Run the DNS package tests (the area this fix touches).
test-dns:
    cd {{project_dir}} && ./tool/go test tailscale.com/net/dns/...

# Build, then install + start the patched launchd daemon (reboot-persistent).
deploy: build install-daemon

# Install the patched launchd daemon, disabling whatever currently runs tailscaled.
install-daemon:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Disabling any existing tailscaled management..."
    sudo brew services stop tailscale 2>/dev/null || true
    sudo launchctl bootout system/{{official_label}} 2>/dev/null || true
    sudo pkill -x tailscaled 2>/dev/null || true
    sleep 1
    echo "Writing {{plist_path}} -> {{bin_dir}}/tailscaled"
    printf '%s\n' \
      '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0"><dict>' \
      '<key>Label</key><string>{{plist_label}}</string>' \
      '<key>ProgramArguments</key><array>' \
      '<string>{{bin_dir}}/tailscaled</string>' \
      '<string>--state={{state_file}}</string>' \
      '<string>--socket={{socket_file}}</string>' \
      '</array>' \
      '<key>RunAtLoad</key><true/>' \
      '<key>KeepAlive</key><true/>' \
      '<key>StandardOutPath</key><string>{{patched_log}}</string>' \
      '<key>StandardErrorPath</key><string>{{patched_log}}</string>' \
      '</dict></plist>' \
      | sudo tee {{plist_path}} >/dev/null
    sudo chown root:wheel {{plist_path}}
    sudo chmod 644 {{plist_path}}
    sudo launchctl bootout system/{{plist_label}} 2>/dev/null || true
    sudo launchctl bootstrap system {{plist_path}}
    sudo launchctl kickstart -k system/{{plist_label}}
    sleep 2
    echo "Patched tailscaled running via launchd ({{plist_label}})."
    echo "Use the patched CLI, e.g.:  {{bin_dir}}/tailscale status"

# Revert: remove the patched daemon and restart the official one.
revert:
    #!/usr/bin/env bash
    set -euo pipefail
    sudo launchctl bootout system/{{plist_label}} 2>/dev/null || true
    sudo rm -f {{plist_path}}
    if [ -f "/Library/LaunchDaemons/{{official_label}}.plist" ]; then
      sudo launchctl bootstrap system "/Library/LaunchDaemons/{{official_label}}.plist" 2>/dev/null || true
      sudo launchctl kickstart -k "system/{{official_label}}" 2>/dev/null || true
      echo "Removed patched daemon; restored {{official_label}}."
    else
      sudo brew services start tailscale
      echo "Removed patched daemon; restored the Homebrew tailscale service."
    fi
    echo "NOTE: if you previously copied the patched binary over Homebrew's, run"
    echo "      'brew reinstall tailscale' to restore the official binary."

# Stop the patched daemon (leaves the plist; `just deploy` restarts, `just revert` removes).
stop:
    -sudo launchctl bootout system/{{plist_label}} 2>/dev/null
    @echo "Stopped patched tailscaled (`just deploy` to start, `just revert` to restore official)"

# Show what's running and tailscale status via the patched CLI.
status:
    @ps -Ao pid,user,args | grep "/[t]ailscaled " || echo "tailscaled not running"
    @echo ""
    {{bin_dir}}/tailscale --socket={{socket_file}} status

# Show recent patched-daemon logs.
logs:
    @sudo tail -50 {{patched_log}} 2>/dev/null || echo "No {{patched_log}} yet — run `just deploy` first"

# Follow the patched-daemon log live.
logs-follow:
    sudo tail -f {{patched_log}}

# Show the /etc/resolver files this fix writes (proof MagicDNS is wired up).
dns-check:
    @echo "=== /etc/resolver files ==="
    @ls -la /etc/resolver/ 2>/dev/null || echo "No resolver directory"
    @echo ""
    @for f in /etc/resolver/*; do echo "--- $f ---"; cat "$f" 2>/dev/null; done

# Test MagicDNS resolution against the local listener (default port 5533).
dns-test HOST:
    @echo "Resolving {{HOST}} via the local listener on 127.0.0.1:5533 (see `just dns-check` if 5533 was busy)..."
    @dig @127.0.0.1 -p 5533 {{HOST}} +short

# Remove build artifacts.
clean:
    rm -rf {{bin_dir}}
    @echo "Cleaned {{bin_dir}}"
