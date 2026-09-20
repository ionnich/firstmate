# Autonomous Dispatch Mandate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one primary-owned mandate for reviewed local work.

**Architecture:** `bin/fm-autonomous-mandate.sh` owns records, locks, activation, queries, revocation, archive, and evidence.

**Architecture:** Native task records, spawn, holds, merges, deployments, and inheritance retain ownership and call narrow seams.

**Tech Stack:** Bash, jq, tasks-axi, existing portable test harness.

**Spec:** `docs/superpowers/specs/2026-09-20-autonomous-dispatch-mandate-design.md`

## Global Constraints

- One active mandate per primary home.
- Default cap is four concurrent workers unless review records another positive cap.
- Identity is reviewed `home` plus `task_id`, then exact `spawn_gen` after launch.
- Remote secondmates never receive mandate authority or live mandate reads.
- Opinions are primary-owned, read-only in secondmate homes, advisory only, and use `weak`, `default`, or `strong`.
- Never authorize red checks, credentials, destructive or irreversible work, security-sensitive choices, unrelated scope, or spend above cap.
- Answer held decisions through `fm-captain-hold.sh answer`, never around that lifecycle.
- Use atomic regular single-linked private records and existing lock helpers.

## File map

- Create `bin/fm-autonomous-mandate.sh` and `tests/fm-autonomous-mandate.test.sh`.
- Modify `bin/fm-spawn.sh:368-4055`, `bin/fm-teardown.sh:329-3494`, `bin/fm-pr-merge.sh:860-990`, `bin/fm-merge-local.sh:65-125`, and `bin/fm-captain-hold.sh:1001-1119`.
- Modify `bin/fm-config-inherit-lib.sh:67-101,226-493`, `bin/fm-remote-inherit-push.sh:31-82`, and `bin/fm-remote-inherit.sh:110-169`.
- Create `.agents/skills/autonomous-dispatch/SKILL.md`.
- Modify `AGENTS.md`, `docs/configuration.md`, `docs/architecture.md`, `docs/scripts.md`, and `docs/documentation-audiences.json`.

### Task 1: Create mandate owner and schema validation

**Files:** Create `bin/fm-autonomous-mandate.sh` and `tests/fm-autonomous-mandate.test.sh`.

**Interfaces:** Add `propose`, `confirm`, `launch-receipt`, `activate`, `query`, `answer`, `revoke`, `archive`, `recover`, and `status` subcommands.

- [ ] Write public-command tests that accept valid `fm-autonomous-mandate.v1` proposal and deny absent, malformed, symlinked, hardlinked, duplicate, unreadable, and cross-device records.
- [ ] Run `bin/fm-test-run.sh tests/fm-autonomous-mandate.test.sh` and confirm it fails because owner is absent.
- [ ] Implement `data/autonomous-mandates/{proposed,activating,active}.json` plus `archive/<id>.json` under one primary-home lock.
- [ ] Validate unique reviewed `(home, task_id)`, positive cap, ISO timestamp or null expiry, and exact allowed/excluded environment partition.
- [ ] Persist immutable reviewed launch arguments per member so recovery replays only reviewed spawns.
- [ ] Add cap, null-expiry, duplicate-member, and environment-partition cases.
- [ ] Run `bin/fm-test-run.sh tests/fm-autonomous-mandate.test.sh && shellcheck bin/fm-autonomous-mandate.sh` and expect PASS.
- [ ] Commit `feat: add autonomous mandate record owner` with owner, test, and `docs/scripts.md` pointer.

### Task 2: Activate exact members and recover safely

**Files:** Modify `bin/fm-autonomous-mandate.sh`, `bin/fm-spawn.sh:368-4055`, `bin/fm-teardown.sh:329-3494`, `tests/fm-spawn-batch.test.sh`, and `tests/fm-teardown.test.sh`.

**Interfaces:** `confirm --id <mandate-id>` creates activating state, and `launch-receipt --id <mandate-id> --home <home> --task <task-id> --spawn-gen <spawn-gen>` binds native identity.

- [ ] Write tests proving confirmation begins activation, no query grants before every receipt, and partial launch leaves launched work intact without authority.
- [ ] Run mandate test and confirm failure because activation and receipt paths are absent.
- [ ] Make `fm-spawn.sh` verify exact reviewed member tuple before launch and register returned native `spawn_gen` only through mandate owner.
- [ ] Publish `active.json` only after every receipt matches native home, task, mode, project, and generation.
- [ ] Make `recover` launch only receipt-missing members, never substitute membership, and stop new launch after revocation.
- [ ] After existing teardown proves terminal native outcome, request archive for exact member.
- [ ] Archive automatically only after all members have terminal native evidence, while expired or revoked records can archive immediately.
- [ ] Add crash-between-launch-and-receipt, duplicate-receipt, replacement-generation, cutoff, null-expiry, and revocation cases.
- [ ] Run mandate, spawn-batch, and teardown tests with `bin/fm-test-run.sh` and expect PASS.
- [ ] Commit `feat: activate and recover autonomous mandates`.

### Task 3: Query local authority and preserve captain holds

**Files:** Modify `bin/fm-autonomous-mandate.sh`, `bin/fm-captain-hold.sh:1001-1119`, `tests/fm-autonomous-mandate.test.sh`, and `tests/fm-captain-hold-lifecycle.test.sh`.

**Interfaces:** `query` returns `grant`, `deny`, or `unavailable` with mandate and member identity.

- [ ] Write tests proving validated local parent can query, remote route cannot, and answer retains source `autonomous-mandate:<id>`.
- [ ] Run mandate test and confirm failure because local-parent query and evidence are absent.
- [ ] Validate `.fm-secondmate-parent` through `fm_secondmate_parent_record_parse`, require `route=local` and matching primary home, and hold mandate lock through handoff.
- [ ] Record mandate id, member identity, action, result, timestamp, and evidence pointer for grants, denials, and unavailable reads.
- [ ] Answer every in-scope technical or product held decision through `fm-captain-hold.sh answer <task-id> --decision-file <file> --release`.
- [ ] Add cap, expiry, revocation, mismatch, opinion contradiction, scope expansion, and permanent-exclusion cases.
- [ ] Run mandate and captain-hold lifecycle tests with `bin/fm-test-run.sh` and expect PASS.
- [ ] Commit `feat: answer mandate-authorized holds`.

### Task 4: Integrate green merges and reviewed deployment wrapper

**Files:** Modify `bin/fm-pr-merge.sh:860-990`, `bin/fm-merge-local.sh:65-125`, `tests/fm-pr-merge.test.sh`, and `tests/fm-autonomous-mandate.test.sh`, then create `bin/fm-autonomous-deploy-check.sh`.

**Interfaces:** Add `fm-autonomous-deploy-check.sh <task-id> <spawn-gen> <environment> -- <command> [args...]`.

- [ ] Write tests proving green exact-member merge passes authority, red checks never reach forge, and excluded environment never runs wrapped command.
- [ ] Run PR merge test and confirm failure because mandate is not action input.
- [ ] Add mandate query inside existing merge critical sections without weakening PR identity, head, hold, yolo, away lock, or check verification.
- [ ] Reject `--allow-red` under mandate unconditionally.
- [ ] Run wrapped deployment only after exact allowed-environment query under mandate lock.
- [ ] Never infer targets or create deployment engine.
- [ ] Add staging and production, explicit exclusion, later-discovered environment, revocation race, credential, rollback, and remote denial cases.
- [ ] Run PR merge and mandate tests plus shellcheck wrapper, expecting PASS.
- [ ] Commit `feat: gate merges and deployments by mandate`.

### Task 5: Propagate advisory captain opinions

**Files:** Modify inheritance scripts named in file map and create `tests/fm-captain-opinions-inherit.test.sh`.

**Interfaces:** Add `data/captain-opinions.md` to `fm_config_inherit_items` with required primary-authoritative advisory header.

- [ ] Write local and remote supported-transport tests for mode `0444`, primary absence, malformed source, and divergent-copy quarantine.
- [ ] Run opinion test and confirm failure because opinions are absent from declared inheritance.
- [ ] Generalize existing shared-captain safeguards by declared file descriptor while retaining existing bytes and behavior.
- [ ] Require scope, stance, `weak|default|strong`, rationale, and last-confirmed date in authored entries.
- [ ] Keep opinions out of config reread instructions.
- [ ] Add proof opinions never alter mandate query result or grant authority.
- [ ] Run opinion inheritance test and relevant remote inheritance test with `bin/fm-test-run.sh`, expecting PASS.
- [ ] Commit `feat: propagate advisory captain opinions`.

### Task 6: Add dispatch procedure and owner documentation

**Files:** Create `.agents/skills/autonomous-dispatch/SKILL.md` and modify documentation files named in file map.

- [ ] Add one-line AGENTS trigger before assemble, review, approve-and-start, recovery, revocation, and finish.
- [ ] Make skill require environment inventory, visible cap, exclusions, mandate confirmation, native spawn, recovery, and terminal archive.
- [ ] Document optional expiry, four-worker default, no copied authority, opinion precedence, local-first authority, remote opinion propagation, and permanent exclusions.
- [ ] Keep schema in mandate owner and procedure in skill rather than duplicate either contract.
- [ ] Classify each new tracked prose surface in `docs/documentation-audiences.json`.
- [ ] Run mandate, opinions, PR merge, captain-hold, documentation-audience, and lint checks.
- [ ] Expect all checks PASS, then commit `docs: document autonomous dispatch procedure`.

## Self-review results

- Tasks cover records, activation, recovery, local reads, decisions, holds, merges, deployments, opinions, propagation, compatibility, exclusions, and focused tests.
- Interfaces and fields are introduced before later tasks consume them.
- Every task has failure-first, focused pass, and isolated commit steps.
