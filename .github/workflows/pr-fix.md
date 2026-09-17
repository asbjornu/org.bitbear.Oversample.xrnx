---
on:
  workflow_dispatch:
concurrency:
  job-discriminator: ${{ github.run_id }}
permissions:
  contents: read
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
    signed-commits: false
    github-token: ${{ secrets.GH_AW_PUSH_TOKEN }}
    allowed-files:
      - "Oversample/**"
      - "renoise/**"
      - "test/**"
      - "**.lua"
      - "**.txt"
      - "**.cfg"
      - "**.json"
      - "*.md"
      - "*.lua"
      - "LICENSE"
  reply-to-pull-request-review-comment:
    max: 100
  resolve-pull-request-review-thread:
    max: 100
    github-token: ${{ secrets.GH_AW_PUSH_TOKEN }}
  add-comment:
    max: 1
jobs:
  guard:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read
    outputs:
      ok: ${{ steps.check.outputs.ok }}
    steps:
      - id: check
        env:
          GH_TOKEN: ${{ secrets.GH_AW_PUSH_TOKEN }}
          AW_CONTEXT: ${{ github.event.inputs.aw_context }}
          AUTHOR: ${{ vars.PR_FIX_AUTHOR || 'asbjornu' }}
        run: |
          set -euo pipefail
          number=""
          if [ -n "$AW_CONTEXT" ]; then
            number=$(printf '%s' "$AW_CONTEXT" | jq -r 'if .item_type == "pull_request" then (.item_number // empty) else empty end' 2>/dev/null || true)
          fi
          if [ -z "$number" ]; then
            echo "ok=false" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          head_repo=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$number" --jq '.head.repo.full_name // empty')
          if [ "$head_repo" != "$GITHUB_REPOSITORY" ]; then
            echo "ok=false" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          pr_author=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$number" --jq '.user.login // empty')
          if [ "$pr_author" != "$AUTHOR" ]; then
            echo "ok=false" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          echo "ok=true" >> "$GITHUB_OUTPUT"
  agent:
    needs: [guard]
    if: needs.guard.outputs.ok == 'true'
---

# PR Fixer (Copilot)

<!--
Push auth: the push_to_pull_request_branch safe output pushes with the
GH_AW_PUSH_TOKEN repo secret (a PAT with contents: write, pull-requests:
write, and workflow scopes). gh-aw strict mode forbids granting contents:
write to the GITHUB_TOKEN, so a dedicated PAT is required; GitHub also
refuses PAT pushes that touch .github/workflows/* without the workflow scope.

Why the built-in safe outputs: replies and thread resolution use gh-aw's
`reply-to-pull-request-review-comment` and
`resolve-pull-request-review-thread` outputs instead of custom shell jobs.
The custom jobs issued an invalid `in_reply_to_id` request field and relied
on `gh api`, which the locked-down agent job cannot authenticate. The
built-ins call the correct REST/GraphQL endpoints with the job token.

Security notes:
- Same-repo guard: the pre-agent `steps:` guard rejects a dispatch whose
  `aw_context` does not name a same-repository pull request, so the agent never
  activates against untrusted fork code with repository secrets available.
- File allowlist: the `allowed-files` globs above limit the model to the
  project's source paths. The .github/workflows/ directory (including the
  compiled lock file) is intentionally excluded; those files are edited by
  the engineer and recompiled, not by the fixer. Targeting .github/workflows/
  paths in allowed-files would require a GitHub App token with workflows:
  write, which is not configured here.
- Agent read access: `contents: read` is granted so the agent job's
  actions/checkout can fetch the PR head it needs to inspect and edit.
- Effective token grants: gh-aw's compiled safe_outputs and conclusion jobs
  are granted contents: write on the job token in addition to GH_AW_PUSH_TOKEN.
  This broader grant is required by gh-aw's safe-output push; the default
  repository token is still not used for the push itself (the PAT is).
- Trigger: this workflow is dispatch-only. `pr-fix-orchestrator.yml` runs on a
  schedule, finds the newest Copilot review on each open same-repo PR's current
  head, and dispatches this workflow with `aw_context`. That covers both inline
  comments and body-only reviews: Copilot's agentic review is posted with
  GITHUB_TOKEN, so its `pull_request_review` event never creates a run, and a
  body-only review has no `pull_request_review_comment` event either. The
  orchestrator records the dispatched review id in a hidden PR comment so each
  review runs at most once.
- Companion workflows: `copilot-review-request.yml` requests a Copilot review on
  PR open/ready/synchronize, and `pr-fix-squash.yml` autosquashes the `fixup!`
  commits this agent creates and force-pushes the branch, which re-requests the
  next review. The agent replies on and resolves the Copilot threads it fixed.
-->

A Copilot review is ready to address on this pull request (dispatched by the
review orchestrator, inline or body-only). Fix the unresolved issues Copilot
raised.

1. The target pull request number is the `pull-request-number` shown in the
   GitHub context. Read that PR's review threads with the GitHub MCP tool
   `get_pull_request_review_comments`. It returns each review thread's GraphQL
   `id` (a `PRRT_...` value), its `is_resolved` flag, and its comments (body,
   path, line, author, html_url). Work only on unresolved, non-outdated threads
   whose comments are authored by `Copilot`, `copilot`,
   `copilot-pull-request-reviewer`, or `copilot-pull-request-reviewer[bot]`. Do
   not re-fix threads that are already resolved.
   Also use `get_pull_request_reviews` to read the most recent Copilot review
   body; if it lists findings under "Suppressed comments" (which have no
   thread), treat the concrete ones as actionable too. The orchestrator
   dispatches this workflow for exactly those body-only reviews.
   Before acting, confirm the newest Copilot review's `commit_id` equals the
   PR's current head (`get_pull_request` -> `head.sha`). If they differ, the
   review is stale because the branch moved after it was posted: call the
   `noop` safe-output tool and stop.

2. If there are concrete, actionable issues, address each one (file:line + the
   fix). Stay within the `allowed-files` paths. Do not make unrelated changes.
   Keep edits minimal and aligned with the existing code style. Stage the
   changes and create a `fixup!` commit per changed file targeting the commit
   that last touched it, so the branch history stays clean. Only target a commit
   that is a strict descendant of the branch merge-base (not the merge-base
   itself); if the file's last change predates the branch, create a normal
   commit so the autosquash cannot leave an unfoldable `fixup!` behind:
     base=""
     for ref in origin/HEAD origin/main origin/master; do
       if git rev-parse --verify -q "$ref" >/dev/null 2>&1; then
         base=$(git merge-base HEAD "$ref" 2>/dev/null || true)
         [ -n "$base" ] && break
       fi
     done
     git add -A
     for f in $(git diff --cached --name-only); do
       sha=$(git log -1 --format=%H -- "$f" || true)
       if [ -n "$base" ] && [ -n "$sha" ] && [ "$sha" != "$base" ] && git merge-base --is-ancestor "$base" "$sha"; then
         git commit --fixup="$sha" -- "$f"
       else
         git commit -m "fix: address Copilot review ($f)"
       fi
     done
   A follow-up workflow autosquashes these fixups and force-pushes. Do not run
   `git push` or force-push yourself; transport the commits with the safe
   output in step 6.

3. If there are no actionable issues remaining, make NO changes and do NOT push.

4. Explain the outcome on the review:
   - For every thread you fixed, reply to its first Copilot comment by calling
     the `reply_to_pull_request_review_comment` safe-output tool with
     `comment_id` set to that comment's numeric database id and `body` set to a
     concise explanation of how you addressed that specific complaint
     (reference file:line). Derive the numeric id from the comment's `html_url`:
     it is the number after `discussion_r` (e.g.
     `.../pull/8#discussion_r4010111827` -> `4010111827`). One call per fixed
     thread. Keep each reply minimal.
   - For every unresolved Copilot thread you did NOT fix, reply once with a
     one-line rationale (not actionable / already addressed / obsolete).
   - Then call the `add_comment` safe-output tool once with a short summary of
     how the review's complaints were addressed overall.

5. Resolve only the Copilot threads you actually fixed: for each such thread
   call the `resolve_pull_request_review_thread` safe-output tool with its
   `PRRT_...` `id` from step 1. Do not resolve a thread you did not change
   (leave it open for a human), and never resolve non-Copilot threads.

6. If and only if you committed a fix, push it to the target pull request's
   branch by calling the `push_to_pull_request_branch` safe output. If you made
   no changes, do NOT push; call the `noop` safe output with a short reason.

If the repository's automatic Copilot code review is enabled, your push
triggers a fresh review; otherwise a maintainer re-requests it. The loop ends
when Copilot approves or when no actionable comments remain.
