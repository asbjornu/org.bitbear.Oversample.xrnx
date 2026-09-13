---
on:
  pull_request_review:
    types: [submitted]
  bots:
    - copilot-pull-request-reviewer[bot]
if: >-
  github.event_name == 'pull_request_review'
  && github.event.review.user.login == 'copilot-pull-request-reviewer[bot]'
  && github.event.review.state == 'COMMENTED'
  && github.event.pull_request.head.repo.id == github.event.pull_request.base.repo.id
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
---

# PR Fixer (Copilot)

<!--
Push auth: the push_to_pull_request_branch safe output pushes with the
GH_AW_PUSH_TOKEN repo secret (a PAT with contents: write, pull-requests:
write, and workflow scopes). gh-aw strict mode forbids granting contents:
write to the GITHUB_TOKEN, so a dedicated PAT is required; GitHub also
refuses PAT pushes that touch .github/workflows/* without the workflow scope.

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
- Effective token grants: gh-aw's compiled safe_outputs and conclusion jobs
  are granted contents: write on the job token in addition to GH_AW_PUSH_TOKEN.
  This broader grant is required by gh-aw's safe-output push; the default
  repository token is still not used for the push itself (the PAT is).
- Trigger: this workflow runs only when Copilot posts a `COMMENTED` review on
  a same-repo PR. It does not run on every push, so the native Copilot review
  is the single gate that drives the loop.
-->

A native GitHub Copilot review was posted on this pull request. Fix the issues
Copilot raised in THAT review (do not process other reviews).

1. Read this review's inline comments:
   `gh api --paginate repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}/reviews/${{ github.event.review.id }}/comments`
   Comments from `copilot-pull-request-reviewer[bot]` are the ones to address.
   Do not re-fix comments on threads already marked resolved. The REST comment
   endpoints expose no resolved status, so fetch the PR's review threads via
   GraphQL and skip resolved ones:
   `gh api graphql -f query='query($q:String!){search(query:$q,type:ISSUE,first:1){nodes{... on PullRequest{reviewThreads(first:100){nodes{isResolved,comments(first:1){nodes{author{login},body,pullRequestReview{databaseId}}}}}}}}}' -f q="repo:${{ github.repository }} is:pr number:${{ github.event.pull_request.number }}"`
2. If there are concrete, actionable issues, address each one (file:line + the
   fix). Stay within the `allowed-files` paths. Do not make unrelated changes.
   Keep edits minimal and aligned with the existing code style. Commit your
   fixes locally with `git add` and `git commit`.
3. If there are no actionable issues remaining, make NO changes and do NOT push.
4. Only when you have committed a substantive fix, push it to this pull request's
   branch by calling the `push_to_pull_request_branch` safe output.

Your push re-triggers the native Copilot review (the review gate is configured
in repository settings). The loop ends when Copilot approves or when no
actionable comments remain.
