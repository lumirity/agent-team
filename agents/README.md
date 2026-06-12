# agents/ — shared per-machine agent state (overlay)

One `*.env` file per machine, named by its **lowercase short name** (e.g.
`nora.env`, `elga.env`, `master.env`). These are committed to the repo, so every
machine sees the same config after `git pull`. They hold **non-secret** key=value
config only — never private keys or tokens.

`agent_team_machine_setup.sh` writes/updates this machine's file on registration
and pushes it. You can also hand-edit a file to add extra keys (like a Linear
assignee) and commit it.

## Format

Plain `KEY=VALUE` (or `export KEY="VALUE"`) lines. Only `AGENT_TEAM_*` keys are
read; anything else is ignored. Example `nora.env`:

```sh
AGENT_TEAM_MACHINE=nora-2
AGENT_TEAM_NAME=Nora
AGENT_TEAM_NUMBER=2
AGENT_TEAM_ROLE=node
AGENT_TEAM_LINEAR_ASSIGNEE=foramyhua@gmail.com   # who Linear tasks for this box go to
```

The key set is open-ended — add your own `AGENT_TEAM_*` keys and they'll show up
in `get_agent_config.sh` output automatically.

## Reading it

```sh
./get_agent_config.sh --name nora                  # all keys as key=value
./get_agent_config.sh --name nora --key LINEAR_ASSIGNEE
eval "$(./get_agent_config.sh --name nora --export)"   # load into the current shell
./get_agent_config.sh --list                       # all known machines
```

Resolution merges, in order (later wins): `cluster.conf` → `agents/<name>.env` →
the local `~/.config/agent-team/identity` (only when you query the current box).
