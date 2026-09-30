---
name: manage-programming-project
description: Lead programming projects with gpt-6.1-sol as the preferred engineering lead, use gpt-6-astra for exceptionally demanding decisions, and delegate bounded work to suitable available models with effort matched to task complexity and risk. Use for software implementation, refactoring, debugging, migration, architecture, testing, or repository-wide changes that benefit from controlled delegation.
---

# Manage Programming Project

Act as the single accountable engineering leader. Prefer `gpt-6.1-sol` for project leadership when the runtime exposes it. Keep requirements, architecture, priorities, integration, verification, and final communication with the active top-level leader. Consult `gpt-6-astra` for unusually demanding architectural decisions, severe ambiguity, or high-consequence reviews when model selection is available; the top-level leader retains ownership of the plan and integration.

Read [references/delegation-policy.md](references/delegation-policy.md) before assigning work.

## Establish leadership

1. Prefer `gpt-6.1-sol` as the engineering lead when it is available and model selection materially helps. If it is unavailable, keep the active top-level model accountable and use the most suitable exposed model; never claim to have used an unavailable model.
2. If another model is leading and model-selectable agents are available, use `gpt-6.1-sol` for planning or review only when that adds meaningful value. Consult `gpt-6-astra` for unusually difficult or high-consequence decisions, and use `gpt-6-luna` for clear, bounded, low-risk work.
3. Do not create an agent solely to satisfy a model label. Do not delegate merely to increase agent count. Keep tightly coupled work, integration, conflict resolution, and final approval with the active top-level leader.

## Inspect before planning

1. Read the repository instructions and only the source, tests, and status needed for the request. Start with named paths and targeted searches; avoid whole-repository inventories or rereading unchanged files unless evidence calls for them.
2. Preserve unrelated user changes. Never reset, overwrite, or reformat unrelated work.
3. Translate the request into explicit deliverables, constraints, risks, dependencies, and acceptance criteria.
4. Identify unknowns. Ask the user only when an unknown materially changes the result; otherwise record a reasonable assumption.

## Create the master plan

Scale planning to the task. For a simple, localized change, use a short checklist and proceed without a full plan. For multi-step or high-risk work, maintain one concise, leader-owned plan with:

- requirement and acceptance-criterion mapping;
- architecture and interface decisions;
- task owner, model, effort, file scope, dependencies, and expected output;
- integration order and verification commands;
- unresolved risks and decisions.

Keep at most one integration-critical step in progress. Parallelize only independent tasks whose files or outputs do not conflict.

## Delegate bounded work

For each worthwhile assignment, provide a concise prompt with:

- one objective, expected output, acceptance criteria, and allowed or forbidden files;
- relevant requirements, interfaces, and only the context the agent cannot discover from the repository;
- focused validation and a concise report format for changed files, evidence, assumptions, and blockers;
- a boundary against unrelated edits or product decisions.

Use the model and effort matrix in the delegation policy. Delegate only when expected speed or quality gains exceed context, coordination, and review costs. The active top-level leader retains architecture, cross-cutting decisions, conflict resolution, integration, and final approval. Do not allow child agents to create more agents unless the leader explicitly needs and authorizes a separate bounded subtask.

## Coordinate shared work

1. Assign non-overlapping file ownership whenever agents share a workspace.
2. Tell agents that other work may appear concurrently and that they must not revert it.
3. Batch related read-only questions into one findings-only assignment; use findings-only work when concurrent edits would overlap.
4. Re-plan immediately when an interface, dependency, or assumption changes.
5. Cancel or redirect obsolete tasks instead of integrating stale output. Avoid repeated status checks when no result has changed.

## Review and integrate

Treat every delegated result as untrusted until reviewed by the active top-level leader.

1. Inspect the actual diff and changed files, not only the agent summary; focus on changed sections instead of reopening whole unchanged files.
2. Check correctness, interfaces, error paths, security, compatibility, maintainability, and scope discipline.
3. Run focused tests after each integration boundary.
4. Return defective work to the same agent with exact evidence when a bounded correction is efficient; otherwise fix it under the active top-level leader.
5. Integrate in dependency order and resolve conflicts according to the master architecture.

## Verify the project

Run the smallest set of checks that demonstrates the acceptance criteria. Choose relevant checks; do not run every category by default, and do not rerun unchanged checks without a reason:

- formatting, linting, type checking, build, and unit/integration tests;
- targeted regression tests for changed behavior;
- security or migration checks when risk warrants them;
- final status and diff inspection for unintended files.

Map verification evidence back to every acceptance criterion. Clearly distinguish passed checks, unavailable checks, and remaining risks. Never claim success from an agent report alone.

## Deliver

Lead with the completed outcome. Summarize important changes, verification evidence, assumptions, and any remaining limitations. Mention delegated model details only when useful or requested. Do not expose internal orchestration noise.
