# Agent instructions

Do not test the text of prompts with an automated unit or acceptance test.
That includes constitution articles, role prompts, Tool Startup, and generated
instruction files. Prompt wording is not production behavior to pin with
`str/includes?`, Gherkin, or any other automated check.

## Agent skills

### Issue tracker

Track work in GitHub Issues for `arlishansenn/swarm-forge`. Never create, edit, or
comment on issues in the `unclebob/swarm-forge` upstream. This clone is a fork, so
`gh` resolves to the upstream by default. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the canonical triage labels defined for this repository. See `docs/agents/triage-labels.md`.

### Domain docs

Use the single-context domain documentation layout. See `docs/agents/domain.md`.
