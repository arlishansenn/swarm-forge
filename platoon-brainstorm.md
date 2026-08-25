# Platoon Brainstorm

## Purpose

A platoon is a SwarmForge control layer for building a system from multiple
independently deployable components. It coordinates several squads under one
Lieutenant agent.

Each squad is a normal SwarmForge pack instance. The Lieutenant is the only
agent active at platoon startup. Squads are created later, after the user and
Lieutenant have agreed on a component plan.

## Vocabulary

- **Pack**: A configured SwarmForge workflow pipeline, such as two-pack,
  four-pack, or six-pack.
- **Squad**: A collaborating pack instance. This term is distinct from any
  historical or branch name that may also be called `squad`.
- **Platoon**: A group of collaborating squads working toward a larger system
  objective.
- **Lieutenant**: The platoon-level agent that oversees the squads, assigns
  work, coordinates dependencies, integrates squad outputs, and owns the system
  test procedure.
- **Component**: An independently deployable unit produced by one squad.

## Command Structure

```text
operator
  |
lieutenant
  |
  +-- squad-a
  +-- squad-b
  +-- squad-c
```

The Lieutenant is the platoon-level overseer and integrator. Each squad is a
pack running its own workflow.

## Runtime Flow

1. The user starts the platoon.
2. Only the Lieutenant is active at startup.
3. The user and Lieutenant brainstorm the system.
4. They identify components, component levels, and polymorphic interfaces
   between components.
5. The Lieutenant produces a system plan for user review.
6. The user approves or rejects the plan.
7. After approval, the Lieutenant evaluates each component and chooses the
   appropriate squad type for it.
8. The Lieutenant starts each squad in its own directory, one level below the
   platoon.
9. The Lieutenant gives each squad its component task.
10. Squads execute their normal pack workflows independently.
11. The Lieutenant monitors squad progress.
12. When squads complete, the Lieutenant integrates their independently
    deployable components.
13. The Lieutenant writes and executes the system test procedure.
14. The Lieutenant reports completion, remaining risks, and any unresolved
    operator decisions.

## Squad Selection

The Lieutenant chooses a pack type for each component after the user approves
the system plan.

- **two-pack**: Simple utility components that do not need acceptance tests.
- **four-pack**: Complex components that need Gherkin acceptance tests. These
  components tend to contain business rules.
- **six-pack**: Components with a substantial user interface that require QA.

## Filesystem Shape

Squads run in their own directories, one level below the platoon directory.

```text
platoon/
  platoonforge.conf
  swarmforge/
    roles/
      lieutenant.prompt
    constitution/
      articles/
        platoon-workflow.prompt
  .platoonforge/
    dashboard-url
    state...
  squad-a/
    swarmforge/
    .swarmforge/
    .worktrees/
  squad-b/
    swarmforge/
    .swarmforge/
    .worktrees/
  squad-c/
    swarmforge/
    .swarmforge/
    .worktrees/
```

Each squad owns its own dashboard, tmux sessions, worktrees, handoff daemon, and
`.swarmforge` state. The platoon directory is the parent control plane.

## Component Architecture

Each squad produces one independently deployable component. Each component
operates at a single architectural level.

Levels are defined by distance from IO:

- **Low level**: Close to IO, devices, databases, frameworks, transports,
  external services, and delivery mechanisms.
- **High level**: Far from IO, policy, rules, use cases, and domain decisions.

A component that mixes high-level policy with low-level IO should be split into
separate components.

## Inter-Component Interfaces

Components communicate through polymorphic interfaces appropriate to their
language:

- Clojure: protocols
- Java: interfaces
- Go: interface types
- TypeScript: interfaces or abstract service contracts

Squads depend on contracts, not on one another's concrete implementations.

Interfaces between two components are defined in the higher-level component and
implemented in the lower-level component. The lower-level component acts as a
plugin to the higher-level component, even when runtime calls flow in the
opposite direction.

## Dependency Rule

Dependencies between components always point toward the higher-level component.

Example:

```text
Level 3: order-processing
  Defines PaymentPort.

Level 2: stripe-adapter
  Depends on order-processing.
  Implements PaymentPort.

Level 1: web-api
  Depends on order-processing.
  Drives order-processing use cases.
```

Dependency arrows:

```text
web-api         -> order-processing
stripe-adapter -> order-processing
```

The high-level component must not depend on lower-level implementations.

## Lieutenant Responsibilities

The Lieutenant should:

- Decompose large operator goals into squad-sized component tasks.
- Identify component boundaries and architectural levels with the user.
- Define or approve cross-component interfaces.
- Produce the system plan and wait for user approval before starting squads.
- Assign each approved component to an appropriate squad.
- Ensure every squad/component declares its architectural level.
- Maintain the platoon dependency graph.
- Enforce the Dependency Rule across components.
- Ensure cross-component interfaces are owned by the higher-level component.
- Prevent concrete coupling between squad directories.
- Coordinate compatibility between components.
- Monitor squad progress.
- Integrate squad outputs into the larger platoon result.
- Write and execute the system-level test procedure for the full platoon
  objective.
- Escalate ambiguous requirements, architectural conflicts, or dependency-rule
  violations to the operator.

## Platoon Dashboard

The platoon dashboard should use the existing pack dashboard as its skeleton,
but scale the board up one level.

The board consists of horizontal squad rows. Each row represents one squad and
contains that squad's normal pack swim lanes.

Example:

```text
Squad: billing-core
  specifier | coder | refactorer | architect | Done

Squad: billing-postgres
  coder | cleaner | Done

Squad: billing-web
  specifier | coder | cleaner | architect | hardender | QA | Done
```

This preserves the familiar pack lane model while making platoon-level status
visible at a glance.

The work queue becomes a scrolling list of agents subdivided by squad:

```text
billing-core
  specifier
  coder
  refactorer
  architect

billing-postgres
  coder
  cleaner

billing-web
  specifier
  coder
  cleaner
  architect
  hardender
  QA
```

The Lieutenant should remain visually distinct from the squads, since it is the
platoon-level overseer rather than a member of any one squad. Attention items
should aggregate across the Lieutenant and all squads, with enough labeling to
show which squad and agent require action.

## Open Design Questions

- What exact format should `platoonforge.conf` use?
- What commands should the Lieutenant use to launch squads?
- Should the platoon dashboard embed live squad views, link to each squad's
  existing dashboard, or replace them with a single aggregate board?
- How should component levels be declared and validated?
- How should interface ownership be represented across languages?
- What integration artifact proves the platoon objective is complete?
- What information must the user approve before the Lieutenant may start squads?
