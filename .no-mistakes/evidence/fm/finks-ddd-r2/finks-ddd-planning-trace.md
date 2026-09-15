# Live finks-ddd planning trace

Handoff planned: `/Users/nich/.local/share/finks/handoffs/commercialize-finks-api/search-api-commercial-readiness-v2.handoff.md`
Read-only pass following `.agents/skills/finks-ddd/SKILL.md`'s "Read-only handoff planning" procedure. No writes to Linear, no charter edits, no task spawn, no `tasks-axi` mutation.

## 1. Real FIN ticket + Domain: line (live Linear MCP `get_issue FIN-3452`)

```
FIN-3452 "Chore: custom domain on the commercial API gateway"
description: "Domain: [External API Surface](https://linear.app/joefinks/project/external-api-surface-b94799e1ad92)\nRepo: `finks-api` ..."
project: "External API Surface"
relations.blockedBy: [FIN-3601]
relations.relatedTo: [FIN-3564]
```

## 2. Live `linear-tree --project "External API Surface"` (project -> parent initiative)

```json
{ "name": "External API Surface", "initiatives": ["Commercialize Finks API"], ... }
```

Matches handoff frontmatter `initiative: "search-api-commercial-readiness-v2"`, `domain: "commercialize-finks-api"`.

## 3. Live `finks-linear-graph graph FIN-3452 --depth 2 --format json` (dependency/blocker map)

Edges of record:
- `FIN-3601 -> FIN-3452 : blocks` (FIN-3601 is the sole blocker; matches Linear `blockedBy`)
- `FIN-3452 -> FIN-3564 : related` (cross-domain neighbor, NOT an ownership signal)

## 4. Accountable secondmate resolution (`~/code/finks/cos/state/roster.md` line 59)

```
| domain | commercialize-finks-api | initiative | /Users/nich/orca/workspaces/manager/mgr-commercialize-finks-api | run_4025aa74a0f7 | term_fb72f88c-62cf-4880-be05-58b46992cf6d | live | 2026-08-19 | natural domain boundary |
```

Matches handoff frontmatter `claimed_by: "mgr-commercialize-finks-api"`. Route: FIN-3452 -> External API Surface -> Commercialize Finks API -> mgr-commercialize-finks-api (live).

## 5. Adversarial: missing/unprovable evidence, not guessed

**(a) Plan commit hash.** Handoff frontmatter gives `outcome_plan_hash: "sha256:ffcdfc18..."` — a content digest, which the skill explicitly forbids substituting for a Git commit hash. Independently verified in the real `planner` repo:

```
$ git -C ~/code/finks/planner log -1 --format="%H %ci" -- plans/commercialize-finks-api/search-api-commercial-readiness-v2/plan.md
59b498a214c0b3503f08ae9812cb4d54131cf9ea 2026-09-11 13:21:43 +0800
```

Correct `Plan:` line uses this proven Git commit hash, not the handoff's sha256 content digest.

**(b) Cross-domain graph neighbor with no live route.** FIN-3564 (related, not a dependency) belongs to project "Foundational SEO":

```
$ linear-tree --project "Foundational SEO" --json
{ "initiatives": ["Organic Growth (SEO & Distribution)"], ... }
```

`~/code/finks/cos/state/roster.md` has no row for "Organic Growth (SEO & Distribution)" / SEO — no live secondmate mapped. Per the skill, this is unresolved ownership to report, not a route to guess; and per the ownership rule, graph-adjacency to FIN-3452 must not pull FIN-3564's foreign domain into this route regardless.

## 6. Static wiring check

`.agents/skills/finks-ddd/SKILL.md` never references `nld`, `finks-pr`, `finks-plan`, `finks-workstreams`, `finks-actor-mail`, or `finks-manager-store` (grep, no matches). States `tasks-axi remains sole authority for task rows, dependencies, holds, and execution state.`
