# agent-team

Tooling to stand up and run an **always-on cluster of Mac minis** that host
long-running [Claude Code](https://claude.com/claude-code) sessions, reachable
securely from one machine you carry — the **MASTER**.

Clone the repo onto a fresh Mac mini, run one script, answer a few prompts, and
the machine becomes a hardened, always-on node you can `ssh` into from anywhere.

```bash
git clone git@github.com:lumirity/agent-team.git
cd agent-team
./agent_team_machine_setup.sh          # interactive wizard
```

---

## The model

You SSH **from** the MASTER **into** the NODEs. A machine can connect only when
**all three** of these are true — defense in depth, so losing any one is not enough:

| # | Condition | Enforced by |
|---|-----------|-------------|
| 1 | It's in your private **Tailscale** network (tailnet) | WireGuard device authorization — only devices you approve can even reach a node |
| 2 | It holds the cluster's **authorized SSH key** | Key-only OpenSSH; the wizard creates & installs the key for you |
| 3 | It logs in as your **user account** (`amy`) | `AllowUsers` + macOS SSH access group |

On top of that: persistent work uses **tmux** (sessions survive disconnects) and
resilient links use **autossh** (auto-reconnect). See `../SSH_SETUP.md` for the
full connection guide.

```
   MASTER  ──WireGuard (Tailscale)──►  NODE: nora-2, liger-3, ...
   (you SSH from)                       (always-on, key-only sshd, tmux + claude)
```

---

## What's in this repo — and what is NOT

**In the repo (all non-secret, safe to push):**

| File | Purpose |
|------|---------|
| `agent_team_machine_setup.sh` | The interactive installer (node + master roles) |
| `authorized_clients` | Shared allow-list of **public** keys (public keys can't authenticate by themselves) |
| `cluster.conf` | Manifest of machines (`NUMBER\|NAME\|LOCAL\|date`) |
| `.gitignore` | Blocks private keys from ever being committed |
| `README.md` | This file |

**NEVER in the repo (private keys):**

- The cluster **access private key** and any node private keys.
- They live **outside** the repo in `~/.config/agent-team/keys/` (override with
  `$AGENT_TEAM_SECRETS` or `--secrets-dir`), plus the usual `~/.ssh/`.
- `.gitignore` blocks `keys/`, `*_ed25519`, `*.pem`, `*.key`, etc. as a backstop.

> 🔒 **Make the GitHub repo private.** Even though it holds no secrets, it
> describes your infrastructure. Private repo + your own GitHub SSH key + 2FA.

---

## Where private keys are stored (and how to keep them safe)

| Key | Lives on | Path | In repo? | Backup |
|-----|----------|------|:--------:|--------|
| **Cluster access key** (the master's identity) | the MASTER | `~/.config/agent-team/keys/agentteam_access_ed25519`, installed to `~/.ssh/agentteam_access_ed25519` | ❌ never | Password manager (1Password/Bitwarden) **or** encrypted USB |
| **Node identity key** (mini↔mini mesh) | each NODE | `~/.ssh/id_ed25519` | ❌ never | Not needed — regenerable per node |
| **Public** halves of the above | everywhere | `authorized_clients` (repo) + each node's `~/.ssh/authorized_keys` | ✅ yes | git |

Guidance:

- **The access private key is your master credential.** Anyone who has it can
  reach the cluster. Treat it like a password: store the canonical copy in a
  password manager or on an encrypted USB; let it exist only on the MASTER's
  encrypted disk (keep **FileVault on**).
- **Nodes never hold a private *client* key** — only public keys. So a stolen
  node cannot be used to log into the other nodes' accounts.
- **Want it un-exfiltratable?** Generate the access key in the Secure Enclave
  (e.g. the [Secretive](https://github.com/maxgoedjen/secretive) app, or a
  hardware security key with `ssh-keygen -t ed25519-sk`) so the private key can
  never leave the machine. Then add only its public key to `authorized_clients`.
- **Rotate / revoke** by deleting the key, removing its line from
  `authorized_clients`, committing, and re-running the installer on each node.

---

## Setup

### 0. One-time: publish the repo (do this once, from the first machine)

```bash
cd ~/agent-team
git init -b main
git add .
git status                       # ← confirm NO *_ed25519 / keys/ files are staged
git commit -m "agent-team cluster tooling"
git remote add origin git@github.com:lumirity/agent-team.git
git push -u origin main
```

### 1. Set up the MASTER (the machine you SSH from)

```bash
git clone git@github.com:lumirity/agent-team.git && cd agent-team
./agent_team_machine_setup.sh --role master
```

This joins the tailnet, **creates the cluster access key** (if it doesn't exist),
installs it into your `~/.ssh`, adds its public key to `authorized_clients`, and
writes `ssh <name>` shortcuts. Then publish the updated public allow-list:

```bash
git add authorized_clients cluster.conf && git commit -m "enroll master" && git push
```

> Back up `~/.config/agent-team/keys/agentteam_access_ed25519` to your password
> manager now. On a **second** master later, restore that file to the same path
> *before* running, and the wizard will reuse it instead of minting a new one.

### 2. Set up each NODE (a Mac mini)

On the fresh mini:

```bash
git clone git@github.com:lumirity/agent-team.git && cd agent-team
./agent_team_machine_setup.sh --role node --name Liger --number 3
# (or just ./agent_team_machine_setup.sh and answer the prompts)
```

The node installs the public `authorized_clients` (so it trusts the master),
enables hardened key-only SSH, applies always-on power + firewall tuning, joins
the tailnet, and registers itself in `cluster.conf`. Then share the update:

```bash
git add authorized_clients cluster.conf && git commit -m "add Liger #3" && git push
```

Approve the new device in the Tailscale admin console. Re-run on existing nodes
(after `git pull`) to refresh their peer shortcuts.

---

## Daily use

From the MASTER (or any node):

```bash
ssh nora            # shortcuts were written into ~/.ssh/config for every machine
ssh liger
```

Resilient + persistent Claude Code (add to `~/.zshrc` on the MASTER):

```bash
alias nora='autossh -M 0 -t nora "tmux new -A -s claude"'
```

`autossh` keeps the link alive across Wi-Fi drops; `tmux new -A -s claude` always
drops you into the same persistent session. Detach with `Ctrl-b d` (Claude keeps
running on the node); reattach later with the same command. Full details and
troubleshooting: `../SSH_SETUP.md`.

---

## Secure-setup checklist

- [ ] GitHub repo is **private**; pushed over SSH (`git@`), GitHub 2FA on.
- [ ] `git status` never shows `*_ed25519` / `keys/` — `.gitignore` covers them.
- [ ] Access private key backed up to a password manager / encrypted USB.
- [ ] **FileVault on** for every machine (it is, on Nora).
- [ ] Tailscale: **disable key expiry** for always-on nodes; consider **tailnet
      lock** and an **ACL** limiting who reaches port 22.
- [ ] Nodes expose **no** SSH to the public internet (only via the tailnet);
      app firewall + stealth mode are enabled by the installer.

## Revoking access

1. Delete the offending key from `~/.config/agent-team/keys/` (and the master's `~/.ssh`).
2. Remove its line from `authorized_clients`; `git commit && git push`.
3. `git pull` + re-run the installer on each node (rewrites `authorized_keys`).
4. Delete the device in the Tailscale admin console.

(Removing the device from Tailscale alone already blocks network reach; do both
for full revocation.)

---

## Command reference

```
./agent_team_machine_setup.sh [options]

  --role node|master    node = a mini you SSH INTO; master = machine you SSH FROM
  --name <Name>         (node) display name, e.g. Liger
  --number <N>          (node) machine number, e.g. 3
  --user <user>         login/SSH user to allow            (default: amy)
  --login-server <url>  use a self-hosted Headscale instead of Tailscale's cloud
  --secrets-dir <path>  where PRIVATE keys live   (default: ~/.config/agent-team)
  --no-tailscale        LAN-only (skip Tailscale)
  --interactive | --non-interactive
  --force               proceed despite an empty allow-list (lockout risk)
  --dry-run             print actions; change nothing
```

Current cluster: see `cluster.conf` (Nora is mini #2).
