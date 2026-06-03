# Tailscale macOS CLI MagicDNS fix — build / test / deploy helper
#
# UNOFFICIAL community build. Not affiliated with or endorsed by Tailscale, Inc.
# This justfile builds tailscale/tailscaled from source on your own machine and
# (optionally) swaps your Homebrew-installed binaries with the locally built ones.
# See MACOS_CLI_MAGICDNS.md for the full guide, caveats, and how to revert.
#
# Requires: just (https://github.com/casey/just) and a working Homebrew tailscale
# install. Run `just` with no arguments to list the available recipes.

# Repo root (this justfile lives at the top of the tailscale source tree).
project_dir := justfile_directory()
bin_dir := project_dir / "bin"

# Auto-detect the Homebrew bin dir (/opt/homebrew on Apple Silicon,
# /usr/local on Intel). Prefer `brew --prefix`; if brew isn't on PATH,
# fall back to the arch default (arm64 -> /opt/homebrew, else /usr/local).
brew_prefix := `brew --prefix 2>/dev/null || { [ "$(uname -m)" = arm64 ] && echo /opt/homebrew || echo /usr/local; }`
brew_bin := brew_prefix / "bin"

# Used only by the manual (*-manual) daemon recipes below. The default
# stop/start/restart recipes manage the Homebrew service via `brew services`.
state_file := "/var/lib/tailscale/tailscaled.state"
socket_file := "/var/run/tailscaled.socket"

# Show available recipes by default (safer than auto-deploying).
default:
    @just --list

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

# Show what `install` would overwrite, without changing anything.
install-preview:
    @echo "Would copy:"
    @echo "  {{bin_dir}}/tailscale  -> {{brew_bin}}/tailscale"
    @echo "  {{bin_dir}}/tailscaled -> {{brew_bin}}/tailscaled"
    @echo ""
    @echo "Current installed versions:"
    @{{brew_bin}}/tailscaled --version 2>/dev/null | head -1 || echo "  (tailscaled not found at {{brew_bin}})"

# Copy locally built binaries over the Homebrew ones (requires sudo; `just revert` undoes it).
install:
    # NOTE: this overwrites brew-managed files; a later `brew upgrade tailscale`
    # will replace them with the official binaries again. Use `just revert` to undo.
    sudo cp {{bin_dir}}/tailscale {{brew_bin}}/tailscale
    sudo cp {{bin_dir}}/tailscaled {{brew_bin}}/tailscaled
    @echo "Installed to {{brew_bin}}. Run `just revert` to restore official binaries."

# Restore the official Homebrew binaries (undo `install`).
revert:
    brew reinstall tailscale
    @echo "Restored official Homebrew tailscale binaries. Restart the daemon if needed."

# Stop the Homebrew-managed tailscaled service.
stop:
    sudo brew services stop tailscale
    @echo "Stopped tailscale service"

# Start the Homebrew-managed tailscaled service.
start:
    sudo brew services start tailscale
    @echo "Started tailscale service"

# Restart the Homebrew service (picks up a newly installed binary).
restart:
    sudo brew services restart tailscale
    @echo "Restarted tailscale service"

# --- Manual daemon recipes: use ONLY if you run tailscaled by hand, not via brew services ---

# Stop a manually-launched tailscaled.
stop-manual:
    -sudo pkill -x tailscaled
    @sleep 1
    @echo "Stopped tailscaled (manual)"

# Start tailscaled manually in the background, logging to /var/log/tailscaled.log.
start-manual:
    sudo sh -c 'nohup {{brew_bin}}/tailscaled --state={{state_file}} --socket={{socket_file}} >> /var/log/tailscaled.log 2>&1 &'
    @sleep 2
    @echo "Started tailscaled manually (logging to /var/log/tailscaled.log)"

# Restart a manually-launched tailscaled (stop-manual + start-manual).
restart-manual: stop-manual start-manual

# Full cycle: build, install, restart.
deploy: build install restart

# Check whether tailscaled is running and show tailscale status.
status:
    @ps aux | grep tailscaled | grep -v grep || echo "tailscaled not running"
    @echo ""
    {{brew_bin}}/tailscale status

# Show recent tailscaled logs (the start-manual recipe writes /var/log/tailscaled.log).
logs:
    @tail -50 /var/log/tailscaled.log 2>/dev/null || echo "No /var/log/tailscaled.log — brew-services logs live elsewhere (see: brew services info tailscale)"

# Follow the manual tailscaled log live (/var/log/tailscaled.log).
logs-follow:
    sudo tail -f /var/log/tailscaled.log

# Show the /etc/resolver files this fix writes (proof MagicDNS is wired up).
dns-check:
    @echo "=== /etc/resolver files ==="
    @ls -la /etc/resolver/ 2>/dev/null || echo "No resolver directory"
    @echo ""
    @for f in /etc/resolver/*; do echo "--- $$f ---"; cat "$$f" 2>/dev/null; done

# Test MagicDNS resolution against the local listener on the default port 5533.
dns-test HOST:
    # If 5533 was unavailable, the listener uses an ephemeral port — run
    # `just dns-check` to see the actual port written to the resolver files.
    @echo "Testing DNS for {{HOST}} via the local listener (127.0.0.1:5533)..."
    dig @127.0.0.1 -p 5533 {{HOST}} +short

# Remove build artifacts.
clean:
    rm -rf {{bin_dir}}
    @echo "Cleaned {{bin_dir}}"
