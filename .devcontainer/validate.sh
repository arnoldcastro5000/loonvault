#!/bin/bash
# Validates that the running devcontainer matches docs/devcontainer.md.
# Run inside the container as the node user. Exits 0 if all checks pass.
set -uo pipefail

PASS=0
FAIL=0

pass() { echo "  PASS  $1"; ((PASS++)); }
fail() { echo "  FAIL  $1"; ((FAIL++)); }

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

check_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$desc"
  else
    fail "$desc (got: '$actual', want: '$expected')"
  fi
}

check_json() {
  local desc="$1" file="$2" query="$3" expected="$4"
  local actual
  actual=$(jq -r "$query" "$file" 2>/dev/null)
  check_eq "$desc" "$actual" "$expected"
}

# ─── User & binaries ────────────────────────────────────────────────────────

echo "User & binaries"
check_eq "Running as node user" "$(whoami)" "node"
check "claude binary at ~/.local/bin/claude" test -f ~/.local/bin/claude
check "claude resolves on PATH" which claude

# ─── Packages ────────────────────────────────────────────────────────────────

echo ""
echo "Packages"
for pkg in git gh zsh fzf sudo iptables ipset iproute2 dnsutils aggregate jq nano vim bubblewrap socat; do
  check "Package: $pkg" dpkg -s "$pkg"
done

# ─── Environment variables (present) ─────────────────────────────────────────

echo ""
echo "Environment variables (present)"
check_eq "NODE_OPTIONS" "${NODE_OPTIONS:-}" "--max-old-space-size=4096"
check_eq "CLAUDE_CONFIG_DIR" "${CLAUDE_CONFIG_DIR:-}" "/home/node/.claude"
check_eq "POWERLEVEL9K_DISABLE_GITSTATUS" "${POWERLEVEL9K_DISABLE_GITSTATUS:-}" "true"

# ─── Environment variables (absent) ──────────────────────────────────────────

echo ""
echo "Environment variables (absent)"
check_eq "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC not set" "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" ""
check_eq "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB not set" "${CLAUDE_CODE_SUBPROCESS_ENV_SCRUB:-}" ""

# ─── Managed settings ────────────────────────────────────────────────────────

echo ""
echo "Managed settings (/etc/claude-code/managed-settings.json)"
MANAGED=/etc/claude-code/managed-settings.json
check "File exists" test -f "$MANAGED"
check_json "sandbox.enabled = true"                  "$MANAGED" ".sandbox.enabled"                  "true"
check_json "sandbox.enableWeakerNestedSandbox = true" "$MANAGED" ".sandbox.enableWeakerNestedSandbox" "true"
check_json "sandbox.failIfUnavailable = false"        "$MANAGED" ".sandbox.failIfUnavailable"        "false"
check_json "sandbox.allowUnsandboxedCommands = false" "$MANAGED" ".sandbox.allowUnsandboxedCommands" "false"

# ─── Firewall script ─────────────────────────────────────────────────────────

echo ""
echo "Firewall script"
check "init-firewall.sh exists"     test -f /usr/local/bin/init-firewall.sh
check "init-firewall.sh executable" test -x /usr/local/bin/init-firewall.sh
check "node has passwordless sudo for init-firewall.sh" sudo -n -l /usr/local/bin/init-firewall.sh

# ─── Mounts & volumes ────────────────────────────────────────────────────────

echo ""
echo "Mounts & volumes"
check "/home/node/.claude exists (named volume)"    test -d /home/node/.claude
check "/commandhistory exists (named volume)"        test -d /commandhistory
check "firewall-extra-domains.txt accessible (bind mount)" test -f /workspace/.devcontainer/firewall-extra-domains.txt
check "firewall-extra-domains.txt is read-only" bash -c '! touch /workspace/.devcontainer/firewall-extra-domains.txt 2>/dev/null'

# ─── Project-level settings ──────────────────────────────────────────────────

echo ""
echo "Project-level settings (.claude/settings.local.json)"
SETTINGS=/workspace/.claude/settings.local.json
check "File exists" test -f "$SETTINGS"
check "excludedCommands contains 'gh *'"  jq -e '.sandbox.excludedCommands | contains(["gh *"])'  "$SETTINGS"
check "excludedCommands contains 'git *'" jq -e '.sandbox.excludedCommands | contains(["git *"])' "$SETTINGS"
check_json "sandbox.allowUnsandboxedCommands = false" "$SETTINGS" ".sandbox.allowUnsandboxedCommands" "false"

# ─── No cloud credential tooling ─────────────────────────────────────────────

echo ""
echo "No cloud credential tooling"
check "gcloud not on PATH" bash -c '! which gcloud'
check "aws not on PATH"    bash -c '! which aws'

# ─── Firewall (network tests — slowest) ──────────────────────────────────────

echo ""
echo "Firewall (network)"
check "example.com is blocked"      bash -c '! curl --connect-timeout 5 https://example.com'
check "api.github.com is reachable" curl --connect-timeout 5 https://api.github.com/zen

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────"
echo "$PASS passed, $FAIL failed"
echo "────────────────────────────────────"

[ "$FAIL" -eq 0 ]
