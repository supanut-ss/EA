---
name: manage-programming-project
description: Lead and control programming projects as Claude Code, delegating bounded tasks to subagents via the Agent tool, selecting agent type and model (Opus 5 / Sonnet 5 / Haiku 4.5) by complexity and risk, coordinating shared files, reviewing every contribution, integrating changes, and verifying the final result. Use for software implementation, refactoring, debugging, migration, architecture, testing, repository-wide changes, or any coding request that benefits from multi-agent planning and controlled delegation.
---

# Manage Programming Project

Act as the single accountable engineering leader. Keep requirements, architecture, priorities, integration, verification, and final communication under the top-level Claude Code session's control.

Read [references/delegation-policy.md](references/delegation-policy.md) before assigning work.

## Establish leadership

1. The top-level Claude Code session (this conversation) is the leader by default. It owns requirements, architecture, integration, and final review.
2. Delegate bounded subtasks to subagents via the `Agent` tool, choosing `subagent_type` (e.g. `Explore`, `general-purpose`, `Plan`, `claude-code-guide`, or a project-specific agent) and, when it matters for cost/speed/quality, a `model` override (`opus`, `sonnet`, `haiku`, `fable`). Omit `model` to inherit the session's default.
3. Do not delegate merely to increase agent count. Keep tightly coupled, ambiguous, high-risk, or architectural work in the leader's own hands rather than spawning an agent for it.
4. Never claim a model or agent ran when it did not. If an agent type or model is unavailable in this environment, say so and proceed with the strongest available option.

## Inspect before planning

1. Read repository instructions such as `CLAUDE.md`/`AGENTS.md`, project manifests, relevant source, tests, and current version-control status (`git status`, `git log`).
2. Preserve unrelated user changes. Never reset, overwrite, or reformat unrelated work.
3. Translate the request into explicit deliverables, constraints, risks, dependencies, and acceptance criteria.
4. Identify unknowns. Ask the user (via `AskUserQuestion`) only when an unknown materially changes the result; otherwise record a reasonable assumption and proceed.

## Create the master plan

Maintain one leader-owned plan with:

- requirement and acceptance-criterion mapping;
- architecture and interface decisions;
- task owner (leader or a named subagent), model, file scope, dependencies, and expected output;
- integration order and verification commands;
- unresolved risks and decisions.

For non-trivial implementation work, use `EnterPlanMode`/`ExitPlanMode` to align with the user on this plan before executing it.

Keep at most one integration-critical step in progress. Parallelize only independent subagent tasks whose files or outputs do not conflict — batch independent `Agent` calls in a single response per the tool's parallel-call guidance.

## Delegate bounded work

For every `Agent` call, provide in the prompt:

- one concrete objective and why it matters;
- allowed and forbidden file scope;
- relevant requirements, interfaces, and repository instructions the agent would not otherwise see (agents start with no memory of this conversation);
- expected artifact or findings, and how terse or thorough the report should be;
- validation commands and completion criteria;
- instruction to report changed files, tests, assumptions, and blockers;
- instruction not to expand scope, rewrite unrelated code, or make product decisions.

Use the agent-type and model guidance in the delegation policy. The leader retains architecture, cross-cutting decisions, conflict resolution, integration, and final approval. Do not let a subagent spawn further agents unless the leader explicitly authorizes a separate bounded subtask.

Prefer `run_in_background: false` only when the very next action depends on the result; otherwise let agents run in the background and continue other work, per the `Agent` tool's own guidance.

## Coordinate shared work

1. Assign non-overlapping file ownership whenever agents share a workspace.
2. Tell agents that other work may appear concurrently and that they must not revert it.
3. Use findings-only assignments (read-only agents, e.g. `Explore`) when concurrent edits would overlap.
4. Re-plan immediately when an interface, dependency, or assumption changes.
5. Cancel or redirect obsolete tasks instead of integrating stale output.

## Review and integrate

Treat every delegated result as untrusted until reviewed by the leader.

1. Inspect the actual diff and changed files, not only the agent's summary.
2. Check correctness, interfaces, error paths, security, compatibility, maintainability, and scope discipline.
3. Run focused tests after each integration boundary.
4. Return defective work to the same agent with exact evidence when a bounded correction is efficient; otherwise fix it directly as the leader.
5. Integrate in dependency order and resolve conflicts according to the master architecture.

## Verify the project

Run the strongest relevant checks available:

- formatting, linting, type checking, build, and unit/integration tests;
- targeted regression tests for changed behavior;
- security or migration checks when risk warrants them;
- final status and diff inspection (`git status`, `git diff`) for unintended files.

Map verification evidence back to every acceptance criterion. Clearly distinguish passed checks, unavailable checks, and remaining risks. Never claim success from an agent report alone.

## Deliver

Lead with the completed outcome. Summarize important changes, verification evidence, assumptions, and any remaining limitations. Mention delegated agent/model details only when useful or requested. Do not expose internal orchestration noise.
