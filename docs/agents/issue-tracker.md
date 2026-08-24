# Issue tracker: GitHub

Issues and specs for this repository live in GitHub Issues at
`arlishansenn/swarm-forge`. Use the `gh` CLI for all operations.

## Conventions

- Create: `gh issue create`
- Read with comments and labels: `gh issue view <number> --comments`
- List: `gh issue list`
- Comment: `gh issue comment <number>`
- Apply or remove labels: `gh issue edit <number>`
- Close: `gh issue close <number>`

## This clone is a fork: `gh` defaults to the upstream

`origin` is `arlishansenn/swarm-forge`; `upstream` is `unclebob/swarm-forge`. For a
fork, `gh` resolves to the parent repository, not to `origin`. Running `gh` inside
this clone is therefore not enough, and every `gh issue`/`gh label` command silently
lands on the upstream tracker.

Before any `gh` work in a fresh clone:

```sh
gh repo set-default arlishansenn/swarm-forge
gh repo set-default --view   # must print arlishansenn/swarm-forge
```

Never create, edit, close, or comment on an issue in `unclebob/swarm-forge`.

Issue numbers are per repository. A bare `#49` in an issue body resolves against
this fork, where it may not exist. Write cross-repository references in full:
`unclebob/swarm-forge#49`.

## Pull requests as a triage surface

PRs as a request surface: no.

A bare `#<number>` can identify an issue or PR because GitHub shares one number
space. Try `gh pr view <number>` and then `gh issue view <number>`.

## Skill operations

When a skill says "publish to the issue tracker", create a GitHub issue.

When a skill says "fetch the relevant ticket", run:

`gh issue view <number> --comments`

## Blocking relationships

Use GitHub native issue dependencies when available. Create blocker issues
first, resolve their database IDs through `gh api`, and add `blocked_by`
relationships to dependent issues.

If native dependencies are unavailable, add a `Blocked by: #<number>` section
to the dependent issue body.

A ticket is ready when all blockers are closed.
