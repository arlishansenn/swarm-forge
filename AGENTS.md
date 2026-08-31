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

## OpenSpec

The `intent-driven` schema comes from `arlishansenn/openspec-schemas`, a fork
whose only divergence is that repository-level ADRs go to `docs/adr/` instead
of upstream's top-level `adr/`. Re-sync the schema from that fork, never from
`intent-driven-dev/openspec-schemas`: installing upstream moves ADRs back to
`adr/`, which splits the folder the adr step walks to resolve the Supersedes
chain. Reasoning is in `docs/adr/0004-adr-location-follows-forked-schema.md`.

Companion skills still come from `intent-driven-dev/skills`; that repository
carries no ADR path.
