# Autonomous dispatch mandate design

Audience: maintainer architecture.

## Decision

Firstmate gains one primary-owned active autonomous mandate.

A mandate is durable, reviewed authority for an exact set of reviewed native tasks, bound to their launched incarnations during activation.

Approving a reviewed autonomous dispatch creates that mandate and starts its members in one activation operation.

Version one is local-first.

Primary and local secondmate homes may read one live primary mandate.

Remote secondmates receive no grant and cannot use mandate authority in this version.

Native task records, task lifecycle, task delivery modes, backlog state, captain holds, PR state, and deployment mechanisms remain their existing owners.

The mandate adds authority only.

## Goals and fixed boundaries

An active mandate authorizes maximum routine autonomy within reviewed membership.

It permits best-judgment routine decisions, green merges, and deployment to every environment listed for each reviewed member.

It does not authorize a red-check waiver, credential or login use, destructive action, irreversible action, security-sensitive choice, unrelated scope, or spend beyond its recorded cap.

The visible default cap is four concurrent workers when review does not state another cap.

Any non-default cap is displayed and approved as part of that reviewed dispatch.

An exact captain instruction still outranks a mandate.

A mandate never broadens a task's delivery mode, project posture, no-mistakes authority, or existing approval needed outside its named authority categories.

It never bypasses or deletes captain-hold lifecycle.

For an in-scope decision it authorizes Firstmate to answer that lifecycle through its existing owner and record the answer.

Absent, expired, revoked, malformed, unreadable, mismatched, or activating mandate state grants nothing.

One active mandate exists per primary home.

Creating another mandate requires its predecessor to be archived or explicitly revoked.

## Components and ownership

`bin/fm-autonomous-mandate.sh` is proposed as sole owner of mandate schema, proposal validation, confirmation, activation transaction, active and archive placement, locking, authority queries, revocation, and recovery.

`assemble-dispatch` remains owner of gathering candidate work and review material.

`run-dispatch` remains owner of task launch and calls mandate activation instead of separately approving then launching autonomous members.

`end-dispatch` remains owner of dispatch completion and asks the mandate owner to archive only after every member reaches a terminal native lifecycle outcome.

Native task records remain owner of task identity, current lifecycle, mode, yolo posture, worktree, PR binding, and task history.

`bin/fm-pr-merge.sh`, `bin/fm-merge-local.sh`, and any deployment entrypoint remain action owners.

Those action owners call the mandate owner's read-only authority query immediately before their existing action-specific checks and keep their existing checks.

`bin/fm-afk-contract.sh` remains sole owner of away-posture authority and its lock.

An active mandate does not replace away posture, captain holds, or yolo.

`bin/fm-config-inherit-lib.sh` remains owner of inherited local material.

It must not mirror mandate bytes because a copied grant delays revocation.

`data/captain-opinions.md` is primary-owned advisory memory and is not mandate authority.

## Record placement and schema

Primary private record paths are:

```text
data/autonomous-mandates/active.json
data/autonomous-mandates/proposed.json
data/autonomous-mandates/activating.json
data/autonomous-mandates/archive/amd-20260920T120000Z-a1b2c3.json
```

The owner writes regular single-linked files below a non-symlinked directory with atomic same-filesystem replacement.

The owner holds one primary-home mandate lock across every mutation and each action query plus its immediate authorization-sensitive handoff.

`active.json` uses schema `fm-autonomous-mandate.v1` and contains:

```json
{
  "schema": "fm-autonomous-mandate.v1",
  "id": "amd-20260920T120000Z-a1b2c3",
  "state": "active",
  "primary_home": "/absolute/primary/home",
  "approved_at": "2026-09-20T12:00:00Z",
  "approved_by": "captain",
  "expires_at": null,
  "spend_cap": {"max_concurrent_workers": 4},
  "authority": {
    "routine_decisions": "best-judgment",
    "green_merges": true,
    "deployments": "reviewed-member-environments"
  },
  "members": [
    {
      "home": "secondmate:payments",
      "task_id": "task-id",
      "project": "project-name",
      "mode": "no-mistakes|direct-PR|local-only",
      "reviewed_revision": "immutable reviewed dispatch revision",
      "deploy_environments": ["staging", "production"],
      "excluded_deploy_environments": [],
      "spawn_gen": "s..."
    }
  ],
  "activation": {
    "transaction_id": "activation id",
    "started_at": "2026-09-20T12:00:00Z",
    "completed_at": "2026-09-20T12:01:00Z"
  }
}
```

`id`, timestamps, primary home, and every member identity are mandatory.

Before activation, member `home` and `task_id` identify exact reviewed native work.

Activation records the native `spawn_gen` receipt, after which `home`, `task_id`, and `spawn_gen` form identity.

Duplicate task ownership, unknown modes, blank reviewed revisions, invalid environments, an environment listed in both deployment lists, a discovered environment listed in neither list, cap values outside positive integers, and a finite expiry at or before approval are invalid.

`expires_at` is an ISO 8601 timestamp or null.

It is optional or null when review selects completion or explicit-cutoff termination only.

The reviewed revision is dispatch-owned immutable source identity, not a task record replacement.

The deployment lists partition every environment review identifies for that task.

`deploy_environments` grants deployment authority.

`excluded_deploy_environments` records review exclusions.

Neither list may be inferred from a project name, file path, or workflow discovered after review.

The active record is immutable except state transition metadata added by its sole owner.

Changing members, authority, cap, expiry, or environments creates a new reviewed proposal rather than editing active authority.

Archived records retain complete final state, revocation or expiry reason, member terminal summaries, and archive timestamp.

## Proposal, confirmation, and activation

Assemble-dispatch inventories every environment each reviewed task uses and produces a reviewed proposal with exact members, each member's reviewed revision, allowed and excluded environment lists, cap, optional expiry, and explicitly bounded authority.

Review displays every member, its home, task identity, allowed and excluded deployment environments, cap, expiry, permitted actions, and permanent exclusions.

Captain confirmation names that reviewed proposal exactly.

Confirmation atomically records the approval and begins activation.

There is no approve-now, start-later state.

The owner writes `activating.json` before any launch using immutable approved proposal bytes and a transaction id.

Activating state is visible but grants zero autonomous authority.

Run-dispatch launches only members in that exact activation record and records each generated native `spawn_gen` as a durable launch receipt bound to its reviewed task.

After every receipt validates against native task state and cap accounting, the owner atomically replaces activation state with `active.json`.

No action can use mandate authority before that publication.

This makes approval and authority activation atomic even though separate process launches cannot be physically atomic.

Partial-launch recovery preserves existing launched members as native tasks without mandate authority.

Recovery resumes only missing exact members from the immutable activation record, never adds, substitutes, or re-reviews members.

Recovery does not discard launched work.

If a missing member cannot safely launch, activation remains recoverable and no active grant appears.

An explicit captain revocation during activation deletes authority immediately, marks activation revoked, and prevents further launches.

## Authority queries and action checks

Action owners query by caller home, task id, spawn generation, requested action, and, for deployment, exact environment.

The mandate owner grants only when all conditions hold:

1. Caller resolves to primary home or a validated local secondmate whose `.fm-secondmate-parent` binding names that primary home.
2. Active record is readable, schema-valid, unexpired, and not revoked.
3. Caller task exactly matches one member identity and native task record still names that generation.
4. Requested action is one recorded authority permits.
5. Requested deployment environment exactly appears in that member's reviewed allowed environment list.
6. Concurrent active member work remains within mandate cap.
7. No stronger existing owner refuses action.

The query returns `grant`, `deny`, or `unavailable` with machine-readable reason.

Action owners treat `deny` and `unavailable` identically for authority: no autonomous action.

They may continue only under independent existing captain authority.

Maximum best judgment covers every in-scope technical or product decision native lifecycle would otherwise hold for captain answer, except permanent exclusions and genuine scope expansion.

For those decisions Firstmate answers through existing captain-hold lifecycle and records that answer through its existing owner.

The mandate neither bypasses nor deletes the hold lifecycle.

Every grant-consuming action appends a decision record with mandate id, member identity, action, result, timestamp, and existing action evidence pointer.

The mandate owner owns decision-record format and retention.

It records denied and unavailable authority attempts too, without changing task state.

### Merge checks

Before green merge, existing merge owner validates open PR or local branch, exact current head, delivery-mode rules, captain hold, and green checks.

Mandate authority can satisfy only routine merge approval for exact active member.

`--allow-red` remains forbidden.

Away-posture restrictions remain enforced and use their existing lock.

Mandate query and merge handoff share mandate lock so revocation cannot race an authorized forge handoff.

### Deployment checks

Deployment entrypoints must identify task identity and environment before deployment begins.

They query mandate authority for that exact environment and keep every existing deployment-specific check.

Assembly inventories every environment each member task uses, including production when task uses production.

Review grants every inventoried environment unless it records that environment in the member's excluded list.

A later-discovered environment requires new review because it was outside reviewed task-environment set.

No later discovered environment, inferred target, credential operation, rollback, destructive migration, irreversible release, or security-sensitive choice is authorized by that list.

Such work follows existing attended authority even when deployment itself was authorized.

## Local secondmate access

Local secondmate reads resolve parent route through `bin/fm-secondmate-parent-lib.sh`.

Only a route explicitly marked local and bound to the record's `primary_home` can read primary mandate paths.

Secondmates never write, copy, cache as authority, or propagate mandate records.

Every local action query reads active primary bytes while mandate lock is held.

A missing parent, foreign parent, remote route, unreadable primary path, invalid file identity, or lock failure returns unavailable.

Remote grants, remote mandate reads, remote activation, and remote deployment authorization are excluded from version one.

## Expiry, revocation, completion, and archive

When finite, expiry is absolute at `expires_at` and requires no polling to take effect because every authority query checks it.

A null or omitted expiry leaves completion and explicit cutoff as mandate termination paths.

Explicit captain revocation is immediate at confirmation of command receipt.

Revocation atomically replaces active authority with a revoked archive-intent record under mandate lock before any further action query can grant.

In-flight external action cannot be recalled, but no new handoff may begin after revocation.

All running members continue under native lifecycle with autonomous authority removed.

When every exact member has a terminal native lifecycle outcome, end-dispatch asks owner to archive mandate automatically.

Archive verifies every member against native history rather than a worker status sentence.

An incomplete, unreadable, or replaced member prevents automatic archive and leaves no silent authority extension after expiry.

An expired or revoked record may be archived without waiting for member completion because it grants nothing.

Archive removes active and activating authority files only after final archive publication succeeds.

## Captain opinions

`data/captain-opinions.md` stores vague captain stances that help judgment but never grant authority.

It is primary-owned.

Local secondmate homes receive a read-only primary copy through existing inherited-local-material convergence, with same quarantine and byte-validation behavior used for `data/captain-shared.md`.

Remote opinion grants do not exist because opinions are advisory only.

Remote secondmate homes receive read-only inherited opinion copies through existing convergence whenever that transport supports inherited local material.

The primary file header states primary ownership, secondmate read-only status, advisory-only semantics, and route for discovered changes back to primary.

Each opinion has one scoped entry containing scope, stance, strength, rationale, and last-confirmed date.

Strength is one of `weak`, `default`, or `strong` and indicates confidence for judgment, not authority.

Scope must name bounded affected project, domain, task class, or decision class.

Exact instructions, explicit mandate membership and limits, safety exclusions, native task contracts, and current facts outrank opinions.

An opinion contradicting stronger authority is ignored for that decision and recorded as contradiction evidence when material.

Conflicting opinions at same precedence produce no autonomous choice and request clarification or use an independently authorized conservative path.

Stale or missing last-confirmed date makes an opinion advisory only with lower confidence and never blocks an exact instruction.

Opinions can guide how a mandate-authorized best-judgment decision is made, but cannot create membership, authorize merge or deployment, release a hold, raise spend, extend expiry, or bypass a refusal.

## Compatibility and migration

No existing task, away record, captain preference, secondmate route, delivery mode, or merge behavior changes until a reviewed mandate is confirmed.

Homes without mandate records preserve current behavior.

Existing task records need no migration because mandate membership references their current durable identity.

Legacy tasks without a readable spawn generation cannot enter a reviewed mandate until relaunched or otherwise assigned a new native identity through existing lifecycle owner.

Existing secondmate homes gain opinions propagation only after primary file exists and convergence validates it.

An absent opinions file converges as absent.

Malformed mandate or opinions files are reported with path and validation reason, never guessed or repaired from prose.

Malformed active mandate denies autonomous authority without altering native work.

Malformed primary opinions input is not copied to secondmates and does not stop unrelated work.

## First-version exclusions

Version one excludes remote grants and remote live mandate reads.

Version one excludes multiple concurrent active mandates, nested mandates, member edits after review, approval inheritance, semantic parsing of vague opinions, automatic credential handling, red-check waivers, destructive or irreversible operations, security-sensitive choices, and spend over cap.

Version one does not replace no-mistakes, captain-hold lifecycle, PR merge, local merge, deployment implementation, task records, away posture, or secondmate routing.

## Focused executable verification

Add portable tests for record parse and validation, malformed and unavailable denial, exact member and generation matching, cap enforcement, environment membership, expiry, immediate revocation, archive eligibility, and decision-record idempotence.

Add activation tests that prove no grant before all exact launch receipts, crash recovery resumes only missing reviewed members, and revocation halts recovery without discarding launched tasks.

Add local secondmate tests that prove valid local parent reads work and remote, foreign, unreadable, copied, and stale authority paths deny.

Extend merge tests to prove green exact members can pass mandate approval while red checks, holds, absent members, and post-revocation handoffs refuse.

Add deployment authorization adapter tests proving only reviewed exact environments pass.

Add opinions propagation tests for primary ownership, read-only secondmate copy, quarantine on divergence, missing-source convergence, precedence, contradiction, and no-authority behavior.

Run `bin/fm-doc-audience-check.sh` for documentation classification and links.
