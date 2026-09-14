# Agent instructions

Do not test the text of prompts with an automated unit or acceptance test.
That includes constitution articles, role prompts, Tool Startup, and generated
instruction files. Prompt wording is not production behavior to pin with
`str/includes?`, Gherkin, or any other automated check.

## Issue tracker

Track work in GitHub Issues for `arlishansenn/swarm-forge`. Never create, edit, or
comment on issues in the `unclebob/swarm-forge` upstream. This clone is a fork, so
`gh` resolves to the upstream by default: pass `--repo arlishansenn/swarm-forge`
on every `gh issue` and `gh pr` call. Opening a ticket on someone else's tracker
is public and cannot be quietly undone.

## This branch is not `main`

The tree here is upstream's `lieutenant` product branch, not a copy of this
fork's `main`. Two consequences:

- **Never merge `main` into this branch.** It would replace this branch's
  862-line `handoffd.bb` with `main`'s 446-line one and delete card dispatch,
  the Attention lane, and the reverse lane. Sync against `upstream/lieutenant`
  only, the same way the pack branches do.
- **Every fork delta has to be applied here separately**, and the anchors
  usually do not match `main`'s. The index and the reasoning live on `main`:
  [`docs/fork-deltas.md`](https://github.com/arlishansenn/swarm-forge/blob/main/docs/fork-deltas.md).

`docs/`, `openspec/`, and `.agents/` do not exist on this branch by design — they
are development-time assets of `main`, and `get-swarm-forge` never ships them.
For the operator skill or an OpenSpec change, work on `main`.
