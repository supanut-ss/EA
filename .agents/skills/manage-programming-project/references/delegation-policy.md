# Delegation Policy

## Model selection

| Model | Assign when | Avoid when |
| --- | --- | --- |
| `gpt-6-astra` | Exceptionally demanding architecture, severe ambiguity, cross-system failure analysis, and high-consequence design or security review | Routine implementation, mechanical work, or a second review that adds no meaningful confidence |
| `gpt-6-sol` | Project leadership, architecture, ambiguous requirements, complex implementation, difficult debugging, security-sensitive changes, integration, code review, and final verification | A faster model can complete a fully specified, low-risk subtask without increasing integration risk |
| `gpt-6-luna` | Fast repository searches, inventory, simple test additions, mechanical edits, formatting, small documentation updates, and reproducible command checks | Ambiguous logic, architecture, security decisions, difficult debugging, or final approval |

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

Use only reasoning efforts exposed for the selected model. The current runtime offers `low`, `medium`, `high`, `xhigh`, `max`, and `ultra` for Astra and Sol; Luna supports up to `max`.

## Delegation decision

Delegate only when all are true:

1. The output is independently describable and reviewable.
2. Relevant context can be supplied without transferring project leadership.
3. File ownership is non-overlapping, or the task is findings-only.
4. Parallel work saves time or specialist attention improves quality.
5. The Sol lead can verify the result before integration.

Keep work with Sol when it determines architecture, changes a shared contract, is too small to justify coordination, depends on rapidly changing local state, or cannot be independently verified. Consult Astra for unusually high complexity or consequences while keeping integration ownership with Sol.

## Default routing examples

| Task | Model | Effort |
| --- | --- | --- |
| Inspect repository structure and identify test commands | gpt-6-luna | low |
| Implement an isolated CRUD module with established patterns | gpt-6-sol | medium |
| Add regression tests for a known bug | gpt-6-sol | medium |
| Diagnose an intermittent race across services | gpt-6-astra | high or xhigh |
| Design a database migration with rollback and compatibility | gpt-6-sol, with Astra consultation for unusual risk | xhigh |
| Review integrated changes against acceptance criteria | gpt-6-sol | high |

## Quality gates

Require the leader to reject or revise delegated work when it:

- changes files outside scope without necessity;
- lacks requested tests or evidence;
- conflicts with repository instructions or architecture;
- introduces an unhandled error, compatibility break, or security regression;
- relies on an assumption that the leader cannot validate;
- reports completion without an inspectable artifact or reproducible finding.
