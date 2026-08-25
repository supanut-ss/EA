# Delegation Policy

## Agent type and model selection

Delegation in Claude Code goes through the `Agent` tool: pick a `subagent_type` for the *kind* of work, and optionally a `model` override for cost/speed/quality.

| Subagent type | Assign when | Avoid when |
| --- | --- | --- |
| `Explore` | Locating code, answering "where is X defined", multi-location keyword search, read-only reconnaissance | The task needs to write/edit files, or requires judgment beyond retrieval |
| `Plan` | Designing an implementation strategy, weighing architectural trade-offs before committing to a plan | The task is a small, already-well-specified edit |
| `general-purpose` | Multi-step tasks mixing research and execution, ambiguous scope, tasks needing broad tool access | A narrower agent type already fits (prefer the specific one) |
| `claude-code-guide` | Questions about Claude Code itself, the Agent SDK, or the Claude API | The task is about the user's own codebase, not Claude Code tooling |
| leader (no delegation) | Architecture, ambiguous requirements, security-sensitive changes, integration, final review, anything touching files another concurrent agent also owns | A cheaper, well-scoped mechanical subtask can be handed off without raising integration risk |

| Model override | Assign when | Avoid when |
| --- | --- | --- |
| `opus` | The hardest reasoning: architecture, security-sensitive design, difficult/nondeterministic debugging | A cheaper model can complete a fully specified mechanical subtask without increasing integration risk |
| `sonnet` (default) | Routine feature implementation, isolated multi-file changes, tests, refactors, API wiring | Rarely — this is the safe default; override only with a reason |
| `haiku` | Fast repository searches, inventory, simple mechanical edits, formatting, small doc updates | Ambiguous logic, architecture, security decisions, or anything needing final approval |

Omit `model` to inherit the session's current model unless a different one materially improves cost, speed, or quality. Use only model identifiers actually available in this environment (`opus`, `sonnet`, `haiku`, `fable`).

## Delegation decision

Delegate only when all are true:

1. The output is independently describable and reviewable.
2. Relevant context can be supplied in a self-contained prompt without transferring project leadership.
3. File ownership is non-overlapping, or the task is findings-only.
4. Parallel work saves time or a narrower agent (e.g. `Explore`) is a better fit than doing it inline.
5. The leader can verify the result before integration.

Keep work with the leader when it determines architecture, changes a shared contract, is too small to justify coordination overhead, depends on rapidly changing local state, or cannot be independently verified.

## Default routing examples

| Task | Subagent type | Model |
| --- | --- | --- |
| Inspect repository structure and identify test commands | `Explore` | `haiku` or default |
| Implement an isolated CRUD module with established patterns | `general-purpose` | `sonnet` (default) |
| Add regression tests for a known bug | `general-purpose` | `sonnet` (default) |
| Diagnose an intermittent race across services | leader (no delegation) | `opus` if escalating |
| Design a database migration with rollback and compatibility | `Plan`, then leader executes | `opus` |
| Review integrated changes against acceptance criteria | leader (no delegation), or `code-review` skill | default |

## Quality gates

Require the leader to reject or revise delegated work when it:

- changes files outside scope without necessity;
- lacks requested tests or evidence;
- conflicts with repository instructions or architecture;
- introduces an unhandled error, compatibility break, or security regression;
- relies on an assumption that the leader cannot validate;
- reports completion without an inspectable artifact or reproducible finding (a subagent's summary describes intent, not necessarily what happened — verify the actual diff).
