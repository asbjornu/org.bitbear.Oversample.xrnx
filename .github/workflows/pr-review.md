---
on:
  pull_request:
    types: [opened, synchronize]
permissions:
  contents: read
  pull-requests: read
  copilot-requests: write        # org billing; or set COPILOT_GITHUB_TOKEN secret instead
safe-outputs:
  add-comment:
    max: 1
  create-pull-request-review-comment:
    max: 20
  submit-pull-request-review:
    allowed-events: [COMMENT, APPROVE, REQUEST_CHANGES]
---

# Pull Request Review (Copilot)

You are reviewing a pull request diff for correctness, security,
maintainability, and test coverage.

- Post inline review comments (`create-pull-request-review-comment`) only for
  concrete, actionable issues, with file:line and the specific fix.
- Add exactly one summary comment (`add-comment`) grouping findings by
  severity and noting anything that needs human follow-up.
- Do NOT restate unchanged code or give style-only feedback.
- If the diff is clean, submit an `APPROVE` review
  (`submit-pull-request-review`). Otherwise submit `REQUEST_CHANGES`.

This review is the gate for an automated fix loop: a `REQUEST_CHANGES`
review triggers the fixer workflow, and each fixer push re-triggers this
review via the `synchronize` event. The loop ends when you submit `APPROVE`.
