---
on:
  pull_request_review:
    types: [submitted]
  pull_request:
    types: [synchronize, opened]
if: >-
  (github.event_name == 'pull_request_review' && github.event.review.user.login == 'copilot-pull-request-reviewer[bot]' && github.event.review.state == 'COMMENTED')
  || github.event_name == 'pull_request'
engine: copilot
network:
  allowed:
    - defaults
    - copilot
safe-outputs:
  push-to-pull-request-branch:
    max: 1
---

# PR Fixer (Copilot)

A native GitHub Copilot review was posted on this pull request (or a new push
landed). Fix the issues Copilot raised.

1. Read all inline review comments on the PR:
   - `gh api repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}/comments`
   These are the comments from `copilot-pull-request-reviewer[bot]`.
2. If there are concrete, actionable issues, address each one (file:line + the
   fix). Do not make unrelated changes. Keep edits minimal and aligned with the
   existing code style. Commit your fixes locally with `git add` and `git commit`.
3. If there are no actionable issues remaining (e.g. they were already resolved
   by a previous push), make NO changes and do NOT push.
4. Only when you have committed a substantive fix, push it to this pull request's
   branch by calling the `push_to_pull_request_branch` safe output.

Your push re-triggers the native Copilot review (the review gate is configured
in repository settings). The loop ends when Copilot approves or when no
actionable comments remain.
