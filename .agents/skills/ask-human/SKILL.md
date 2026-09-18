---
name: ask-human
description: >-
  Agent-only shape guide for putting a decision to the captain.
  Load whenever an agent is about to raise a decision blocker on the captain's end: a merge not already authorized, a destructive or irreversible action, a security-sensitive choice, a product or value call, an escalated gate finding, or any blocker whose resolution is the captain's and not the fleet's.
  Owns the shape of the question, not whether to ask it.
user-invocable: false
metadata:
  internal: true
---

# ask-human

This skill is the single owner of how a captain-facing decision question is shaped.
It does not decide whether to ask.
`ask-user-authority` is the sole owner of which findings firstmate decides versus escalates.
`captain-hold-lifecycle` is the sole owner of recording and closing the captain's answer.
Load both for their own procedures; this skill only shapes the question once one of them has already decided to raise it.

## Contract

Every captain-facing decision question carries all six elements below.
State them in this order.

1. **The decision itself**, in one sentence, before any evidence.
2. **The problem space**: what is actually true right now, measured rather than assumed, including what is NOT at risk.
   State what was verified and what remains unproven.
   Never present inference as fact.
3. **Each option**, stated separately rather than merged into prose: what it commits to, what it costs, what it forecloses, and what specifically happens if it is wrong.
   An option the captain should not take still gets its real case, not a strawman.
4. **A recommendation** with the reason it best serves the captain's already-stated intent.
5. **The consequence of not deciding**: what stays blocked, what degrades, and whether the question expires on its own.
6. **Reversibility**: whether the choice can be undone, and at what cost.

## Style

Follow `AGENTS.md` section 9's outcome language exactly: the captain's nouns, no internal vocabulary.
Never use task ids, wake types, harness or backend names, worktree or checkout terms, gate or pipeline state labels, delivery-mode names, or fail-closed/fail-open phrasing.
Never relay a worker report, tool output, or status line verbatim into the question.
Translate it into the outcome and consequence first.
Give exact identifiers the captain needs to act, such as a full PR URL, copied from the record, never assembled from memory.

## Surface choice

More machinery than the question needs is itself a cost.
A question small enough for one sentence gets one sentence in plain chat.
Use plain chat for a binary or simple call.
Use the `ask_user`-style structured surface only when there are genuinely mutually exclusive options that benefit from being laid side by side.
Use `lavish-axi` only when several options or a structured report genuinely benefit from a visual surface.

## Boundaries

- This is a how-to-ask skill, never a whether-to-ask authority.
  `ask-user-authority` decides which findings escalate; `captain-hold-lifecycle` records and closes the answer.
- Asking never substitutes for judgment the asker can defensibly make.
  If the evidence settles it, decide and report the decision instead.
- One question is one decision.
  Batch only decisions the captain should genuinely take together.
- Silence is never assent.
  An unanswered question stays open.

## Examples

**Correct**: a scout found the target production database has no automated backup.
Decision: whether to pause the migration to add a backup first, or proceed on schedule and accept the exposure.
Problem space: verified no backup job exists; unverified whether the vendor's underlying storage has independent snapshotting.
Not at risk: the staging database, which is backed up.
Option A, pause: costs one day, forecloses the announced release date, and if wrong the team loses a day for a backup that turns out to already exist upstream.
Option B, proceed: costs nothing now, forecloses recovery if the migration corrupts data before a backup exists, and if wrong the exposure is unrecoverable data loss.
Recommendation: pause, because the captain's stated priority is data safety over the release date.
Consequence of not deciding: the migration stays paused and the release date slips further each day it waits.
Reversibility: the pause is fully reversible; proceeding without a backup is not.

**Wrong** (should not have been asked): "Should I rename this internal helper function to match the file's existing naming convention?"
The convention is already established in the file, the change has no product or security consequence, and it is fully reversible.
The agent should have just made the change and reported it, not escalated a judgment call it could defensibly make itself.
