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
- Modify `AGENTS.md:280-405`, `bin/fm-brief.sh`, `bin/fm-spawn.sh`, and `bin/fm-teardown.sh` at existing intake, launch, and completion hooks.
- Modify `docs/configuration.md`, `docs/architecture.md`, `docs/scripts.md`, and `docs/documentation-audiences.json`.

## Dispatch integration boundary

No tracked `assemble-dispatch`, `run-dispatch`, or `end-dispatch` executable exists.

`AGENTS.md:284-318` is current assemble-dispatch runtime procedure because it resolves intake, task scope, delivery contract, and task brief.

`AGENTS.md:320-340` plus `bin/fm-spawn.sh` is current run-dispatch runtime procedure because it launches only after task-specific review and records native task metadata.

`AGENTS.md:385-400` plus `bin/fm-teardown.sh` is current end-dispatch runtime procedure because it validates landing, completes task lifecycle, and removes native records.

Implementation must add mandate calls at those existing hooks and regression coverage in `tests/fm-brief.test.sh`, `tests/fm-spawn-batch.test.sh`, and `tests/fm-teardown.test.sh`.

Do not create a standalone skill as a dispatch owner.

The implementation changes the existing AGENTS runtime procedure directly with concise one-owner cross-references to the mandate script.

### Task 1: Create mandate owner and schema validation

**Files:** Create `bin/fm-autonomous-mandate.sh` and `tests/fm-autonomous-mandate.test.sh`.

**Interfaces:** Add `propose`, `confirm`, `launch-receipt`, `activate`, `query`, `answer`, `revoke`, `archive`, `recover`, and `status` subcommands.

**Shell contract:**

```bash
bin/fm-autonomous-mandate.sh propose --proposal <absolute-json>
bin/fm-autonomous-mandate.sh query --home <absolute-home> --task <task-id> --spawn-gen <spawn-gen> --action <decision|merge|deploy> [--environment <name>]
```

`propose` prints `proposed: <id>` on success.

`query` prints one JSON object with `result` set to `grant`, `deny`, or `unavailable`.

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

**Shell contract:**

```bash
bin/fm-autonomous-mandate.sh confirm --id <mandate-id>
bin/fm-spawn.sh <task-id> <project> --mode <mode> --yolo <on|off> --mandate-id <mandate-id> --mandate-member <member-id>
bin/fm-autonomous-mandate.sh launch-receipt --id <mandate-id> --member <member-id> --spawn-gen <spawn-gen>
bin/fm-autonomous-mandate.sh recover --id <mandate-id>
```

`confirm` prints `activating: <id>`.

`launch-receipt` prints `receipt: <member-id> <spawn-gen>`.

`recover` prints `recover: no-op`, `recover: launch <member-id>`, or exits nonzero with `recovery stopped: revoked`.

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

**Representative implementation seam:**

```bash
answer=$(bin/fm-autonomous-mandate.sh query --home "$FM_HOME" --task "$id" --spawn-gen "$spawn_gen" --action decision) || exit $?
[[ $(jq -r .result <<<"$answer") == grant ]] || exit 2
bin/fm-captain-hold.sh answer "$id" --decision-file "$decision_file" --release
```

- [ ] Write tests proving validated local parent can query, remote route cannot, and answer retains source `autonomous-mandate:<id>`.
- [ ] Run mandate test and confirm failure because local-parent query and evidence are absent.
- [ ] Validate `.fm-secondmate-parent` through `fm_secondmate_parent_record_parse`, require `route=local` and matching primary home, and hold mandate lock through handoff.
- [ ] Record mandate id, member identity, action, result, timestamp, and evidence pointer for grants, denials, and unavailable reads.
- [ ] Answer every in-scope technical or product held decision through `fm-captain-hold.sh answer <task-id> --decision-file <file> --release`.
- [ ] Add cap, expiry, revocation, mismatch, opinion contradiction, scope expansion, and permanent-exclusion cases.
- [ ] Run mandate and captain-hold lifecycle tests with `bin/fm-test-run.sh` and expect PASS.
- [ ] Commit `feat: answer mandate-authorized holds`.

### Task 4: Integrate green merges and existing deployment entrypoints

**Files:** Modify `bin/fm-pr-merge.sh:860-990`, `bin/fm-merge-local.sh:65-125`, `tests/fm-pr-merge.test.sh`, and `tests/fm-autonomous-mandate.test.sh`.

**Interfaces:** Add `bin/fm-autonomous-mandate.sh authorize-deployment --home <home> --task <task-id> --spawn-gen <spawn-gen> --environment <environment>`.

`authorize-deployment` is an authority query only.

It never accepts a command, arguments, shell text, target inference, or deployment credentials.

Existing task-specific deployment entrypoints consume its JSON grant before their own execution contract.

**Representative existing-entrypoint seam:**

```bash
grant=$(bin/fm-autonomous-mandate.sh authorize-deployment --home "$FM_HOME" --task "$task_id" --spawn-gen "$spawn_gen" --environment "$environment") || exit $?
[[ $(jq -r .result <<<"$grant") == grant ]] || exit 2
# Existing task-specific deployment owner continues here.
```

- [ ] Write tests proving green exact-member merge passes authority, red checks never reach forge, and excluded environment produces no deployment grant.
- [ ] Run PR merge test and confirm failure because mandate is not action input.
- [ ] Add mandate query inside existing merge critical sections without weakening PR identity, head, hold, yolo, away lock, or check verification.
- [ ] Reject `--allow-red` under mandate unconditionally.
- [ ] Add `authorize-deployment` authority query only, with no executable command interface.
- [ ] Preserve existing task-specific deployment entrypoints as sole deployment owners.
- [ ] Add staging and production, explicit exclusion, later-discovered environment, revocation race, credential, rollback, and remote denial cases.
- [ ] Run `bin/fm-test-run.sh tests/fm-pr-merge.test.sh`, `bin/fm-test-run.sh tests/fm-autonomous-mandate.test.sh`, and `bin/fm-lint.sh`, expecting PASS.
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

### Task 6: Integrate dispatch procedure and owner documentation

**Files:** Modify `AGENTS.md:284-340,385-400`, `bin/fm-brief.sh`, `bin/fm-spawn.sh`, `bin/fm-teardown.sh`, and documentation files named in file map.

- [ ] Add mandate review fields to existing `fm-brief.sh` dispatch brief output, including exact member, environment inventory, exclusions, cap, expiry, and permanent exclusions.
- [ ] Add concise AGENTS hooks: intake assembles reviewed proposal, spawn confirms and records exact receipt, teardown requests terminal archive.
- [ ] Add public-interface regression assertions proving the generated brief carries review fields, spawn rejects absent or mismatched mandate member, and teardown only requests archive after terminal lifecycle proof.
- [ ] Document optional expiry, four-worker default, no copied authority, opinion precedence, local-first authority, remote opinion propagation, and permanent exclusions.
- [ ] Keep schema in mandate owner and dispatch procedure in existing AGENTS plus script headers rather than add a new procedure owner.
- [ ] Classify each new tracked prose surface in `docs/documentation-audiences.json`.
- [ ] Run `bin/fm-test-run.sh tests/fm-autonomous-mandate.test.sh`, `bin/fm-test-run.sh tests/fm-brief.test.sh`, `bin/fm-test-run.sh tests/fm-spawn-batch.test.sh`, `bin/fm-test-run.sh tests/fm-teardown.test.sh`, `bin/fm-test-run.sh tests/fm-pr-merge.test.sh`, `bin/fm-test-run.sh tests/fm-captain-hold-lifecycle.test.sh`, `bin/fm-doc-audience-check.sh`, and `bin/fm-lint.sh`.
- [ ] Expect all checks PASS, then commit `docs: document autonomous dispatch procedure`.

## Self-review results

- Tasks cover records, activation, recovery, local reads, decisions, holds, merges, deployments, opinions, propagation, compatibility, exclusions, and focused tests.
- Interfaces and fields are introduced before later tasks consume them.
- Every task has failure-first, focused pass, and isolated commit steps.
