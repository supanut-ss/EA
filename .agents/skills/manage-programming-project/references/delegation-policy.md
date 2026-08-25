# Delegation Policy

## Model selection

| Model | Assign when | Avoid when |
| --- | --- | --- |
| `gpt-5.6-sol` | Project leadership, architecture, ambiguous requirements, complex implementation, difficult debugging, security-sensitive changes, integration, code review, final verification | A cheaper model can complete a fully specified mechanical subtask without increasing integration risk |
| `gpt-5.6-terra` | Routine feature implementation, isolated multi-file changes, tests, refactors, API wiring, documentation requiring technical judgment | The task owns architecture, has severe uncertainty, or crosses many subsystem boundaries |
| `gpt-5.6-luna` | Fast repository searches, inventory, simple test additions, mechanical edits, formatting, small documentation updates, reproducible command checks | Ambiguous logic, architecture, security decisions, difficult debugging, or final approval |

Prefer the inherited model unless a different model materially improves cost, speed, or quality. Use only model identifiers actually exposed by the runtime.

## Effort selection

| Effort | Use for | Examples |
| --- | --- | --- |
| `low` | Deterministic, narrow, low-risk work | Locate symbols, list impacted files, rename a local identifier, update a small comment |
| `medium` | Routine engineering with clear patterns | Add unit tests, implement a small endpoint, ordinary refactor, update typed models |
| `high` | Complex reasoning or meaningful integration risk | Multi-file feature, nondeterministic bug, concurrency issue, auth change, database behavior |
| `xhigh` | Architecture or hard cross-system work | Major migration, performance redesign, distributed failure analysis, unfamiliar legacy subsystem |
| `max` / `ultra` | Exceptional ambiguity or very high consequence when supported | Critical architecture review, severe security boundary, repeated failed diagnosis |

Choose the lowest effort that can reliably satisfy the acceptance criteria. Escalate when evidence contradicts assumptions, tests repeatedly fail, or the task expands across boundaries. Do not use `max` or `ultra` by default.

## Delegation decision

Delegate only when all are true:

1. The output is independently describable and reviewable.
2. Relevant context can be supplied without transferring project leadership.
3. File ownership is non-overlapping, or the task is findings-only.
4. Parallel work saves time or specialist attention improves quality.
5. Sol can verify the result before integration.

Keep work with Sol when it determines architecture, changes a shared contract, is too small to justify coordination, depends on rapidly changing local state, or cannot be independently verified.

## Default routing examples

| Task | Model | Effort |
| --- | --- | --- |
| Inspect repository structure and identify test commands | Luna | low |
| Implement an isolated CRUD module with established patterns | Terra | medium |
| Add regression tests for a known bug | Terra | medium |
| Diagnose an intermittent race across services | Sol | high or xhigh |
| Design a database migration with rollback and compatibility | Sol | xhigh |
| Review integrated changes against acceptance criteria | Sol | high |

## Quality gates

Require the leader to reject or revise delegated work when it:

- changes files outside scope without necessity;
- lacks requested tests or evidence;
- conflicts with repository instructions or architecture;
- introduces an unhandled error, compatibility break, or security regression;
- relies on an assumption that the leader cannot validate;
- reports completion without an inspectable artifact or reproducible finding.
