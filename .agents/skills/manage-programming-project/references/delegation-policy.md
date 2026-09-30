# Delegation Policy

## Model selection

| Model | Assign when | Avoid when |
| --- | --- | --- |
| `gpt-6.1-sol` | Preferred project leader for coding, architecture, implementation, debugging, integration, review, and verification | Fast, fully specified subtasks that `gpt-6-luna` can complete reliably |
| `gpt-6-astra` | Bounded consultation for unusually difficult architecture, severe ambiguity, cross-system failure analysis, and high-consequence design or security review | Routine implementation, mechanical work, or duplicate review without meaningful added confidence |
| `gpt-6-luna` | Fast, bounded searches, inventory, mechanical edits, formatting, clear isolated tests or documentation, and reproducible command checks | Ambiguous logic, architecture, security decisions, difficult debugging, final approval, or work faster to do directly |
| `gpt-6-sol` | Workhorse fallback when `gpt-6.1-sol` is unavailable or explicitly requested | A newer suitable model is available and materially improves the work |

Use only model identifiers exposed by the current runtime. Prefer the inherited model when switching adds no meaningful quality or speed; do not create a duplicate leader merely to match a preferred identifier. A model with a higher effort setting is not a substitute for choosing a model suited to the task.

## Effort selection

| Effort | Use for | Examples |
| --- | --- | --- |
| `low` | Clear, deterministic, low-risk tasks with little uncertainty | Locate symbols, inventory files, make a mechanical rename, update a small comment |
| `medium` | Routine implementation with familiar patterns and limited scope | Fix a known bug, add a focused test, update a small endpoint or typed model |
| `high` | Meaningful uncertainty, integration risk, or behavior spanning several components | Debug a nondeterministic issue, implement a multi-file feature, review an auth or data-flow change |
| `xhigh` | Cross-cutting architecture or difficult multi-system reasoning | Plan a major migration, resolve concurrency across services, analyze a distributed failure |
| `max` | Rare cases where high or xhigh still leaves consequential uncertainty | Repeated failed diagnosis or a high-impact design decision with unresolved tradeoffs |
| `ultra` | Exceptional last resort for very high-consequence work, only when supported and justified | A critical architecture or security decision still unresolved at max |

Choose effort after assessing scope, uncertainty, reversibility, and consequence. Start at the lowest level likely to meet the acceptance criteria; raise it only when evidence shows the work needs more reasoning. Do not use `max` or `ultra` by default, raise effort just because more files are involved, or repeat the same analysis at a higher effort without new evidence.

Use only efforts exposed for the selected model. In the current model menu, `gpt-6.1-sol`, `gpt-6-astra`, and `gpt-6-sol` support `low`, `medium`, `high`, `xhigh`, `max`, and `ultra`; `gpt-6-luna` supports `low`, `medium`, `high`, and `max`. Recheck the menu when it differs from this list.

## Token and context control

- Handle simple, localized, mechanical work directly when delegation would add more setup and review than value.
- Reuse findings and plans already available in the conversation or repository. Read relevant files once, then revisit only changed files or details required by new evidence.
- Batch related searches and questions. Split work only across independent tasks with clear file boundaries; avoid duplicate agents and duplicate reviews.
- Keep prompts and reports compact: cite paths and line numbers instead of pasting whole files, include only task-specific context, and request findings, changed paths, checks, assumptions, and blockers without a long narrative.
- Filter large command output to the relevant lines. Broaden searches, rerun checks, or increase effort only when the current evidence is insufficient or a failure requires it.

## Delegation decision

Delegate only when all are true:

1. The output is independently describable and reviewable.
2. Relevant context can be supplied without transferring project leadership.
3. File ownership is non-overlapping, or the task is findings-only.
4. Parallel work or specialist attention is likely to save more time or improve quality than the added prompt, coordination, and review cost.
5. The active top-level leader can verify the result before integration.

Keep work with the active leader when it determines architecture, changes a shared contract, is too small to justify coordination, depends on rapidly changing local state, or cannot be independently verified. Consult Astra for unusually high complexity or consequences while keeping integration ownership with the active leader.

## Default routing examples

| Task | Model | Effort |
| --- | --- | --- |
| Inspect affected paths and identify relevant test commands | gpt-6-luna or active leader | low |
| Make a mechanical edit or format a file | active leader; use gpt-6-luna only if delegation saves effort | low |
| Implement an isolated CRUD module with established patterns | gpt-6.1-sol | medium |
| Fix a known bug and add a focused regression test | gpt-6.1-sol | medium |
| Implement a multi-component feature | gpt-6.1-sol | high |
| Trace a complex intermittent race across services | gpt-6.1-sol lead; gpt-6-astra consult | xhigh |
| Design a cross-system migration with rollback and compatibility | gpt-6.1-sol; consult Astra for architectural tradeoffs | xhigh |
| Review integrated changes against acceptance criteria | gpt-6.1-sol | high |
| Reassess a critical decision after high or xhigh failed to resolve uncertainty | gpt-6-astra | max; ultra only if supported and justified |

## Quality gates

Require the leader to reject or revise delegated work when it:

- changes files outside scope without necessity;
- lacks requested tests or evidence;
- conflicts with repository instructions or architecture;
- introduces an unhandled error, compatibility break, or security regression;
- relies on an assumption that the leader cannot validate;
- reports completion without an inspectable artifact or reproducible finding.
