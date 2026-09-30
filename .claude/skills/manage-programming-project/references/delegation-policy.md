# Delegation Policy

## Model selection

| Model | Assign when | Avoid when |
| --- | --- | --- |
| `haiku` (Haiku 4.5) | Repository searches, file inventory, mechanical edits, formatting, small isolated tests or docs, reproducible command checks | Ambiguous logic, architecture, security decisions, difficult debugging, final approval |
| `sonnet` (Sonnet 5.5) | Default leader and workhorse: routine-to-complex implementation, debugging, tests, integration, review, final verification | A cheaper model can finish a fully specified subtask, or the work needs deeper reasoning |
| `opus` (Opus 5.5) | Hard architecture, ambiguous requirements, cross-system failure analysis, security-sensitive or high-risk design review | Routine implementation, mechanical work, or a duplicate review that adds no confidence |
| `fable` (Fable 5.1) | Rare last resort for very high-consequence decisions still unresolved after Opus at high effort | Anything Opus can resolve; never the default |

Prefer the inherited model unless another one materially improves cost, speed, or quality. Use only model identifiers the runtime exposes.

## Effort selection

| Effort | Use for | Examples |
| --- | --- | --- |
| `low` | Clear, deterministic, low-risk work | Locate symbols, inventory files, mechanical rename, small comment |
| `medium` | Routine work with familiar patterns | Fix a known bug, add a focused test, small endpoint |
| `high` | Real uncertainty or multi-component integration risk | Nondeterministic bug, multi-file feature, auth or data-flow review |
| `xhigh` | Cross-cutting architecture, multi-system reasoning | Major migration, concurrency across services |
| `max` | Rare: high/xhigh still leaves consequential uncertainty | Repeated failed diagnosis, high-impact design tradeoff |

The Agent tool accepts `model` but has no effort parameter: a subagent inherits the session effort or the effort in its agent definition. Choose the model to control cost, and state the intended depth in the prompt (for example "quick lookup, no deep analysis"). The efforts above apply to the leader session (changed by the user) and to agent definitions that set `effort`.

Start at the lowest effort likely to meet the acceptance criteria. Raise it only on new evidence (repeated failures, contradicted assumptions), not because more files are involved. Support varies by model (for example `xhigh` and `max` may be missing on smaller models): use only efforts the selected model exposes, and fall back to the next lower level, ordinarily `high`, when one is unavailable. Do not assume a level is supported without checking the model picker.

## Delegation decision

Delegate only when all hold:

1. The output is independently describable and reviewable.
2. Context can be supplied without transferring leadership.
3. File ownership is non-overlapping, or the task is findings-only.
4. Parallelism or specialist attention saves more than the added prompt, coordination, and review cost.
5. The leader can verify the result before integration.

Keep work with the leader when it sets architecture, changes a shared contract, is too small to justify coordination, depends on fast-changing local state, or cannot be verified independently. Consult Opus for unusually high complexity while the leader keeps integration ownership.

## Token and context control

- Do simple, localized, or mechanical work directly rather than delegating.
- Reuse findings already in the conversation; read a file once and revisit only changed parts.
- Batch related searches into one findings-only assignment; avoid duplicate agents and duplicate reviews.
- Keep prompts and reports compact: cite paths and line numbers, do not paste whole files.
- Filter command output to relevant lines; broaden or rerun only when evidence requires it.

## Default routing

| Task | Model | Effort |
| --- | --- | --- |
| Find affected paths and test commands | haiku or leader | low |
| Mechanical edit or formatting | leader; haiku only if it saves effort | low |
| Isolated CRUD module with established patterns | sonnet | medium |
| Known bug plus regression test | sonnet | medium |
| Multi-component feature | sonnet | high |
| Intermittent race across services | sonnet lead, opus consult | xhigh |
| Migration with rollback and compatibility | sonnet, opus consult for tradeoffs | xhigh |
| Review integrated changes against criteria | sonnet | high |
| Critical decision unresolved after Opus | fable | max |

## Quality gates

Reject or revise delegated work that:

- changes files outside scope without necessity;
- lacks requested tests or evidence;
- conflicts with repository instructions or architecture;
- introduces an unhandled error, compatibility break, or security regression;
- rests on an assumption the leader cannot validate;
- reports completion without an inspectable artifact or reproducible finding.
