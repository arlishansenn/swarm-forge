# SwarmForge

Agent coordination for developing a **managed project**. This file is the glossary.

## Language

**SwarmForge**:
The coordination product (this repository). It is not the product being developed.
_Avoid_: the swarm repo (when meaning a managed project)

**Managed project**:
A product git repository that a swarm develops (for example podsum or pi-governance). SwarmForge is installed into it.
_Avoid_: target repo, client project, host project

**Script snapshot**:
The SwarmForge operational toolbox copied into a managed project at `swarmforge/scripts/`. It is a local snapshot, not the SwarmForge source of truth.
_Avoid_: swarm-forge scripts, the scripts directory, helper scripts (when meaning this copy)

**Swarm launcher** (`./swarm`):
The entry command in a managed project. Its only relationship to the script snapshot is: create that directory when it is missing, reuse it unchanged when it exists, then start the swarm from it.
_Avoid_: swarm script, start script, the wrapper (when meaning the snapshot)

**Source checkout**:
The SwarmForge git working tree that authors the operational scripts. Changing it does not change a managed project's script snapshot until that snapshot is replaced.
_Avoid_: upstream (when meaning this checkout), main scripts

**Role worktree copy**:
The per-role copy of the script snapshot under that role's git worktree `swarmforge/scripts/`. Each role uses this copy on `PATH`.
_Avoid_: the worktree scripts (when meaning the managed project's snapshot)

**Swarm**:
One running orchestration of configured roles against one project root. One project root supports one swarm; a second swarm needs a separate git worktree as its root.
_Avoid_: pack (when meaning the running process)

**Pack**:
A named role topology (`two-pack`, `four-pack`, `six-pack`) recorded in `swarmforge.conf`.
_Avoid_: swarm (when meaning the topology file)
