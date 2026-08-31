# Domain docs

This repository uses a single-context domain documentation layout.

## Before exploring

Read these files when they exist:

- `CONTEXT.md`
- ADRs under `docs/adr/`

Proceed silently when they do not exist. Create domain documentation lazily
when terminology or architectural decisions are resolved.

## Vocabulary

Use terms defined in `CONTEXT.md` in issue titles, specifications, tests, and
implementation discussions. Avoid introducing synonyms for established terms.

If required terminology is absent, record the gap for domain modeling.

## Architectural decisions

Surface conflicts with an existing ADR explicitly. Do not silently override an
accepted decision.
