# Task for reviewer

Independent adversarial code review. Do not modify files or run tests. Return only source-grounded material findings with file/line and concrete path, focus current diff base 3dc74b63cc58348cf887f8651912ce770f8db9df..HEAD c0d9679a15e5f24c299d857a00a8172801112580, including full histories/callers needed. Intent: simplified one active dispatch record; approval launches existing lifecycle; persist member dispatch identity; consume active membership at routine decision, green merge, task-requested deployment; task exclusions/permanent safety stops remain; revoke removes dispatch-only authority; advisory captain-opinions on-demand documented. Deployment guard must validate exact task/spawn gen/reviewed env/explicit executable args under lock before exec, deny malformed/unavailable/expired/revoked/mismatch/excluded zero exec. Previously declined historical issues must not be repeated (PR merge lock deadlock, merge-local fallback, old mandate engine lifecycle). Review pipeline-added c0d967 as untrusted. Test quality: flag source-content-only test assertions. ## PR Review Context
- PR: local branch review
- PR HEAD SHA: c0d9679a15e5f24c299d857a00a8172801112580
- Review mode: LOCAL_FILES
- Working directory: /Users/nich/.no-mistakes/worktrees/3bc3ee2d971b/01M2ZCC86C8TWFNBBCKVGBH34M
- Changed files: AGENTS.md, bin/fm-autonomous-deploy.sh, bin/fm-autonomous-dispatch.sh, bin/fm-merge-authority-lib.sh, bin/fm-pr-merge.sh, docs/configuration.md, tests/fm-autonomous-dispatch.test.sh
Do not run tests.

## Acceptance Contract
Acceptance level: attested
Completion is not accepted from prose alone. End with a structured acceptance report.

Criteria:
- criterion-1: Return concrete findings with file paths and severity when applicable

Required evidence: review-findings, residual-risks

Finish with a fenced JSON block tagged `acceptance-report` in this shape:
Use empty arrays when no items apply; array fields contain strings unless object entries are shown.
`criteriaSatisfied[].status` must be exactly one of: satisfied, not-satisfied, not-applicable.
`commandsRun[].result` must be exactly one of: passed, failed, not-run.
`manualNotes` and `notes` are optional strings; an empty string means no note and does not satisfy `manual-notes` evidence.
```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "specific proof"
    }
  ],
  "changedFiles": [
    "src/file.ts"
  ],
  "testsAddedOrUpdated": [
    "test/file.test.ts"
  ],
  "commandsRun": [
    {
      "command": "command",
      "result": "passed",
      "summary": "short result"
    }
  ],
  "validationOutput": [
    "validation output or concise summary"
  ],
  "residualRisks": [
    "none"
  ],
  "noStagedFiles": true,
  "diffSummary": "short description of the diff",
  "reviewFindings": [
    "blocker: file.ts:12 - issue found, or no blockers"
  ],
  "manualNotes": "anything else the parent should know"
}
```