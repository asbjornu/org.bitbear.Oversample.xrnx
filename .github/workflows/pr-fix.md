---
on:
  pull_request_review:
    types: [submitted]
if: github.event.review.state == 'changes_requested'
permissions:
  pull-requests: read
  copilot-requests: write
engine: copilot
model: copilot/gpt-5.1-codex
safe-outputs:
  push-to-pull-request-branch:
    max: 1
---

# PR Fixer (Copilot)

A Copilot review requested changes on this pull request. Fix it.

1. The pull request number is `${{ github.event.pull_request.number }}`. Read the
   latest Copilot review and its inline comments:
   - `gh api repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}/reviews`
   - `gh api repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}/comments`
2. Address every concrete issue it raised (file:line + the fix). Do not make
   unrelated changes. Keep edits minimal and aligned with existing code style.
3. Commit your fixes locally with `git add` and `git commit`.
4. Push the commits to this pull request's branch by calling the
   `push_to_pull_request_branch` safe output.

Your push re-triggers the Copilot reviewer via the `synchronize` event.
The loop ends when Copilot submits an `APPROVE` review.
