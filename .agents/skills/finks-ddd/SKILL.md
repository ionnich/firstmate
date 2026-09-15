---
name: finks-ddd
description: Agent-only Finks DDD procedure for Linear-linked routing, ticket-linked backlog filing, and ticket-linked terminal outcomes.
user-invocable: false
metadata:
  internal: true
---

# Finks DDD

Load this skill before routing or sequencing a Linear-linked request.
Load this skill before filing a ticket-linked backlog item.
Load this skill before a terminal outcome on a ticket-linked task.

This procedure resolves ownership, grooming evidence, backlog records, and terminal Linear evidence.
It never authorizes task launch, implementation, deployment, or a new execution system.

## Live ownership evidence

Read current `linear-tree --help` and `finks-linear-graph --help` before using either installed tool.
Use their current output directly, without a wrapper, daemon, persistent graph, or alternate queue.

1. Read ticket source and extract its canonical `Domain:` project link.
2. Resolve that project and its direct parent initiative with live Linear tree evidence.
3. Read graph evidence for exact ticket identity, URL, state, and declared dependency or blocker edges.
4. Match parent initiative to `data/secondmates.md` and match canonical Domain project to `data/projects.md`.
5. Route only when both mappings name same accountable secondmate and home.

`Domain:` project decides ownership.
That project's direct parent initiative decides accountable secondmate.
Labels, assignee, repository, project-clone availability, milestone, tracker, issue title, and graph-adjacent ticket project never decide ownership.
They may support planning evidence after ownership is already resolved.

## Readiness and filing

Readiness is grooming evidence only.
Readiness never blocks task spawn, changes delivery authority, or replaces native Firstmate lifecycle ownership.

A ticket is readiness-complete only when its live label set contains exactly one `class:*` label and its body contains all four house-complete lines.

```text
Domain: <canonical project link>
Acceptance: <testable outcome>
Honors: <constraints preserved>
Repo: <execution repository or explicit repository decision>
```

Record missing or duplicate `class:*` labels and each missing body line as readiness evidence.
Do not infer a missing line from labels, assignee, repository, tracker, title, or related tickets.

`tasks-axi` remains sole authority for task rows, dependencies, holds, and execution state.
Use its existing home-addressed path for every backlog mutation.
Do not create a parallel plan queue, dependency store, ownership database, or execution command.

Every ticket-linked backlog item records exact Linear ticket id and URL.
When canonical plan drove work, record canonical plan path and source commit hash on same item.
Use a full Git commit hash, not a content hash, branch name, or copied handoff hash.

Record only attested facts in this shape:

```text
Linear: FIN-<number> <exact Linear URL>
Domain: <exact project name> <exact project URL>
Initiative: <exact initiative name> <exact initiative URL>
Plan: <canonical path> @ <full Git commit hash>
```

Omit `Plan:` when no canonical plan drove work.
If plan path exists but its source commit cannot be proven, record it as missing evidence and do not substitute a SHA-256 content digest.

## Durable mappings and charters

Keep each `data/secondmates.md` parser suffix unchanged.
Record initiative-to-secondmate and canonical Domain-project coverage in that entry's free-text `scope:` value.
Keep `home:`, `projects:`, and `added` fields in their existing order and syntax.

Record each canonical Domain-project-to-home mapping in that project's `data/projects.md` description.
Preserve its existing delivery-mode marker.
Name Linear initiative, canonical Domain project, accountable secondmate id, and home together so either registry can be checked against other.

Amend every affected local secondmate charter with one domain-specific ownership rule:

> A Finks ticket routes by its `Domain:` project and that project's direct parent initiative.
> This charter owns only listed Domain projects under its mapped initiative.
> Labels, assignee, repository, project clones, milestones, and tracker views never establish ownership.

Leave generated lifecycle, backlog, delivery, recovery, and escalation sections unchanged.
Missing mapping, mismatched mappings, an absent `Domain:` link, or an absent parent initiative is unresolved ownership.
Return that evidence to primary firstmate rather than guessing or broadening a charter.

## Read-only handoff planning

Treat a handoff as planning input, never permission to launch work.
For each proposed item, preserve exact handoff path, ticket id, URLs, Domain project, parent initiative, accountable secondmate and home, dependency edges, blocker edges, and evidence source.
Keep dependency and blocker relations as tool-reported edges rather than prose-derived classifications.

For `/Users/nich/.local/share/finks/handoffs/commercialize-finks-api/search-api-commercial-readiness-v2.handoff.md`, prove planning evidence with live Linear tree and graph results for a real referenced FIN ticket before recording an accountable route.
Do not launch work from this planning pass.

If Linear access, `linear-tree`, graph evidence, ticket `Domain:` evidence, parent-initiative evidence, mapping agreement, or plan-source commit evidence is unavailable, stop planning.
Report source checked, exact available facts, missing evidence, and no accountable route or launch.
Never replace missing evidence with labels, repository inference, handoff `domain:` text, or a neighboring ticket.

## Primary-only terminal write-back

Only primary firstmate writes a terminal ticket result to Linear.
Secondmates and crewmates return native task evidence to primary and never perform this write-back.

Before a successful landed ticket-linked outcome, primary firstmate reads current issue and preserves its full description.
Primary firstmate then uses `finks-linear-graph edit` to set exact Linear state `Ready for QA` and append or update this Completion block.

```text
## Completion
Outcome: <landed outcome>
PR: <exact https:// URL>
Commit: <full Git commit hash>
Checks: <result>
```

Replace only prior Completion block content.
Preserve every other description byte and all existing ticket evidence.
If current ticket body or exact completion evidence cannot be read, stop write-back and report missing evidence.

For failed, cancelled, or unlanded work, do not invent a terminal Linear state or claim completion.
Record that outcome in native task evidence and leave Linear state unchanged.
