# Devcontainer

The LoonVault devcontainer is the isolated environment in which Claude Code runs. Its
purpose is containment: the AI assistant has filesystem access scoped to the repository,
a process sandbox, and an egress firewall, so that a prompt-injection attack has a limited
blast radius (see T-051 in the threat model). **AWS credentials never enter this
environment** — all Terraform and deploy operations run on the developer's host terminal.

This document is the spec that `.devcontainer/validate.sh` checks the running container
against. If you change `.devcontainer/`, update this file and re-run the validator inside
the container:

```bash
bash .devcontainer/validate.sh
```

## Base image and features

- **Base image:** `node:20` (`.devcontainer/Dockerfile`)
- **Devcontainer features** (pinned by digest in `devcontainer-lock.json`):
  - `ghcr.io/anthropics/devcontainer-features/claude-code:1.0` → version 1.0.5
  - `ghcr.io/devcontainers/features/node:1` → version 1.7.1
- **Timezone:** passed in via the `TZ` build arg (defaults to `America/Toronto` from the
  developer's local env)

## User and binaries

- Container runs as the **`node`** user (not root).
- Claude Code installed via `https://claude.ai/install.sh` to `~/.local/bin/claude`;
  `/home/node/.local/bin` is on `PATH`.
- `gitleaks` installed from the latest GitHub release to `/usr/local/bin`.
- `terraform` (pinned **1.9.8**, matching CI's `~1.9` and the stacks' `>= 1.9`) installed from
  `releases.hashicorp.com` to `/usr/local/bin`. For **offline static checks only** (`fmt`,
  `validate`) — see "Intentionally absent" for why apply/plan/init still run on the host.

## Installed packages

Installed via `apt-get` in the Dockerfile:

```
less git procps sudo fzf zsh man-db unzip gnupg2 gh
iptables ipset iproute2 dnsutils aggregate jq nano vim
bubblewrap socat
```

`validate.sh` asserts the presence of: `git gh zsh fzf sudo iptables ipset iproute2
dnsutils aggregate jq nano vim bubblewrap socat`.

### Intentionally absent

- **Terraform `apply`/`plan`/`init`/`destroy`** — not runnable here. The `terraform` binary
  *is* installed (see above), but only for offline static checks (`fmt`, `validate`). AWS
  credentials never enter the devcontainer, so any credentialed/network operation
  (`apply`, `plan`, `init`, `destroy`) runs on the developer's host using short-lived IAM
  Identity Center sessions. (See the comment block in the Dockerfile.)
- **`aws` CLI** and **`gcloud`** — not on `PATH`. `validate.sh` asserts both are absent;
  no cloud credential tooling exists in the container.

## Environment variables

| Variable | Value | Source |
|---|---|---|
| `NODE_OPTIONS` | `--max-old-space-size=4096` | `devcontainer.json` `containerEnv` |
| `CLAUDE_CONFIG_DIR` | `/home/node/.claude` | `devcontainer.json` `containerEnv` |
| `POWERLEVEL9K_DISABLE_GITSTATUS` | `true` | `devcontainer.json` `containerEnv` |
| `DEVCONTAINER` | `true` | Dockerfile `ENV` |
| `SHELL` | `/bin/zsh` | Dockerfile `ENV` |
| `EDITOR` / `VISUAL` | `nano` | Dockerfile `ENV` |

### Intentionally unset

`validate.sh` asserts these are **not** set:

- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`
- `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`

## Managed settings

`/etc/claude-code/managed-settings.json` is copied in as `root:root` (not editable by the
`node` user) and enforces the sandbox policy:

| Setting | Value |
|---|---|
| `sandbox.enabled` | `true` |
| `sandbox.enableWeakerNestedSandbox` | `true` |
| `sandbox.failIfUnavailable` | `false` |
| `sandbox.allowUnsandboxedCommands` | `false` |

## Project-level settings

`/workspace/.claude/settings.local.json` (developer-specific, gitignored) layers on top of
managed settings. `validate.sh` asserts:

- `sandbox.allowUnsandboxedCommands` = `false`
- `sandbox.excludedCommands` contains `gh *` and `git *` (commands that run outside the
  bash sandbox because they need network/git access)

## Mounts and volumes

Declared in `devcontainer.json`:

| Target | Type | Purpose |
|---|---|---|
| `/commandhistory` | named volume | persists bash history across rebuilds |
| `/home/node/.claude` | named volume | persists Claude Code config across rebuilds |
| `/workspace` | bind mount (`localWorkspaceFolder`) | the repository, `consistency=delegated` |
| `/workspace/.devcontainer/firewall-extra-domains.txt` | bind mount, **read-only** | extra egress allowlist entries, edited on the host |
| `/home/node/.config/loonvault/agent.pem` | bind mount, **read-only** | GitHub App (`loonvault-agent`) private key, so the agent can mint short-lived installation tokens (`just gh-token`) to push branches + open PRs |

### GitHub App key — a bounded, deliberate exception

AWS credentials never enter the container (above), but the GitHub App private key is mounted read-only so the agent can push branches and open PRs on its own. This is a deliberate, bounded exception, not a contradiction of the credential-free stance:

- The App's permissions are **Contents/Pull-requests write only — no merge, no Administration**. The `protect-main` ruleset requires a human approval the App cannot self-provide, so the worst a prompt-injection-compromised agent can do is **open a PR a human still has to review and merge** (the T-051 mitigation: all AI changes pass CI + human review before reaching `main`).
- The key is read-only and only usable for this one bounded App; egress is firewall-limited to GitHub, so exfiltration buys an attacker only the same "open a PR" capability the agent already has.
- The host must place the key at `~/.config/loonvault/agent.pem` **before** the container starts (a bind mount whose source is missing will fail or create a directory).

## Container capabilities and startup

- **`runArgs`:** `--cap-add=NET_ADMIN --cap-add=NET_RAW` — required for the firewall to
  manipulate iptables/ipset.
- **`postStartCommand`:** `sudo /usr/local/bin/init-firewall.sh` runs on every container
  start (the `node` user has passwordless sudo for this one script only, via
  `/etc/sudoers.d/node-firewall`).
- **`waitFor`:** `postStartCommand` — the container is not considered ready until the
  firewall is applied.

## Egress firewall

`init-firewall.sh` enforces a default-deny egress policy with an allowlist
(`ipset allowed-domains`). Outbound traffic is rejected unless it matches.

**DNS** is locked to a single resolver (`10.255.255.254`); all other DNS is dropped.
Inbound/outbound SSH is disabled (commented out).

**Allowed destinations:**

- All GitHub IP ranges (fetched from `https://api.github.com/meta`, fields `web`/`api`/`git`)
- `registry.npmjs.org`
- `api.anthropic.com`
- `downloads.claude.ai`
- The detected host network (`/24` of the default route)
- Any domains listed in `firewall-extra-domains.txt`

The script **self-verifies** at the end: it confirms `https://example.com` is blocked and
`https://api.github.com` is reachable, exiting non-zero if either check fails.

To allow an additional domain (e.g., for an MCP server), add it to
`.devcontainer/firewall-extra-domains.txt` on the host and re-run
`sudo /usr/local/bin/init-firewall.sh` inside the container.

## Validation

`.devcontainer/validate.sh` checks the running container against this spec — user,
binaries, packages, env vars (present and absent), managed settings, project settings,
mounts, absence of cloud credential tooling, and live firewall behavior. It exits `0` when
all checks pass. Run it after any change to `.devcontainer/`.
