---
on:
  pull_request_review:
    types: [submitted]
    max-stack: -1
  pull_request_review_comment:
    types: [created]
  bots:
    - Copilot
    - copilot-pull-request-reviewer[bot]
  roles: all
if: >-
  github.event.pull_request.head.repo.id == github.event.pull_request.base.repo.id
  && (
    (github.event_name == 'pull_request_review'
      && contains(fromJSON('["Copilot","copilot","copilot-pull-request-reviewer[bot]"]'), github.event.review.user.login)
      && contains(fromJSON('["commented","COMMENTED"]'), github.event.review.state))
    || (github.event_name == 'pull_request_review_comment'
      && contains(fromJSON('["Copilot","copilot","copilot-pull-request-reviewer[bot]"]'), github.event.comment.user.login))
  )
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
    max: 20
  resolve-pull-request-review-thread:
    max: 20
    github-token: ${{ secrets.GH_AW_PUSH_TOKEN }}
  add-comment:
    max: 1
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
- Same-repo guard: the `if` condition above restricts activation to pull
  requests whose head and base live in the same repository, so a Copilot
  review on a fork PR cannot activate the agent against untrusted fork code
  with repository secrets available.
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
- Trigger: this workflow runs when Copilot posts a `commented` review, or an
  inline review comment, on a same-repo PR. Copilot's agentic code review is
  posted with GITHUB_TOKEN, so a `pull_request_review` event alone is
  suppressed by GitHub's anti-recursion rule; `pull_request_review_comment`
  still fires. The event exposes the review author as `Copilot` (the REST API
  reports `copilot-pull-request-reviewer[bot]`), so the guard accepts either
  spelling and both review-state casings. `roles: all` skips gh-aw's
  membership check, which 404s on the `Copilot` bot login. It does not run on
  every push, so the native Copilot review is the single gate that drives the
  loop.
-->

A native GitHub Copilot review or inline review comment was posted on this pull
request. Fix the unresolved issues Copilot raised.

1. Read the pull request's review threads with the GitHub MCP tool
   `get_pull_request_review_comments` for PR
   `${{ github.event.pull_request.number }}`. It returns each review thread's
   GraphQL `id` (a `PRRT_...` value), its `is_resolved` flag, and its comments
   (body, path, line, author, html_url). Work only on unresolved, non-outdated
   threads whose comments are authored by `Copilot` or
   `copilot-pull-request-reviewer`. Do not re-fix threads already resolved.
   Also use `get_pull_request_reviews` to read the most recent Copilot review
   body; if it lists findings under "Suppressed comments" (which have no
   thread), treat the concrete ones as actionable too.

2. If there are concrete, actionable issues, address each one (file:line + the
   fix). Stay within the `allowed-files` paths. Do not make unrelated changes.
   Keep edits minimal and aligned with the existing code style. Commit your
   fixes locally with `git add` and `git commit`.

3. If there are no actionable issues remaining, make NO changes and do NOT push.

4. After committing a substantive fix, explain it on the review:
   - For every thread you fixed, reply to its first Copilot comment by calling
     the `reply_to_pull_request_review_comment` safe-output tool with
     `comment_id` set to that comment's numeric database id and `body` set to a
     concise explanation of how you addressed that specific complaint
     (reference file:line). Derive the numeric id from the comment's `html_url`:
     it is the number after `discussion_r` (e.g.
     `.../pull/8#discussion_r4010111827` -> `4010111827`). One call per fixed
     thread. Keep each reply minimal.
   - Then call the `add_comment` safe-output tool once with a short summary of
     how the review's complaints were addressed overall.

5. Resolve the Copilot threads you addressed:
   - For every thread you fixed, call the
     `resolve_pull_request_review_thread` safe-output tool with `thread_id` set
     to that thread's `PRRT_...` `id` from step 1.
   - Only resolve threads you actually changed. Never resolve an unresolved
     thread that you did not fix.

6. Push the committed fix to this pull request's branch by calling the
   `push_to_pull_request_branch` safe output.

If the repository's automatic Copilot code review is enabled, your push
triggers a fresh review; otherwise a maintainer re-requests it. The loop ends
when Copilot approves or when no actionable comments remain.
