# Agent instructions

**This is `arlishansenn/swarm-forge`, a fork of `unclebob/swarm-forge`, on the
`lieutenant` product branch.** Read the next two sections before running any
`gh` command or any `git merge`. Both describe ways to do public, hard-to-undo
damage that look like ordinary work.

## Never touch the upstream tracker

Track work in GitHub Issues for `arlishansenn/swarm-forge`. Never create, edit,
or comment on issues or pull requests in `unclebob/swarm-forge`.

This clone's `origin` is the fork, but **`gh` resolves to the upstream by
default**, so a bare `gh issue create` files a ticket on someone else's
repository. Pass `--repo arlishansenn/swarm-forge` on every `gh issue` and
`gh pr` call. This is public and cannot be quietly undone.

## Never merge `main` into this branch

The tree here is upstream's `lieutenant` product branch. It is **not** a copy of
this fork's `main`, and the two are not interchangeable:

- `handoffd.bb` is 862 lines here and 446 on `main`. The extra 43 functions are
  card dispatch, the Attention lane, and the reverse lane — the whole point of
  this product. Merging `main` deletes them.
- `pack_web.bb` is split into `pack_web_*.bb` here; `start-pack-web!` lives in
  `swarmforge_terminal.bb`, not `swarmforge.bb`.

Sync against `upstream/lieutenant` only, the same way the pack branches do.
`get-swarm-forge lieutenant` downloads this branch and never downloads `main`,
so nothing on `main` reaches an installed forge on its own.

## Fork deltas apply here too, one at a time

Every behavioural fix this fork carries has to be applied to this branch
separately, and the anchors usually differ from `main`'s — several symbols
(`submit-keys`, `pack-web-argv`) have zero hits here. The index, the reasoning,
and the per-delta nails are on `main`:
[`docs/fork-deltas.md`](https://github.com/arlishansenn/swarm-forge/blob/main/docs/fork-deltas.md).

Two traps this branch has already sprung:

- `notify!`'s third parameter is a custom `message` here and an `agent` on
  `main`. Both capabilities have to survive.
- `retry-delay-ms` exists on both sides with opposite meanings — exponential
  backoff for outbox delivery here, a wake ladder on `main`. Clojure lets the
  later definition win **silently**. The wake ladder is named `wake-*` here for
  that reason; keep it that way.

## Verifying a change on this branch

`bb test` aborts at `coverage-in-process-test` (`Cannot find SwarmForge project
root`), on `upstream/lieutenant` too, so there is no total to report. Compare
the failure list before and after instead:

```sh
LC_ALL=C LANG=C bb test > /tmp/after.out 2>&1
grep -oE '(FAIL|ERROR) in \([a-z0-9-]+\)' /tmp/after.out | sort -u
grep -cE '^(FAIL|ERROR) in ' /tmp/after.out
```

The baseline is **1 failing test / 3 assertions**
(`merge-and-process-takes-inbound-task-docs`, already red upstream). `LC_ALL=C
LANG=C` is required: without it git speaks Chinese and that test fails
differently, which reads like a regression you caused.

## Do not pin prompt text with tests

Do not test the text of prompts with an automated unit or acceptance test.
That includes constitution articles, role prompts, Tool Startup, and generated
instruction files. Prompt wording is not production behavior to pin with
`str/includes?`, Gherkin, or any other automated check.

## What is deliberately missing here

`docs/`, `openspec/`, `.agents/`, `CONTEXT.md`, and `contrib/` do not exist on
this branch by design. They are development-time assets of `main`, and
`get-swarm-forge` never installs them. For the `swarmforge-operator` skill, an
OpenSpec change, or an ADR, switch to `main`.
