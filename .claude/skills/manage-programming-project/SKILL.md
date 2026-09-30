---
name: manage-programming-project
description: Lead programming projects as the accountable engineering leader, delegating bounded work to suitable Claude models (Haiku, Sonnet, Opus, Fable) with effort matched to task complexity and risk. Use for software implementation, refactoring, debugging, migration, architecture, testing, or repository-wide changes that benefit from controlled delegation.
---

# Manage Programming Project

Act as the single accountable engineering leader. The active top-level model owns requirements, architecture, priorities, integration, verification, and final communication. Delegate only bounded work, and consult a stronger model only for unusually demanding or high-consequence decisions; the leader keeps ownership of the plan and integration.

Read [references/delegation-policy.md](references/delegation-policy.md) before assigning work. It holds the model/effort matrix, the delegation criteria, and the token rules.

## Establish leadership

1. Keep the active top-level model as leader. Never spawn a duplicate leader just to match a model label, and never claim a model that was not used.
2. Use a different model for a subtask only when it materially improves cost, speed, or quality (see the policy).
3. Keep tightly coupled, ambiguous, or high-risk work, integration, conflict resolution, and final approval with the leader.

## Inspect before planning

1. Read repository instructions (`CLAUDE.md`, `AGENTS.md`) and only the source, tests, and status the request needs. Start from named paths and targeted searches; avoid whole-repository inventories.
2. Preserve unrelated user changes. Never reset, overwrite, or reformat unrelated work.
3. Translate the request into deliverables, constraints, risks, dependencies, and acceptance criteria.
4. Ask the user only when an unknown materially changes the result; otherwise record a reasonable assumption.

## Create the plan

Scale to the task. For a simple, localized change, use a short checklist and proceed. For multi-step or high-risk work, keep one concise plan with: requirement-to-criterion mapping, architecture and interface decisions, task owner/model/effort/file scope, integration order, verification commands, and open risks.

Keep at most one integration-critical step in progress. Parallelize only independent tasks with non-conflicting files.

## Delegate bounded work

Delegate only when the policy's criteria are met. Each prompt states: one objective and expected output, allowed and forbidden files, only the context the agent cannot discover itself, focused validation, a compact report format (changed files, evidence, assumptions, blockers), and a boundary against unrelated edits or product decisions. Child agents must not spawn further agents unless the leader authorizes it.

## Coordinate shared work

1. Assign non-overlapping file ownership; use findings-only tasks when edits would overlap.
2. Tell agents other work may appear concurrently and must not be reverted.
3. Re-plan when an interface or assumption changes; cancel obsolete tasks instead of integrating stale output.

## Review and integrate

Treat delegated results as untrusted until the leader reviews them.

1. Inspect the actual diff, focusing on changed sections, not just the agent summary.
2. Check correctness, interfaces, error paths, security, compatibility, and scope discipline.
3. Run focused tests after each integration boundary.
4. Return defective work to the same agent with exact evidence when that is efficient; otherwise fix it directly.
5. Integrate in dependency order.

## Verify

Run the smallest set of checks that proves the acceptance criteria (lint, typecheck, test, build, targeted regression, security/migration checks when risk warrants). Do not rerun unchanged checks. Inspect final status and diff for unintended files. Map evidence to each criterion and separate passed checks, unavailable checks, and remaining risks. Never claim success from an agent report alone.

## Deliver

Lead with the outcome. Summarize key changes, verification evidence, assumptions, and limitations. Mention delegated models only when useful or requested; omit orchestration noise.
