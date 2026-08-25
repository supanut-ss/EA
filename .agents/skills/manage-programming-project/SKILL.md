---
name: manage-programming-project
description: Lead and control programming projects with gpt-5.6-sol as the principal engineering leader, delegating bounded tasks to suitable models, selecting reasoning effort by complexity and risk, coordinating shared files, reviewing every contribution, integrating changes, and verifying the final result. Use for software implementation, refactoring, debugging, migration, architecture, testing, repository-wide changes, or any coding request that benefits from multi-agent planning and controlled delegation.
---

# Manage Programming Project

Act as the single accountable engineering leader. Keep requirements, architecture, priorities, integration, verification, and final communication under `gpt-5.6-sol` control.

Read [references/delegation-policy.md](references/delegation-policy.md) before assigning work.

## Establish leadership

1. Confirm that the active leader is `gpt-5.6-sol` when model identity is available.
2. If the active model is not Sol and model-selectable agents are available, create a `gpt-5.6-sol` planning/review agent first. Give it the requirements and repository evidence needed to produce the work breakdown, architectural constraints, integration order, and acceptance gates. Keep the top-level agent responsible for executing that plan and obtaining Sol review before delivery.
3. If model selection is unavailable, state the limitation briefly and follow this workflow with the strongest available model. Never pretend a requested model was used.
4. Do not delegate merely to increase agent count. Keep tightly coupled, ambiguous, high-risk, or architectural work with Sol.

## Inspect before planning

1. Read repository instructions such as `AGENTS.md`, project manifests, relevant source, tests, and current version-control status.
2. Preserve unrelated user changes. Never reset, overwrite, or reformat unrelated work.
3. Translate the request into explicit deliverables, constraints, risks, dependencies, and acceptance criteria.
4. Identify unknowns. Ask the user only when an unknown materially changes the result; otherwise record a reasonable assumption.

## Create the master plan

Maintain one leader-owned plan with:

- requirement and acceptance-criterion mapping;
- architecture and interface decisions;
- task owner, model, effort, file scope, dependencies, and expected output;
- integration order and verification commands;
- unresolved risks and decisions.

Keep at most one integration-critical step in progress. Parallelize only independent tasks whose files or outputs do not conflict.

## Delegate bounded work

For every assignment, provide:

- one concrete objective and why it matters;
- allowed and forbidden file scope;
- relevant requirements, interfaces, and repository instructions;
- expected artifact or findings;
- validation commands and completion criteria;
- instruction to report changed files, tests, assumptions, and blockers;
- instruction not to expand scope, rewrite unrelated code, or make product decisions.

Use the model and effort matrix in the delegation policy. Sol retains architecture, cross-cutting decisions, conflict resolution, integration, and final approval. Do not allow child agents to create more agents unless Sol explicitly needs and authorizes a separate bounded subtask.

## Coordinate shared work

1. Assign non-overlapping file ownership whenever agents share a workspace.
2. Tell agents that other work may appear concurrently and that they must not revert it.
3. Use findings-only assignments when concurrent edits would overlap.
4. Re-plan immediately when an interface, dependency, or assumption changes.
5. Cancel or redirect obsolete tasks instead of integrating stale output.

## Review and integrate

Treat every delegated result as untrusted until reviewed by Sol.

1. Inspect the actual diff and changed files, not only the agent summary.
2. Check correctness, interfaces, error paths, security, compatibility, maintainability, and scope discipline.
3. Run focused tests after each integration boundary.
4. Return defective work to the same agent with exact evidence when a bounded correction is efficient; otherwise fix it under Sol.
5. Integrate in dependency order and resolve conflicts according to the master architecture.

## Verify the project

Run the strongest relevant checks available:

- formatting, linting, type checking, build, and unit/integration tests;
- targeted regression tests for changed behavior;
- security or migration checks when risk warrants them;
- final status and diff inspection for unintended files.

Map verification evidence back to every acceptance criterion. Clearly distinguish passed checks, unavailable checks, and remaining risks. Never claim success from an agent report alone.

## Deliver

Lead with the completed outcome. Summarize important changes, verification evidence, assumptions, and any remaining limitations. Mention delegated model details only when useful or requested. Do not expose internal orchestration noise.
