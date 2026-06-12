#!/bin/bash
# agent_team_machine_setup.sh
# Interactive setup for your always-on Claude Code mini cluster.
#
# A machine can connect ONLY when ALL THREE are true:
#   (1) it is in your private Tailscale network (tailnet)
#   (2) it holds the cluster's authorized SSH key   <-- created & installed FOR you
#   (3) it logs in as your account (default: amy)
#
# Just run it and answer the prompts:
#     ./agent_team_machine_setup.sh
# Or drive it non-interactively:
#     ./agent_team_machine_setup.sh --role node   --name Liger --number 3
#     ./agent_team_machine_setup.sh --role master
#
# Distribution: clone the repo, run the script. The repo is the cluster's shared
# REGISTRY — it carries only NON-secret state (script, PUBLIC allow-list, machine
# manifest). Each run installs git + sets up this machine's GitHub key (pausing
# for you to add it), PULLS the latest shared state, configures the machine, then
# COMMITS+PUSHES its registration so every node/master converges on one roster.
# PRIVATE keys live OUTSIDE the repo in $AGENT_TEAM_SECRETS (default
# ~/.config/agent-team) and are NEVER pushed.
#
# Self-healing: deleted/corrupted SSH keys are regenerated and re-registered.
# Idempotent. Privileged steps use sudo (you are prompted once).
set -euo pipefail

# ------------------------------------------------------------------ defaults --
ROLE="" ; NAME="" ; NUMBER="" ; SIGNER=""
LOGIN_USER="$(whoami)"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS_FILE="$SELF_DIR/authorized_clients"          # shared PUBLIC-key allow-list (in repo)
CLUSTER_FILE="$SELF_DIR/cluster.conf"             # shared machine manifest (in repo)
# Private key material lives OUTSIDE the repo so it can never be committed:
SECRETS_DIR="${AGENT_TEAM_SECRETS:-$HOME/.config/agent-team}"
KEYS_DIR="$SECRETS_DIR/keys"                       # holds the managed access key (NOT in repo)
ACCESS_PRIV="$KEYS_DIR/agentteam_access_ed25519"   # THE cluster access key (private)
ACCESS_PUB="$ACCESS_PRIV.pub"
NODE_KEY="$HOME/.ssh/id_ed25519"                   # this node's identity (peer mesh)
MASTER_KEY="$HOME/.ssh/agentteam_access_ed25519"   # access key installed on the MASTER
HARDEN_FILE="/etc/ssh/sshd_config.d/200-agent-team-hardening.conf"
SSH_CFG="$HOME/.ssh/config"
MARK_BEGIN="# >>> agent-team cluster (managed) >>>"
MARK_END="# <<< agent-team cluster (managed) <<<"
DO_TAILSCALE=1 ; DRY_RUN=0 ; FORCE=0 ; INTERACTIVE="auto" ; LOGIN_SERVER=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]
Runs an interactive wizard by default. Flags below skip the questions.

  --role node|master   node = a mini you SSH INTO; master = machine you SSH FROM
  --name <Name>        (node) display name, e.g. Liger
  --number <N>         (node) machine number, e.g. 3
  --user <user>        login/SSH user to allow         (default: $LOGIN_USER)
  --sign <name>        sign the registration commit, e.g. --sign "Amy Hua"
  --login-server <url> use a self-hosted Headscale instead of Tailscale's cloud
  --keys-file <path>   shared allow-list                (default: $KEYS_FILE)
  --cluster-file <path> shared manifest                 (default: $CLUSTER_FILE)
  --secrets-dir <path> where PRIVATE keys live          (default: $SECRETS_DIR)
  --no-tailscale       skip Tailscale (LAN-only)
  --interactive        force the wizard
  --non-interactive    never prompt (use flags/defaults)
  --force              proceed despite an empty allow-list (lockout risk)
  --dry-run            print actions; change nothing
  -h, --help           this help
USAGE
}

# -------------------------------------------------------------------- parse ---
while [ $# -gt 0 ]; do
  case "$1" in
    --role)          ROLE="$2"; shift 2;;
    --name)          NAME="$2"; shift 2;;
    --number)        NUMBER="$2"; shift 2;;
    --user)          LOGIN_USER="$2"; shift 2;;
    --sign)          SIGNER="$2"; shift 2;;
    --login-server)  LOGIN_SERVER="$2"; shift 2;;
    --keys-file)     KEYS_FILE="$2"; shift 2;;
    --cluster-file)  CLUSTER_FILE="$2"; shift 2;;
    --secrets-dir)   SECRETS_DIR="$2"; shift 2;;
    --no-tailscale)  DO_TAILSCALE=0; shift;;
    --interactive)   INTERACTIVE=1; shift;;
    --non-interactive) INTERACTIVE=0; shift;;
    --force)         FORCE=1; shift;;
    --dry-run)       DRY_RUN=1; shift;;
    -h|--help)       usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1;;
  esac
done

[ "$(id -u)" -ne 0 ] || { echo "ERROR: run as your normal user (it will sudo when needed), not root." >&2; exit 1; }

# Recompute private-key paths in case --secrets-dir changed SECRETS_DIR.
KEYS_DIR="$SECRETS_DIR/keys"
ACCESS_PRIV="$KEYS_DIR/agentteam_access_ed25519"
ACCESS_PUB="$ACCESS_PRIV.pub"
# Accept friendly aliases for the master role.
case "$ROLE" in client|portable|p) ROLE="master";; esac
GH_KEY="$HOME/.ssh/github_ed25519"                 # this machine's GitHub key
GIT_SYNC=1                                          # pull/push shared state via git

# --------------------------------------------------------- helpers ------------
run()  { echo "  + $*"; [ $DRY_RUN -eq 1 ] || eval "$@"; }
srun() { echo "  + sudo $*"; [ $DRY_RUN -eq 1 ] || sudo bash -c "$*"; }
count_keys() { { grep -vE '^[[:space:]]*#' "$1" 2>/dev/null || true; } | awk 'NF>=2' | wc -l | tr -d ' '; }
say()  { echo "$*" >&2; }
# ask <question> [default] -> echoes the answer on stdout (prompt goes to stderr)
ask() {
  local q="$1" def="${2:-}" ans
  if [ -n "$def" ]; then printf "  %s [%s]: " "$q" "$def" >&2; else printf "  %s: " "$q" >&2; fi
  IFS= read -r ans || ans=""
  echo "${ans:-$def}"
}
askyn() { local a; a="$(ask "$1 (y/n)" "${2:-y}")"; case "$a" in y*|Y*) return 0;; *) return 1;; esac; }
# pause <msg>: in interactive mode, wait for ENTER; otherwise just print and go.
pause() {
  if [ "$INTERACTIVE" = "1" ] && [ $DRY_RUN -eq 0 ]; then
    printf "\n  %s\n  >> Press ENTER to continue once done... " "$1" >&2; IFS= read -r _ || true
  elif [ -n "${1:-}" ]; then echo "  ($1)"; fi
}

# --- key self-healing -------------------------------------------------------
# valid_key <priv>: true only if it's a readable private key we can derive a pub from.
valid_key() { [ -f "$1" ] && ssh-keygen -y -f "$1" >/dev/null 2>&1; }
# ensure_keypair <priv> <comment>: create if missing OR corrupt (deleted/garbled
# keys are backed up and regenerated); always (re)writes a matching .pub carrying
# <comment>. Echoes "new" if it generated one, "ok" if it reused a good one.
ensure_keypair() {
  local priv="$1" comment="$2" body
  [ $DRY_RUN -eq 1 ] && { echo ok; return 0; }
  mkdir -p "$(dirname "$priv")"
  if valid_key "$priv"; then
    body="$(ssh-keygen -y -f "$priv" 2>/dev/null)"; echo "$body $comment" > "$priv.pub"
    chmod 600 "$priv"; chmod 644 "$priv.pub"; echo ok; return 0
  fi
  if [ -e "$priv" ]; then
    local bak="$priv.corrupt.$(date +%s)"; mv "$priv" "$bak" 2>/dev/null || true
    echo "    ! $priv was missing/unreadable — backed up to $(basename "$bak"), regenerating." >&2
  fi
  rm -f "$priv.pub"
  ssh-keygen -t ed25519 -a 100 -N '' -C "$comment" -f "$priv" >/dev/null
  chmod 600 "$priv"; chmod 644 "$priv.pub"; echo new
}
# allowlist_put <pubfile> <comment_regex>: drop any existing allow-list line whose
# comment matches the regex (so a rotated/regenerated key replaces its old entry),
# then append the new pub and de-dupe by key body. Keeps comment lines intact.
allowlist_put() {
  local pub="$1" cre="$2" tmp
  [ $DRY_RUN -eq 1 ] && return 0
  touch "$KEYS_FILE"; tmp="$(mktemp)"
  awk -v re="$cre" '
    /^[[:space:]]*#/ {print; next} NF<2 {print; next}
    { c=""; for(i=3;i<=NF;i++) c=c (i>3?" ":"") $i; if (c ~ re) next; print }' "$KEYS_FILE" > "$tmp"
  cat "$pub" >> "$tmp"
  awk '{ if ($1 ~ /^#/ || NF<2) {print; next} if (!seen[$2]++) print }' "$tmp" > "$KEYS_FILE"
  rm -f "$tmp"
}

# --- git / GitHub -----------------------------------------------------------
git_in_repo() { git -C "$SELF_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; }
git_has_origin() { git -C "$SELF_DIR" remote get-url origin >/dev/null 2>&1; }
GH_LAST=""
# StrictHostKeyChecking=accept-new auto-pins GitHub's host key (so an unknown host
# key can't make this fail under BatchMode). GH_LAST keeps the real output for
# diagnostics — the failure is usually "Host key verification failed" or
# "Permission denied (publickey)", and we must show which.
gh_authed() {
  GH_LAST="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -T git@github.com 2>&1)"
  echo "$GH_LAST" | grep -qi "successfully authenticated"
}
ensure_github_access() {
  echo; echo "==> GitHub access (so this machine can sync the shared cluster state)"
  [ $DRY_RUN -eq 1 ] && { echo "  + (dry-run) would ensure a GitHub SSH key and verify auth"; return 0; }
  # commit identity
  if [ -z "$(git config --global user.email 2>/dev/null)" ] && [ "$INTERACTIVE" = "1" ]; then
    git config --global user.name  "$(ask 'Git commit name' "$(scutil --get ComputerName 2>/dev/null || echo)")"
    git config --global user.email "$(ask 'Git commit email' "")"
  fi
  ensure_keypair "$GH_KEY" "github-$LOCAL" >/dev/null
  if ! grep -q "^Host github.com$" "$SSH_CFG" 2>/dev/null; then
    touch "$SSH_CFG"; chmod 600 "$SSH_CFG"
    printf '\nHost github.com\n    HostName github.com\n    User git\n    AddKeysToAgent yes\n    UseKeychain yes\n    IdentityFile %s\n    IdentitiesOnly yes\n' "$GH_KEY" >> "$SSH_CFG"
  fi
  ssh-add --apple-use-keychain "$GH_KEY" >/dev/null 2>&1 || ssh-add "$GH_KEY" >/dev/null 2>&1 || true
  grep -q "github.com ssh-ed25519" "$HOME/.ssh/known_hosts" 2>/dev/null || \
    ssh-keyscan -t ed25519 github.com 2>/dev/null >> "$HOME/.ssh/known_hosts" || true
  if gh_authed; then echo "  ✓ ${GH_LAST%%,*}"; return 0; fi
  if [ "$INTERACTIVE" != "1" ]; then
    echo "  ! Not authenticated to GitHub and running non-interactively — git sync disabled." >&2
    echo "    (github said: ${GH_LAST:-no response})" >&2
    GIT_SYNC=0; return 0
  fi
  command -v pbcopy >/dev/null 2>&1 && pbcopy < "$GH_KEY.pub" && echo "  (public key copied to your clipboard)"
  while true; do
    echo "  Add THIS machine's GitHub public key as an *Authentication key* at:"
    echo "    https://github.com/settings/ssh/new"
    echo "    key   : $(cat "$GH_KEY.pub")"
    echo "    (matches fingerprint $(ssh-keygen -lf "$GH_KEY.pub" 2>/dev/null | awk '{print $2}'))"
    pause "Paste the key on GitHub (it's in your clipboard) and save it."
    if gh_authed; then echo "  ✓ GitHub authentication confirmed."; return 0; fi
    echo "  ✗ Still not authenticated. GitHub/SSH replied:"
    echo "$GH_LAST" | sed 's/^/      /'
    case "$GH_LAST" in
      *"Permission denied"*) echo "      → the key isn't on the account you're pushing to. Make sure you pasted"
                             echo "        the key above (not another), as an Authentication key, on the right account.";;
      *"Host key verification"*) echo "      → host-key issue; re-run, it now auto-pins GitHub's host key.";;
    esac
    askyn "  Try again?" "y" || { echo "  Continuing without git sync (push manually later)."; GIT_SYNC=0; return 0; }
  done
}
git_pull_latest() {
  [ $DRY_RUN -eq 1 ] && return 0
  [ "$GIT_SYNC" = 1 ] || return 0
  git_in_repo && git_has_origin || return 0
  echo; echo "==> Pulling latest shared cluster state (authorized_clients, cluster.conf)"
  git -C "$SELF_DIR" pull --rebase --autostash 2>&1 | sed 's/^/    /' || echo "    (pull skipped — continuing)"
}
git_register_push() {
  [ $DRY_RUN -eq 1 ] && return 0
  if [ "$GIT_SYNC" != 1 ]; then echo "  (git sync off — commit & push authorized_clients/cluster.conf yourself)"; return 0; fi
  git_in_repo && git_has_origin || { echo "  (not a git checkout with an origin — skipping push)"; return 0; }
  echo; echo "==> Registering this machine in the repo (commit + push shared state)"
  git -C "$SELF_DIR" add authorized_clients cluster.conf >/dev/null 2>&1 || true
  if git -C "$SELF_DIR" diff --cached --quiet 2>/dev/null; then echo "    Nothing new to register."; return 0; fi

  # Show exactly what would be registered, then ask before committing/pushing.
  echo "    Changes to register:"
  git -C "$SELF_DIR" diff --cached --stat 2>/dev/null | sed 's/^/      /'
  if [ "$INTERACTIVE" = "1" ]; then
    if ! askyn "  Commit and push these to GitHub now?" "y"; then
      echo "    Skipped (changes left staged). Push later with:"
      echo "      git -C '$SELF_DIR' commit -m 'register' && git -C '$SELF_DIR' push"
      return 0
    fi
    # Offer to sign the commit (defaults to your git name; blank = unsigned).
    [ -n "$SIGNER" ] || SIGNER="$(ask "  Sign this commit as (blank to skip)" "$(git -C "$SELF_DIR" config user.name 2>/dev/null)")"
  fi

  local msg="register $ROLE: $NAME${NUMBER:+ #$NUMBER} ($LOCAL)"
  [ -n "$SIGNER" ] && msg="$msg

Signed by $SIGNER"
  git -C "$SELF_DIR" commit -q -m "$msg" || true
  git -C "$SELF_DIR" pull --rebase --autostash -q 2>/dev/null || true
  if git -C "$SELF_DIR" push -q 2>/dev/null; then echo "    ✓ Pushed registration to origin${SIGNER:+ (signed by $SIGNER)}."
  else echo "    ! Push failed — resolve and run: git -C '$SELF_DIR' push"; fi
}

# Decide whether to run the wizard
if [ "$INTERACTIVE" = "auto" ]; then
  if { [ -z "$ROLE" ] || { [ "$ROLE" = "node" ] && [ -z "$NAME" ]; }; } && [ -t 0 ]; then
    INTERACTIVE=1; else INTERACTIVE=0; fi
fi

# ---------------------------------------------------------- the wizard --------
if [ "$INTERACTIVE" = "1" ]; then
  say ""
  say "=============================================================="
  say "  agent-team cluster setup"
  say "=============================================================="
  say "  A machine can connect only when ALL THREE are true:"
  say "    (1) it is in your private Tailscale network"
  say "    (2) it holds the cluster's authorized SSH key  <- I do this for you"
  say "    (3) it logs in as the '$LOGIN_USER' account"
  say "  I'll set those up now. (Privileged steps will ask for your password.)"
  say ""
  if [ -z "$ROLE" ]; then
    say "  What is THIS machine?"
    say "    [1] A cluster NODE   — an always-on Mac mini you SSH INTO"
    say "    [2] The MASTER       — the machine you SSH FROM (you carry it)"
    case "$(ask "Choose 1 or 2" "1")" in 2|master|client|portable|p|m) ROLE="master";; *) ROLE="node";; esac
  fi
  LOGIN_USER="$(ask "Login/SSH user to allow" "$LOGIN_USER")"
  if [ "$ROLE" = "node" ]; then
    [ -n "$NAME" ]   || NAME="$(ask "Machine name (e.g. Liger)" "$(scutil --get ComputerName 2>/dev/null || echo)")"
    [ -n "$NUMBER" ] || NUMBER="$(ask "Machine number (e.g. 3)" "")"
  else
    NAME="${NAME:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"
  fi
  if askyn "Use Tailscale for the encrypted network?" "y"; then
    DO_TAILSCALE=1
    if askyn "  Use a self-hosted Headscale server instead of Tailscale's cloud?" "n"; then
      LOGIN_SERVER="$(ask "  Headscale URL (e.g. https://hs.example.com)" "$LOGIN_SERVER")"
    fi
  else
    DO_TAILSCALE=0
  fi
  say ""
fi

# ------------------------------------------------------- validate -------------
[ -n "$ROLE" ] || ROLE="node"
case "$ROLE" in node|master) :;; *) echo "ERROR: --role must be node or master" >&2; exit 1;; esac
if [ "$ROLE" = "node" ]; then
  [ -n "$NAME" ]   || { echo "ERROR: node setup needs --name" >&2; exit 1; }
  [ -n "$NUMBER" ] || { echo "ERROR: node setup needs --number" >&2; exit 1; }
  [[ "$NUMBER" =~ ^[0-9]+$ ]] || { echo "ERROR: --number must be an integer" >&2; exit 1; }
  [[ "$NAME" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || { echo "ERROR: --name must be alphanumeric" >&2; exit 1; }
  LOCAL="$(echo "$NAME" | tr '[:upper:]' '[:lower:]')-$NUMBER"   # liger-3
  SHORT="$(echo "$NAME" | tr '[:upper:]' '[:lower:]')"           # liger
else
  LOCAL="$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
  SHORT="$LOCAL"
fi

echo "============================================================"
echo "  role: $ROLE    name: $NAME    tailnet name: $LOCAL"
echo "  login user: $LOGIN_USER    tailscale: $([ $DO_TAILSCALE -eq 1 ] && echo yes || echo no)$([ -n "$LOGIN_SERVER" ] && echo " (headscale: $LOGIN_SERVER)")"
echo "  dry-run: $([ $DRY_RUN -eq 1 ] && echo YES || echo no)"
echo "============================================================"

NEED_SUDO=0; { [ "$ROLE" = "node" ] || [ $DO_TAILSCALE -eq 1 ]; } && NEED_SUDO=1
[ $DRY_RUN -eq 1 ] || [ $NEED_SUDO -eq 0 ] || sudo -v

# ---------------------------------------------- 1. packages -------------------
echo; echo "==> Packages (git, autossh, tmux, mosh$([ $DO_TAILSCALE -eq 1 ] && echo ', tailscale'))"
if command -v brew >/dev/null 2>&1; then
  PKGS="git autossh tmux mosh"; [ $DO_TAILSCALE -eq 1 ] && PKGS="$PKGS tailscale"
  run "brew install $PKGS || true"
else
  echo "  ! Homebrew not found — install from https://brew.sh first." >&2
  [ $FORCE -eq 1 ] || exit 1
fi
# macOS ships git via the Command Line Tools; make sure *something* git exists.
command -v git >/dev/null 2>&1 || { [ $DRY_RUN -eq 1 ] || xcode-select --install 2>/dev/null || true; }

# ------------- GitHub access + pull the latest shared state -------------------
# This repo IS the cluster's shared registry: it must be able to pull the newest
# authorized_clients/cluster.conf before we change them, and push our changes
# back afterwards. So we set up (and verify) GitHub SSH access first.
ensure_github_access
git_pull_latest

# --------------------- 2. THE managed cluster access key (condition 2) --------
# The access key's PRIVATE half belongs ONLY on the MASTER. Nodes receive its
# PUBLIC half via the repo's authorized_clients (pulled above). So we generate it
# only during a master setup; it is created once and reused (self-healing).
if [ "$ROLE" = "master" ]; then
  echo; echo "==> Cluster access key (managed automatically; master-only)"
  run "mkdir -p '$KEYS_DIR'"; run "chmod 700 '$KEYS_DIR'"
  TAG="$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z' | cut -c1-8 || echo $$)"
  case "$(ensure_keypair "$ACCESS_PRIV" "agentteam-access-$TAG")" in
    new) echo "    Created a new cluster access key.";;
    ok)  echo "    Reusing existing cluster access key.";;
  esac
  # Put its PUBLIC half in the shared allow-list (replacing any prior access line).
  [ $DRY_RUN -eq 0 ] && [ -f "$ACCESS_PUB" ] && allowlist_put "$ACCESS_PUB" "^agentteam-access"

  # The access key IS the master credential — make the user secure it before we go on.
  if [ $DRY_RUN -eq 0 ]; then
    echo
    echo "  ┌─ SECURE YOUR MASTER ACCESS KEY ───────────────────────────────────"
    echo "  │ This private key is the master credential for the whole cluster."
    echo "  │ Lose it and you must re-key every node; leak it and anyone can SSH in."
    echo "  │ Private key : $ACCESS_PRIV"
    echo "  │ Fingerprint : $(ssh-keygen -lf "$ACCESS_PUB" 2>/dev/null | awk '{print $2}')"
    echo "  │ STORE IT NOW in BOTH places:"
    echo "  │   1) keep this local copy (on your FileVault-encrypted disk), and"
    echo "  │   2) save a copy in your password manager / encrypted USB."
    echo "  └───────────────────────────────────────────────────────────────────"
    if [ "$INTERACTIVE" = "1" ] && askyn "  Print the private key now so you can copy it into your password manager?" "n"; then
      echo "  ----- BEGIN (copy everything between the lines) -----"; cat "$ACCESS_PRIV"; echo "  ----- END -----"
    fi
    pause "Back up the master access key in your password manager AND keep the local copy."
  fi
fi

# --------------------------------------------- 2b. ~/.ssh skeleton -----------
echo; echo "==> ~/.ssh skeleton"
run "mkdir -p '$HOME/.ssh'"; run "chmod 700 '$HOME/.ssh'"
run "touch '$HOME/.ssh/authorized_keys'"; run "chmod 600 '$HOME/.ssh/authorized_keys'"

# =============================================================== NODE ROLE ====
if [ "$ROLE" = "node" ]; then
  # This node's own identity key, for SSH between minis (peer mesh).
  # Self-healing: if the key was deleted or corrupted, it is regenerated and the
  # stale allow-list entry is replaced with the fresh one.
  echo; echo "==> Node identity key (for peer SSH between minis)"
  case "$(ensure_keypair "$NODE_KEY" "$LOCAL-node")" in
    new) echo "    Generated a fresh node identity key.";;
    ok)  echo "    Reusing $NODE_KEY";;
  esac
  [ $DRY_RUN -eq 0 ] && [ -f "$NODE_KEY.pub" ] && allowlist_put "$NODE_KEY.pub" "^$LOCAL-node$"

  # Condition (2): install the shared allow-list into authorized_keys.
  echo; echo "==> Installing the authorized keys (condition 2)"
  if [ $DRY_RUN -eq 0 ]; then
    if [ "$(count_keys "$KEYS_FILE")" -eq 0 ] && [ $FORCE -eq 0 ]; then
      echo "  ERROR: allow-list empty and key-only SSH would lock you out." >&2; exit 1
    fi
    tmp="$(mktemp)"
    cat "$HOME/.ssh/authorized_keys" "$KEYS_FILE" 2>/dev/null \
      | awk 'NF>=2 && $1 !~ /^#/ { if(!seen[$2]++) print }' > "$tmp"
    install -m 600 "$tmp" "$HOME/.ssh/authorized_keys"; rm -f "$tmp"
    echo "    authorized_keys now holds $(grep -c . "$HOME/.ssh/authorized_keys") key(s)."
  fi

  # Condition (3): name the box, enable SSH, restrict to the login user.
  echo; echo "==> Hostname + Remote Login, restricted to '$LOGIN_USER' (condition 3)"
  srun "scutil --set ComputerName '$NAME'"
  srun "scutil --set LocalHostName '$LOCAL'"
  srun "scutil --set HostName '$LOCAL'"
  srun "dscacheutil -flushcache || true"
  srun "systemsetup -setremotelogin on"
  srun "dseditgroup -o create -q com.apple.access_ssh 2>/dev/null || true"
  srun "dseditgroup -o edit -a '$LOGIN_USER' -t user com.apple.access_ssh 2>/dev/null || true"

  echo; echo "==> Key-only SSH hardening"
  if [ $DRY_RUN -eq 0 ]; then
    tmpconf="$(mktemp)"
    cat > "$tmpconf" <<CONF
# agent-team SSH hardening (managed by agent_team_machine_setup.sh)
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
AuthenticationMethods publickey
AllowUsers $LOGIN_USER
MaxAuthTries 3
MaxSessions 20
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding yes
PermitTunnel no
ClientAliveInterval 30
ClientAliveCountMax 6
TCPKeepAlive yes
CONF
    sudo install -m 644 -o root -g wheel "$tmpconf" "$HARDEN_FILE"; rm -f "$tmpconf"
    sudo /usr/sbin/sshd -t && echo "    sshd config valid"
    sudo launchctl kickstart -k system/com.openssh.sshd 2>/dev/null || true
  else echo "  + (dry-run) would write $HARDEN_FILE with AllowUsers $LOGIN_USER"; fi

  echo; echo "==> Always-on power tuning + firewall"
  srun "pmset -c sleep 0"; srun "pmset -c disksleep 0"; srun "pmset -c displaysleep 2"
  srun "pmset -c powernap 1"; srun "pmset -c womp 1"
  srun "pmset -a autorestart 1"; srun "pmset -a tcpkeepalive 1"
  FW=/usr/libexec/ApplicationFirewall/socketfilterfw
  srun "$FW --setglobalstate on >/dev/null"; srun "$FW --setstealthmode on >/dev/null"
  srun "$FW --setallowsigned on >/dev/null"; srun "$FW --setallowsignedapp on >/dev/null"
fi

# ------------------------------------- Condition (1): join the tailnet --------
if [ $DO_TAILSCALE -eq 1 ]; then
  echo; echo "==> Joining your Tailscale network (condition 1)"
  srun "tailscaled install-system-daemon || true"
  UP="tailscale up --hostname $LOCAL"; [ -n "$LOGIN_SERVER" ] && UP="$UP --login-server $LOGIN_SERVER"
  echo "  A sign-in URL will appear — open it and approve '$LOCAL' in the admin console."
  [ $DRY_RUN -eq 1 ] || sudo $UP || true
fi

# ------------------------------------------ cluster manifest + ssh shortcuts --
if [ "$ROLE" = "node" ] && [ $DRY_RUN -eq 0 ]; then
  touch "$CLUSTER_FILE"
  grep -q "^$NUMBER|" "$CLUSTER_FILE" 2>/dev/null || echo "$NUMBER|$NAME|$LOCAL|$(date +%Y-%m-%d)" >> "$CLUSTER_FILE"
  sort -t'|' -k1,1n -o "$CLUSTER_FILE" "$CLUSTER_FILE"
fi

# On the MASTER, install the access key locally so 'ssh <node>' just works.
IDENTITY="$NODE_KEY"
if [ "$ROLE" = "master" ]; then
  echo; echo "==> Installing the cluster access key on this MASTER"
  if [ $DRY_RUN -eq 0 ]; then
    install -m 600 "$ACCESS_PRIV" "$MASTER_KEY"
    install -m 644 "$ACCESS_PUB"  "$MASTER_KEY.pub"
    echo "    Installed $MASTER_KEY (you never have to touch it)."
  fi
  IDENTITY="$MASTER_KEY"
fi

# (Re)write the managed cluster block in ~/.ssh/config: ssh <name> for every mini.
if [ $DRY_RUN -eq 0 ] && [ -s "$CLUSTER_FILE" ]; then
  touch "$SSH_CFG"; chmod 600 "$SSH_CFG"
  tmpcfg="$(mktemp)"
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$SSH_CFG" > "$tmpcfg"
  {
    echo "$MARK_BEGIN"
    while IFS='|' read -r n nm lc dt; do
      [ -z "$n" ] && continue
      sn="$(echo "$nm" | tr '[:upper:]' '[:lower:]')"
      echo "Host $sn $lc"
      echo "    HostName $lc"
      echo "    User $LOGIN_USER"
      echo "    IdentityFile $IDENTITY"
      echo "    IdentitiesOnly yes"
      echo "    ServerAliveInterval 30"
      echo "    ServerAliveCountMax 3"
      echo "    StrictHostKeyChecking accept-new"
    done < "$CLUSTER_FILE"
    echo "$MARK_END"
  } >> "$tmpcfg"
  install -m 600 "$tmpcfg" "$SSH_CFG"; rm -f "$tmpcfg"
  echo; echo "==> Wrote 'ssh <name>' shortcuts to $SSH_CFG for: $(awk -F'|' '{printf "%s ",tolower($2)}' "$CLUSTER_FILE")"
fi

# ----------------------------------------------------- tmux (node) -----------
if [ "$ROLE" = "node" ] && [ $DRY_RUN -eq 0 ]; then cat > "$HOME/.tmux.conf" <<TMUX
# ~/.tmux.conf — $NAME (agent-team mini #$NUMBER) — persistent Claude Code sessions
set -g history-limit 200000
set -g destroy-unattached off
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",xterm-256color:Tc,iTerm.app:Tc"
set -sg escape-time 10
setw -g aggressive-resize on
set -g mouse on
set -g renumber-windows on
set -g base-index 1
set -g status-interval 5
set -g status-right "#[bold]$NAME (mini #$NUMBER)#[default] | %H:%M %d-%b"
set -g status-style "bg=colour24,fg=white"
bind r source-file ~/.tmux.conf \\; display "tmux.conf reloaded"
TMUX
fi

# ----------------------- register shared state back to the repo --------------
git_register_push

# ------------------------------------------------ verification checklist ------
echo; echo "==> Verifying the three conditions"
if [ $DRY_RUN -eq 1 ]; then
  echo "  (dry-run) skipped live checks."
else
  # (1) tailnet
  if [ $DO_TAILSCALE -eq 0 ]; then echo "  [—] (1) tailnet: skipped (LAN-only)"
  elif tailscale status >/dev/null 2>&1; then echo "  [OK] (1) in the tailnet"
  else echo "  [!!] (1) NOT in the tailnet yet — finish 'tailscale up' sign-in."; fi
  # (2) authorized key
  if [ "$ROLE" = "node" ]; then
    if awk '{print $2}' "$HOME/.ssh/authorized_keys" 2>/dev/null | grep -qxF "$(awk '{print $2}' "$ACCESS_PUB" 2>/dev/null)"; then
      echo "  [OK] (2) holds the cluster access key in authorized_keys"
    else echo "  [!!] (2) access key NOT in authorized_keys"; fi
  else
    [ -f "$MASTER_KEY" ] && echo "  [OK] (2) cluster access key installed at $MASTER_KEY" || echo "  [!!] (2) access key not installed"
  fi
  # (3) user
  if id "$LOGIN_USER" >/dev/null 2>&1; then echo "  [OK] (3) login user '$LOGIN_USER' exists$([ "$ROLE" = node ] && echo " and is the only AllowUsers")"
  else echo "  [!!] (3) user '$LOGIN_USER' not found"; fi
fi

# --------------------------------------------------------------- summary ------
echo
echo "============================================================"
if [ "$ROLE" = "node" ]; then
  echo "  DONE: $NAME (mini #$NUMBER) is a cluster node."
  echo "  Reach it later with:  ssh $SHORT   (from the MASTER or any mini)"
  echo "  Cluster now contains:"
  [ -s "$CLUSTER_FILE" ] && awk -F'|' '{printf "     #%s  %-10s %s\n",$1,$2,$3}' "$CLUSTER_FILE"
  echo
  echo "  NEXT: 'git pull' on the next mini and run this again"
  echo "        (this machine's registration was already pushed above)."
else
  echo "  DONE: this MASTER can now reach the cluster. Try:  ssh <name>"
  echo "  Known machines:"
  [ -s "$CLUSTER_FILE" ] && awk -F'|' '{printf "     #%s  %-10s -> ssh %s\n",$1,$2,tolower($2)}' "$CLUSTER_FILE"
fi
echo
# The PRIVATE access key exists ONLY on the master (it is generated during a
# master run into $KEYS_DIR). A node never holds it — it only installs the
# PUBLIC half from authorized_clients. So describe the right thing per role,
# and never claim a path that isn't actually there.
if [ "$ROLE" = "master" ]; then
  if [ -f "$ACCESS_PRIV" ]; then
    echo "  SECURITY: the PRIVATE access key lives in '$KEYS_DIR'"
    echo "    -> $ACCESS_PRIV"
    echo "  (outside the git repo — never committed). Back it up to your password"
    echo "  manager / encrypted USB. Anyone holding it can SSH to the cluster."
    echo "  To revoke: delete that key, remove its line from authorized_clients,"
    echo "  commit & push, then re-run this on each node."
  else
    echo "  SECURITY: no private access key was created at '$ACCESS_PRIV'."
    echo "  (Expected for a dry-run; otherwise re-run the master setup to generate it.)"
  fi
else
  echo "  SECURITY: this NODE does not hold the private access key — by design."
  echo "  It only installs the PUBLIC half (from authorized_clients) into"
  echo "  ~/.ssh/authorized_keys. The private key lives ONLY on the MASTER, in"
  echo "  its '$KEYS_DIR'. Run '--role master' on the machine you SSH FROM to"
  echo "  create it; back THAT copy up to your password manager / encrypted USB."
fi
echo "============================================================"
