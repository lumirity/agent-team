# agent-team

Tooling to stand up and run an **always-on cluster of Mac minis** that host
long-running [Claude Code](https://claude.com/claude-code) sessions, reachable
securely from one machine you control — the **MASTER**.

Clone the repo onto a machine, run one script, answer a few prompts, and the
machine joins the cluster — hardened, always-on, and registered for everyone else
to see.

```bash
git clone git@github.com:lumirity/agent-team.git
cd agent-team
./agent_team_machine_setup.sh            # interactive wizard
```

---

## How this repo works (the shared registry)

**This repo registers the machines in the cluster and holds the shared state that
all nodes and the master need to reach and trust each other.** It is the cluster's
single source of truth — and it stores **only non-secret data**:

| File | Shared state it holds |
|------|-----------------------|
| `authorized_clients` | The **public-key allow-list** — every key permitted to SSH into any node (the master's access key + each node's identity key). Public keys can't authenticate on their own, so this is not secret. |
| `cluster.conf` | The **machine manifest** — one line per machine (`NUMBER\|NAME\|LOCAL\|date`), i.e. the roster. |
| `agents/<name>.env` | The **shared agent-state overlay** — one file per machine holding its `AGENT_TEAM_*` config (machine id, role, Linear assignee, and any custom keys). Read with `get_agent_config.sh`. Non-secret. |
| `get_agent_config.sh` | Accessor that resolves and prints any machine's config (see *Shared agent state* below). |
| `agent_team_machine_setup.sh`, `.gitignore`, `README.md` | The tooling and docs. |

Every time you run the setup script on a machine, it:

1. **pulls** the latest `authorized_clients` + `cluster.conf` from the repo,
2. **registers** this machine — adds its key to the allow-list and (for nodes)
   its entry to the manifest, and
3. **pushes** the updated state back.

So the repo is how machines converge on a single, consistent allow-list and
roster without you copying keys around by hand. **Private keys never enter the
repo** — they live outside it (see *Where private keys live* below), and
`.gitignore` is a backstop.

> 🔒 **Keep the GitHub repo private.** It holds no secrets, but it maps your
> infrastructure. Private repo + your GitHub SSH key + 2FA.

---

## The security model

You SSH **from** the MASTER **into** the NODEs. A machine can connect only when
**all three** are true — lose any one and access fails:

| # | Condition | Enforced by |
|---|-----------|-------------|
| 1 | It's in your private **Tailscale** network | WireGuard device authorization — only devices you approve can even reach a node |
| 2 | It holds the cluster's **authorized SSH key** | Key-only OpenSSH; keys are created & installed for you |
| 3 | It logs in as your **user account** (`amy`) | `AllowUsers` + macOS SSH access group |

Persistent work runs in **tmux** (survives disconnects); resilient links use
**autossh** (auto-reconnect). Full connection guide: `../SSH_SETUP.md`.

---

## What this adds beyond Tailscale

Tailscale already gives you condition **(1)** — the encrypted network — and, if
you enable **Tailscale SSH** (`tailscale up --ssh`), it can also broker **(2)**
and **(3)** using your tailnet identity, with *no SSH keys or `authorized_keys`
at all*. So if all you want is *to connect*, `tailscale up --ssh` on each mini is
nearly enough.

What this repo adds on top of Tailscale:

| | Tailscale alone | This repo adds |
|---|---|---|
| Encrypted reachability | ✅ | — |
| SSH auth | ✅ with Tailscale SSH | key-only OpenSSH as a defense-in-depth alternative |
| **Always-on host tuning** (no-sleep, auto-restart, firewall, hostname) | ❌ | ✅ |
| **tmux + autossh** for persistent long-running sessions | ❌ | ✅ |
| **`ssh <name>` shortcuts** | partial (MagicDNS names) | ✅ |
| **Shared roster + git registry** of machines/keys | ❌ | ✅ |

In short: the durable value here is the **always-on Claude Code host setup,
persistent-session tooling, and the cluster roster/shortcuts** — plus key-only
SSH for anyone who doesn't want to trust Tailscale's control plane for auth. If
you'd rather lean fully on Tailscale for auth, run with `--no-tailscale` off and
use Tailscale SSH; the SSH-key machinery then becomes optional.

---

## What the setup script does

Run `./agent_team_machine_setup.sh` (wizard) or pass flags. In order, it:

1. **Installs packages** — `git`, `autossh`, `tmux`, `mosh` (+ `tailscale`).
2. **Sets up GitHub access for this machine** — generates a dedicated SSH key,
   configures `~/.ssh/config`, pins GitHub's host key, then **pauses and waits**
   for you to add the key at <https://github.com/settings/ssh/new> (the public
   key is copied to your clipboard). It re-checks until auth succeeds — needed so
   the machine can sync the shared state.
3. **Pulls** the latest shared state from the repo.
4. **Sets up the machine for its role** (you choose **node** or **master**):
   - **node** — names it `<name>-<number>`, enables **key-only hardened SSH**,
     applies **always-on power + firewall** tuning, generates this node's
     identity key, installs the allow-list into `~/.ssh/authorized_keys`, writes
     a tmux config, and records itself in `cluster.conf`.
   - **master** — creates (or reuses) the **cluster access key**, then **pauses
     and requires you to back it up** (local copy **and** password manager /
     encrypted USB) before continuing, installs it locally, and writes
     `ssh <name>` shortcuts for every machine.
5. **Joins Tailscale** (or a self-hosted Headscale via `--login-server`).
6. **Stamps this machine's identity** — writes `~/.config/agent-team/identity`
   and sources it from `~/.zshrc`, so `$AGENT_TEAM_MACHINE` (and `_NAME`,
   `_NUMBER`, `_ROLE`) is set in every shell. Also mirrors the same config into
   the repo as `agents/<name>.env` so other machines can look it up.
7. **Self-heals keys** — if an SSH key was deleted or corrupted, it's backed up,
   regenerated, and its stale allow-list entry is replaced with the new one.
8. **Commits & pushes** the updated `authorized_clients`, `cluster.conf`, and
   `agents/` — but **asks first** (in interactive mode) before committing, lets
   you **sign** the commit (`Signed by <name>`), and tags it with a
   `Machine: <name>` trailer so the push is attributable to this box.

It is **idempotent** — safe to re-run anytime (e.g. to recover a lost key or
refresh shortcuts).

---

## Where private keys live (and how to keep them safe)

| Key | Lives on | Path | In repo? | Backup |
|-----|----------|------|:--------:|--------|
| **Cluster access key** (the master's credential) | the MASTER | `~/.config/agent-team/keys/agentteam_access_ed25519`, installed to `~/.ssh/` | ❌ never | **Password manager / encrypted USB** (the script makes you do this) |
| **Node identity key** (mini↔mini) | each NODE | `~/.ssh/id_ed25519` | ❌ never | Not needed — regenerable (self-healing) |
| **GitHub key** (per machine) | each machine | `~/.ssh/github_ed25519` | ❌ never | Not needed — regenerable, re-add to GitHub |
| **Public** halves | everywhere | `authorized_clients` (repo) + nodes' `authorized_keys` | ✅ yes | git |

- The **access private key is the master credential.** Anyone holding it can
  reach the cluster. The script pauses so you store it in a password manager
  *and* keep the local copy on a FileVault-encrypted disk. Lose it → re-key the
  cluster; leak it → revoke (below).
- **Nodes never hold a private *client* key** — only public keys — so a stolen
  node can't log into the others.
- Want it un-exfiltratable? Generate the access key in the Secure Enclave (e.g.
  the [Secretive](https://github.com/maxgoedjen/secretive) app) or on a hardware
  key (`ssh-keygen -t ed25519-sk`); add only its public key to `authorized_clients`.

Override the secrets location with `--secrets-dir <path>` or `$AGENT_TEAM_SECRETS`.

---

## Setup

### 0. One-time: publish the repo (from the first machine)

```bash
cd ~/agent-team
git init -b main
git add .
git status                       # ← confirm NO *_ed25519 / keys/ files are staged
git commit -m "agent-team cluster tooling"
git remote add origin git@github.com:lumirity/agent-team.git
git push -u origin main
```

### 1. The MASTER (the machine you SSH from)

```bash
git clone git@github.com:lumirity/agent-team.git && cd agent-team
./agent_team_machine_setup.sh --role master
```

Follow the prompts: add the machine's GitHub key when asked, then **back up the
cluster access key** when it pauses. It installs the key locally, writes your
`ssh <name>` shortcuts, and pushes the allow-list automatically.

### 2. Each NODE (a Mac mini)

```bash
git clone git@github.com:lumirity/agent-team.git && cd agent-team
./agent_team_machine_setup.sh --role node --name Liger --number 3
# (or just ./agent_team_machine_setup.sh and answer the prompts)
```

It pulls the latest allow-list, hardens the machine, joins the tailnet, registers
itself, and pushes. Approve the new device in the Tailscale admin console. Set up
the **master first**, so its access key is already in the allow-list nodes pull.

---

## Daily use

### Reaching the child machines (from the orchestrator/MASTER)

Setup writes an `ssh <name>` shortcut into `~/.ssh/config` for every machine in
`cluster.conf`, each pointing at the node's tailnet name and using the cluster
access key. The **current cluster** (see `cluster.conf`) is:

| # | Name | Tailnet host | Reach it with |
|---|------|--------------|---------------|
| 1 | Elga | `elga-1` | `ssh elga` |
| 2 | Nora | `nora-2` | `ssh nora` |

```bash
ssh elga                     # open a shell on Elga (mini #1)
ssh nora                     # open a shell on Nora (mini #2)
ssh amy@elga-1               # the long form the shortcut expands to

ssh elga 'hostname; uptime'  # run a one-off command without an interactive shell
ssh nora "cd ~/dev/agent-team && git pull"   # e.g. refresh a node's checkout
```

> **Prerequisite — the tailnet must be up.** The shortcuts dial each node by its
> Tailscale MagicDNS name (`elga-1`, `nora-2`), so this box has to be signed in to
> the same tailnet. Check with `tailscale status`; if it says the service isn't
> running, start it (menu-bar app, or `sudo tailscale up`) and approve this device
> in the admin console. On LAN-only setups (`--no-tailscale`), reach nodes by their
> `.local` name or IP instead.

### Persistent, resilient Claude Code sessions

Run Claude Code inside **tmux** on the node so it survives disconnects, and dial in
over **autossh** so the link auto-reconnects. Add aliases to `~/.zshrc` on the
MASTER — one per node:

```bash
alias elga='autossh -M 0 -t elga "tmux new -A -s claude"'
alias nora='autossh -M 0 -t nora "tmux new -A -s claude"'
```

`autossh` keeps the link alive; `tmux new -A -s claude` attaches the `claude`
session if it exists or creates it otherwise, so you always land in the same place.
Detach with `Ctrl-b d` — Claude keeps running on the node — and re-run the alias to
reattach. Details and troubleshooting: `../SSH_SETUP.md`.

### Fan out to every node

```bash
# Same command on all registered nodes (skips the master's own line):
for n in $(awk -F'|' '{print tolower($2)}' cluster.conf); do
  echo "== $n =="; ssh "$n" 'uptime'
done
```

Look up any machine's shared config (e.g. who its Linear tasks route to) with
`./get_agent_config.sh --name elga` — see **Shared agent state** above.

---

## Shared agent state

Each machine has a stable identity you can attribute work to — **without** giving
it its own unix account. The setup script writes it in two places:

- **Local, private** — `~/.config/agent-team/identity`, sourced from `~/.zshrc`,
  so every shell on the box has `$AGENT_TEAM_MACHINE` (plus `_NAME`, `_NUMBER`,
  `_ROLE`). Use it in scripts, prompts, or to attribute work to "this machine".
- **Shared, committed** — `agents/<name>.env` in the repo, so *any* machine can
  look up *any other* machine's config after a `git pull`.

Read it from anywhere with **`get_agent_config.sh`**:

```bash
./get_agent_config.sh                          # THIS machine
./get_agent_config.sh --name nora              # a specific machine, as key=value
./get_agent_config.sh --name nora --key LINEAR_ASSIGNEE   # one value (prefix optional)
eval "$(./get_agent_config.sh --name nora --export)"      # load into your shell
./get_agent_config.sh --name nora --json       # JSON object
./get_agent_config.sh --list                   # every known machine
```

It merges three sources, **later wins**: `cluster.conf` → `agents/<name>.env` →
the local `~/.config/agent-team/identity` (only when you query the current box).
It *sources* only the local identity file (which this box wrote); shared
`agents/*.env` overlays are parsed, never executed.

**Extensible keys.** Overlays accept any `AGENT_TEAM_*` key, and they all surface
in the output. Add your own (e.g. `AGENT_TEAM_GPU=none`) by editing the file and
committing it.

**Routing Linear tasks per machine.** Store who a machine's tasks go to in
`AGENT_TEAM_LINEAR_ASSIGNEE` — set it with `--linear <assignee>` at setup (or the
interactive prompt), or edit `agents/<name>.env`. Then fetch it when assigning:

```bash
./get_agent_config.sh --name nora --key LINEAR_ASSIGNEE
```

Commits pushed from a machine carry a `Machine: <name>` trailer, so cluster
changes are traceable to the box that made them.

---

## Troubleshooting: `ssh <node>` → `Permission denied (publickey)`

**Symptom.** From the master, `ssh elga` (or any node) fails with
`Permission denied (publickey)`, even though `tailscale status` shows the node
online and `ssh -v` shows the connection *is established* and the access key *is
offered*. The network is fine; the node just doesn't trust the key yet.

**Cause — allow-list drift.** A node only trusts the keys that were in
`authorized_clients` **at the time it last ran the installer**. If a client key was
added *after* that — most commonly the **master/orchestrator was set up after the
nodes already existed**, so its access key didn't exist when they registered — the
node's `~/.ssh/authorized_keys` never received it. The master offers the right key;
the node has no matching line; sshd denies it. (Verify the ordering with
`git log --oneline -- authorized_clients` — if the `agentteam-access-*` line landed
in a commit *newer* than a node's `register node:` commit, that node is stale.)

> **Rule for any new client key.** Whenever a key is added to `authorized_clients`
> — a new/re-keyed master, or any additional client — **every existing node must
> re-pull and re-run the installer** to start trusting it. Setting the master up
> *first* avoids this; when that isn't possible, use the fix below.

**Why it can't be fixed from the master.** SSH is the broken path, key-only
hardening means no password fallback, and the master holds only the *access* key
(not a node *identity* key), so it can't hop in via another node either. **The fix
must run on each node directly** — physical access, Screen Sharing/VNC, or any
existing terminal/tmux session on that box (e.g. a fresh Claude Code session
running *on the node itself*).

### The fix — run these ON the node (not over SSH from the master)

Each node re-pulls the updated allow-list and re-runs its installer, which rewrites
`~/.ssh/authorized_keys` from `authorized_clients`. It's idempotent.

**On Elga (mini #1):**

```bash
cd ~/agent-team
git pull
./agent_team_machine_setup.sh --role node --name Elga --number 1
```

**On Nora (mini #2):**

```bash
cd ~/agent-team
git pull
./agent_team_machine_setup.sh --role node --name Nora --number 2
```

**Any future node** — substitute its own name/number (a node always knows its own
identity via `./get_agent_config.sh --key NAME` and `--key NUMBER`, or
`$AGENT_TEAM_NAME` / `$AGENT_TEAM_NUMBER`):

```bash
cd ~/agent-team && git pull
./agent_team_machine_setup.sh --role node --name "$AGENT_TEAM_NAME" --number "$AGENT_TEAM_NUMBER"
```

**Minimal alternative** (skips the full wizard — just re-installs the allow-list;
de-dupe-safe because the installer merges by key body):

```bash
cd ~/agent-team && git pull
grep agentteam-access authorized_clients >> ~/.ssh/authorized_keys
```

After the node applies this, `ssh <node>` from the master authenticates. If it
still fails, confirm the node is on the tailnet (`tailscale status`) and that the
key the master offers (`ssh-keygen -lf ~/.ssh/agentteam_access_ed25519.pub`)
matches an `agentteam-access-*` line in the node's `~/.ssh/authorized_keys`.

---

## Recovering a lost or corrupted key

Just re-run the script on that machine:

```bash
./agent_team_machine_setup.sh --role node --name Liger --number 3
```

If `~/.ssh/id_ed25519` (node) or the access key (master) is missing or unreadable,
it's backed up (`*.corrupt.<timestamp>`), regenerated, the **stale allow-list
entry is replaced**, and the change is pushed — so peers trust the new key. (A
master whose access key is truly gone with no backup must re-key: a fresh key is
minted and pushed; re-run nodes to pick it up.)

## Revoking access

1. Remove the key's line from `authorized_clients`; `git commit && git push`.
2. `git pull` + re-run the installer on each node (rewrites `authorized_keys`).
3. Delete the device in the Tailscale admin console.

(Removing the Tailscale device alone already blocks network reach; do both for
full revocation.)

---

## Command reference

```
./agent_team_machine_setup.sh [options]

  --role node|master    node = a mini you SSH INTO; master = machine you SSH FROM
  --name <Name>         (node) display name, e.g. Liger
  --number <N>          (node) machine number, e.g. 3
  --user <user>         login/SSH user to allow            (default: amy)
  --sign <name>         sign the registration commit, e.g. --sign "Amy Hua"
  --linear <assignee>   Linear assignee for tasks routed to this machine
  --login-server <url>  use a self-hosted Headscale instead of Tailscale's cloud
  --secrets-dir <path>  where PRIVATE keys live   (default: ~/.config/agent-team)
  --no-tailscale        LAN-only (skip Tailscale)
  --interactive | --non-interactive
  --force               proceed despite an empty allow-list (lockout risk)
  --dry-run             print actions; change nothing
```

```
./get_agent_config.sh [--name <name>] [--key <KEY>] [--export|--json] [--list]
```

Current cluster: see `cluster.conf` (Elga is mini #1, Nora is mini #2).
