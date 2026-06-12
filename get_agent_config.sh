#!/bin/bash
# get_agent_config.sh — read the cluster's SHARED agent state and print one
# machine's AGENT_TEAM_* config as key=value pairs.
#
#   ./get_agent_config.sh                          # THIS machine (from local identity)
#   ./get_agent_config.sh --name nora              # a specific machine
#   ./get_agent_config.sh --name nora --key MACHINE        # one value (prefix optional)
#   ./get_agent_config.sh --name nora --key LINEAR_ASSIGNEE
#   eval "$(./get_agent_config.sh --name nora --export)"   # load into your shell
#   ./get_agent_config.sh --name nora --json
#   ./get_agent_config.sh --list                   # every known machine name
#
# Sources, merged in order (LATER wins), so you get a single resolved view:
#   1. cluster.conf                    shared node manifest  (number|name|local|date)
#   2. agents/<name>.env               shared per-machine overlay (any AGENT_TEAM_* key,
#                                      e.g. AGENT_TEAM_LINEAR_ASSIGNEE) — works for the
#                                      master too, which isn't in cluster.conf
#   3. ~/.config/agent-team/identity   local truth — only when you query THIS machine
#
# It only SOURCES the local identity (which this machine wrote); the shared
# agents/*.env overlays are parsed, never executed.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
CLUSTER_FILE="${AGENT_TEAM_CLUSTER_FILE:-$SELF_DIR/cluster.conf}"
AGENTS_DIR="${AGENT_TEAM_AGENTS_DIR:-$SELF_DIR/agents}"
SECRETS_DIR="${AGENT_TEAM_SECRETS:-$HOME/.config/agent-team}"
LOCAL_IDENTITY="$SECRETS_DIR/identity"

QUERY="" ; KEY="" ; FORMAT="env" ; DO_LIST=0

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name|-n) QUERY="${2:-}"; shift 2;;
    --key|-k)  KEY="${2:-}";   shift 2;;
    --export)  FORMAT="export"; shift;;
    --json)    FORMAT="json";   shift;;
    --list|-l) DO_LIST=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1;;
  esac
done

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Pull AGENT_TEAM_* assignments out of a file, dropping any leading 'export '.
read_kv() { grep -E '^[[:space:]]*(export[[:space:]]+)?AGENT_TEAM_[A-Z0-9_]+=' "$1" 2>/dev/null \
              | sed -E 's/^[[:space:]]*export[[:space:]]+//' || true; }

# ----------------------------------------------------------------- --list -----
if [ "$DO_LIST" -eq 1 ]; then
  {
    [ -f "$CLUSTER_FILE" ] && awk -F'|' '!/^[[:space:]]*#/ && NF>=3 {print tolower($2)}' "$CLUSTER_FILE"
    if [ -d "$AGENTS_DIR" ]; then
      for f in "$AGENTS_DIR"/*.env; do [ -e "$f" ] || continue; basename "$f" .env; done
    fi
  } | sort -u
  exit 0
fi

# --------------------------------------------------- resolve which machine ----
# Default to THIS machine when no --name is given.
if [ -z "$QUERY" ]; then
  if [ -n "${AGENT_TEAM_MACHINE:-}" ]; then
    QUERY="$AGENT_TEAM_MACHINE"
  elif [ -f "$LOCAL_IDENTITY" ]; then
    QUERY="$( . "$LOCAL_IDENTITY" 2>/dev/null; printf '%s' "${AGENT_TEAM_NAME:-${AGENT_TEAM_MACHINE:-}}" )"
  fi
  [ -n "$QUERY" ] || { echo "ERROR: no --name given and this machine has no identity ($LOCAL_IDENTITY)." >&2; exit 1; }
fi
LOWER="$(lower "$QUERY")"

# ----------------------------------------------------------- gather sources ---
BUF=""
SHORT="$LOWER"
MATCHED=0

# (1) cluster.conf — match on short name, tailnet local, or number.
if [ -f "$CLUSTER_FILE" ]; then
  row="$(awk -F'|' -v q="$LOWER" '
    !/^[[:space:]]*#/ && NF>=3 {
      if (tolower($2)==q || tolower($3)==q || $1==q) { print $1"|"$2"|"$3; exit }
    }' "$CLUSTER_FILE")"
  if [ -n "$row" ]; then
    num="${row%%|*}"; rest="${row#*|}"; nm="${rest%%|*}"; lc="${rest#*|}"
    SHORT="$(lower "$nm")"
    BUF="$BUF
AGENT_TEAM_MACHINE=$lc
AGENT_TEAM_NAME=$nm
AGENT_TEAM_NUMBER=$num
AGENT_TEAM_ROLE=node"
    MATCHED=1
  fi
fi

# (2) shared overlay agents/<short>.env (try the resolved short, then the raw query).
for cand in "$AGENTS_DIR/$SHORT.env" "$AGENTS_DIR/$LOWER.env"; do
  if [ -f "$cand" ]; then
    BUF="$BUF
$(read_kv "$cand")"
    MATCHED=1
    break
  fi
done

# (3) local identity — only when the query resolves to THIS machine.
if [ -f "$LOCAL_IDENTITY" ]; then
  lid_m="$( . "$LOCAL_IDENTITY" 2>/dev/null; printf '%s' "${AGENT_TEAM_MACHINE:-}" )"
  lid_short="$(lower "$( . "$LOCAL_IDENTITY" 2>/dev/null; printf '%s' "${AGENT_TEAM_NAME:-}" )")"
  if [ "$LOWER" = "$lid_short" ] || [ "$LOWER" = "$lid_m" ] || [ "$SHORT" = "$lid_short" ]; then
    BUF="$BUF
$(read_kv "$LOCAL_IDENTITY")"
    MATCHED=1
  fi
fi

if [ "$MATCHED" -ne 1 ]; then
  echo "ERROR: unknown machine '$QUERY'. Known machines:" >&2
  "$0" --list | sed 's/^/  /' >&2
  exit 1
fi

# --------------------------------------------- merge (last value per key wins) -
# Split on the FIRST '=' so values may contain '='; strip one layer of quotes;
# keep keys in order of first appearance.
MERGED="$(printf '%s\n' "$BUF" | awk -F= '
  $1 ~ /^AGENT_TEAM_[A-Z0-9_]+$/ {
    key=$1; val=substr($0, index($0,"=")+1)
    sub(/^"/,"",val); sub(/"$/,"",val)
    if (!(key in seen)) order[++n]=key
    seen[key]=val
  }
  END { for (i=1;i<=n;i++) print order[i]"="seen[order[i]] }')"

# ----------------------------------------------------------------- --key ------
if [ -n "$KEY" ]; then
  k="$(printf '%s' "$KEY" | tr '[:lower:]' '[:upper:]')"
  case "$k" in AGENT_TEAM_*) ;; *) k="AGENT_TEAM_$k";; esac
  if val="$(printf '%s\n' "$MERGED" | awk -F= -v k="$k" '$1==k{print substr($0,index($0,"=")+1); f=1} END{exit(f?0:1)}')"; then
    printf '%s\n' "$val"; exit 0
  else
    echo "ERROR: key '$k' is not set for '$QUERY'." >&2; exit 1
  fi
fi

# -------------------------------------------------------------- formatted out -
case "$FORMAT" in
  env)    printf '%s\n' "$MERGED" ;;
  export) printf '%s\n' "$MERGED" | sed -E 's/^([A-Za-z0-9_]+)=(.*)$/export \1="\2"/' ;;
  json)   printf '%s\n' "$MERGED" | awk -F= '
            BEGIN { printf "{" }
            { if (seen++) printf ","; k=$1; v=substr($0,index($0,"=")+1);
              gsub(/\\/,"\\\\",v); gsub(/"/,"\\\"",v); printf "\"%s\":\"%s\"", k, v }
            END { print "}" }' ;;
esac
