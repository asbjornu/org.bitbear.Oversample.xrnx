---
on:
  pull_request_review:
    types: [submitted]
if: github.event.review.user.login == 'copilot-pull-request-reviewer[bot]' && github.event.review.state == 'commented'
permissions:
  pull-requests: read
  copilot-requests: write
engine:
  id: opencode
  version: "1.2.14"
imports:
  - shared/opencode.md
model: copilot/gpt-5.1-codex
network:
  allowed:
    - defaults
    - copilot
safe-outputs:
  push-to-pull-request-branch:
    max: 1
---

# PR Fixer (OpenCode)

A native GitHub Copilot review (`copilot-pull-request-reviewer[bot]`) was posted
on this pull request. Fix the issues it raised.

1. List reviews and locate the one from `copilot-pull-request-reviewer[bot]`:
   - `gh api repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}/reviews`
2. Read its inline comments:
   - `gh api repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}/comments`
3. If the review contains concrete, actionable issues, address each one
   (file:line + the fix). Do not make unrelated changes. Keep edits minimal and
   aligned with existing code style. Commit your fixes locally with `git add`
   and `git commit`.
4. If the review has no actionable issues, make no changes and do not push.
5. When you have committed fixes, push them to this pull request's branch by
   calling the `push_to_pull_request_branch` safe output.

Your push re-triggers the native Copilot review on the updated PR (the review
gate is configured in repository settings). The loop ends when Copilot approves
(no further `commented` review is posted).
