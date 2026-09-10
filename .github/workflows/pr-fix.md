---
on:
  pull_request_review:
    types: [submitted]
# NOTE: gh-aw triggers on any submitted review. To avoid the fixer firing on
# Copilot's APPROVE review (which would break the loop), add a job guard after
# `gh aw compile` so the fixer only runs when the review requests changes, e.g.
#   if: github.event.review.state == 'changes_requested'
# (confirm exact syntax with `gh aw compile` / gh-aw docs; adjust as needed.)
permissions:
  contents: write
  pull-requests: read
engine:
  id: opencode
  version: "1.2.14"
imports:
  - shared/opencode.md
model: anthropic/claude-sonnet-4
engine-env:
  ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
network:
  allowed:
    - defaults
    - api.anthropic.com
---

# PR Fixer (OpenCode)

A Copilot review requested changes on this pull request. Fix it.

1. Read the latest Copilot review on this PR and its inline comments:
   - `gh api repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}/reviews`
   - `gh api repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}/comments`
2. Address every concrete issue it raised (file:line + the fix). Do not make
   unrelated changes. Keep edits minimal and aligned with existing code style.
3. Commit the fixes using fixup semantics on the commit(s) they correct:
   `git commit --fixup=<sha>`, then `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash HEAD~N`.
4. Push the result back to the pull request's head branch:
   `git push --force-with-lease`.

Your push fires the `synchronize` event, which re-triggers the Copilot review
workflow. The loop ends when Copilot submits an `APPROVE` review.
