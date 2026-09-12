---
on:
  pull_request_review:
    types: [submitted]
  pull_request:
    types: [synchronize, opened]
  bots:
    - copilot-pull-request-reviewer[bot]
if: >-
  (github.event_name == 'pull_request_review' && github.event.review.user.login == 'copilot-pull-request-reviewer[bot]' && github.event.review.state == 'COMMENTED')
  || github.event_name == 'pull_request'
permissions:
  pull-requests: read
  copilot-requests: write
engine: copilot
network:
  allowed:
    - defaults
    - copilot
safe-outputs:
  push-to-pull-request-branch:
    max: 1
    github-token: ${{ secrets.GH_AW_PUSH_TOKEN }}
---

# PR Fixer (Copilot)

<!--
Push auth: the push_to_pull_request_branch safe output pushes with the
GH_AW_PUSH_TOKEN repo secret (a PAT with contents: write, pull-requests:
write, and workflow scopes). gh-aw strict mode forbids granting contents:
write to the GITHUB_TOKEN, so a dedicated PAT is required; GitHub also
refuses PAT pushes that touch .github/workflows/* without the workflow scope.
-->

A native GitHub Copilot review was posted on this pull request (or a new push
landed). Fix the issues Copilot raised.

1. Read the inline review comments you need to address:
   - If this run was triggered by a specific review (`github.event.review.id` is set), read only that review's comments:
     `gh api repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}/reviews/${{ github.event.review.id }}/comments`
   - Otherwise (push-triggered run), read all PR review comments:
     `gh api repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}/comments`
   Focus on comments from `copilot-pull-request-reviewer[bot]`. Do not re-fix comments already marked resolved.
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
