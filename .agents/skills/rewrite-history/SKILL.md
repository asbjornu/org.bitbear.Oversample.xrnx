---
name: rewrite-history
description: Squash a branch's Git history into minimal logical commits
---
Reduce a branch to the fewest commits that still capture its logical features.

- **Only the branch's own commits.** Rewrite only commits made after `main`'s HEAD (unreachable from `main`); never touch `main` or anything it already contains.
- **Group by logical feature.** One commit per feature the final diff delivers; drop WIP, refactor and re-shuffle commits that leave the end state unchanged.
- **Drop debug-logging commits.** Squash any commit that adds or removes diagnostics/logging so the logging is gone from the final tree.
- **Fixups fold into the original.** A commit fixing code added earlier in the branch becomes a fixup of that commit (`git commit --fixup=<sha>`); no standalone "fix" commits remain.
- **Messages describe the final diff only.** Never mention squashed-away code, intermediate steps or removed paths; the message must be accurate for what the commit actually contains.

Workflow:
- Rebase the branch onto `main` first (`git rebase main`), before any rewrite, so `main` is the base.
- Base: `base=$(git merge-base main HEAD)` (== `main` after the rebase).
- Plan: `git log --oneline $base..HEAD` and `git diff $base...HEAD --stat`; map each commit to a feature or to the drop/fixup buckets.
- Rewrite: `git rebase -i --autosquash $base` (reorder, `fixup`/`squash`, `reword`, `drop`).
- Verify every commit: run the suites (`luajit test/oversample_core_test.lua` and `luajit test/oversample_ui_test.lua`; see the `oversample-tests` skill) at each rewritten commit; they must pass at each one, not just the tip.
- Verify the final tree: `git diff <pre-rewrite-backup> HEAD` must be empty, so the branch's resulting diff equals its pre-rewrite state.
- Commit rules: `git commit -S`, terse header ≤50 chars (repeat in body if truncated), body wrapped at 72.
- Never rewrite `main` or other shared branches; publish with `git push --force-with-lease`.
