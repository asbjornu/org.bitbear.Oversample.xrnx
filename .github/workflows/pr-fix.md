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
  jobs:
    resolve-threads:
      description: "Resolve (hide, mark 'Resolved') the Copilot review threads the agent addressed"
      needs: reply
      runs-on: ubuntu-latest
      output: "Resolved addressed Copilot review threads"
      permissions:
        pull-requests: write
      inputs:
        thread_ids:
          description: "Comma-separated list of review thread node IDs to resolve"
          required: true
          type: string
      steps:
        - name: Resolve addressed review threads
          env:
            GH_TOKEN: ${{ github.token }}
          run: |
            set -euo pipefail
            test -f "$GH_AW_AGENT_OUTPUT" || { echo "No agent output file"; exit 1; }
            ids=$(jq -r '.items[] | select(.type == "resolve_threads") | .thread_ids' \
              "$GH_AW_AGENT_OUTPUT" | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -v '^$')
            if [ -z "$ids" ]; then
              echo "No threads to resolve"
              exit 0
            fi
            echo "$ids" | while read -r tid; do
              echo "Resolving thread $tid"
              gh api graphql \
                -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' \
                -f id="$tid"
            done
    reply:
      description: "Reply to a Copilot inline review comment, or post a top-level reply explaining how a complaint was addressed"
      runs-on: ubuntu-latest
      output: "Posted reply"
      permissions:
        issues: write
        pull-requests: write
      inputs:
        comment_id:
          description: "Database ID of the inline review comment to reply to. Omit to post a top-level reply about the whole review."
          required: false
          type: string
        reply:
          description: "Explanation of how the complaint was addressed"
          required: true
          type: string
      steps:
        - name: Post reply
          env:
            GH_AW_AGENT_OUTPUT: ${{ runner.temp }}/gh-aw/safe-jobs/agent_output.json
            GH_TOKEN: ${{ github.token }}
            PR_NUMBER: ${{ github.event.pull_request.number }}
            REPO: ${{ github.repository }}
          run: |
            set -euo pipefail
            test -f "$GH_AW_AGENT_OUTPUT" || { echo "No agent output file"; exit 1; }
            jq -c '.items[] | select(.type == "reply")' "$GH_AW_AGENT_OUTPUT" | while read -r item; do
              cid=$(printf '%s' "$item" | jq -r '.comment_id // empty')
              body=$(printf '%s' "$item" | jq -r '.reply')
              if [ -n "$cid" ]; then
                echo "Replying to inline comment $cid"
                payload=$(jq -n --arg body "$body" --arg cid "$cid" '{body:$body, in_reply_to_id:($cid|tonumber)}')
                printf '%s' "$payload" | gh api -X POST "repos/$REPO/pulls/$PR_NUMBER/comments" --input -
              else
                echo "Posting top-level reply on PR #$PR_NUMBER"
                payload=$(jq -n --arg body "$body" '{body:$body}')
                printf '%s' "$payload" | gh api -X POST "repos/$REPO/issues/$PR_NUMBER/comments" --input -
              fi
            done
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
   Each comment carries an `id` (its database id). Comments from
   `copilot-pull-request-reviewer[bot]` are the ones to address. Do not re-fix
   comments on threads already marked resolved. The REST comment endpoints expose
   no resolved status, so also fetch the PR's review threads via GraphQL to learn
   each thread's node `id`, its resolved state, and the comment `databaseId`s it
   contains (you will need these to resolve threads later):
   `gh api graphql -f query='query($q:String!){search(query:$q,type:ISSUE,first:1){nodes{... on PullRequest{reviewThreads(first:100){nodes{id,isResolved,comments(first:50){nodes{databaseId,author{login},body,pullRequestReview{databaseId}}}}}}}}}' -f q="repo:${{ github.repository }} is:pr number:${{ github.event.pull_request.number }}"`
2. If there are concrete, actionable issues, address each one (file:line + the
   fix). Stay within the `allowed-files` paths. Do not make unrelated changes.
   Keep edits minimal and aligned with the existing code style. Commit your
   fixes locally with `git add` and `git commit`.
 3. If there are no actionable issues remaining, make NO changes and do NOT push.
 4. After committing a substantive fix, explain the fix on the review:
    - For every comment you fixed, call the `reply` safe-output tool with
      `comment_id` set to that comment's `id` from step 1 and `reply` set to a
      concise, accurate explanation of how you addressed that specific complaint
      (reference file:line and the change). Keep each reply minimal.
    - Also call the `reply` safe-output tool once WITHOUT `comment_id`, with
      `reply` set to a short summary of how the review's complaints were addressed
      overall. This posts a top-level reply to the review.
 5. Resolve (hide) the Copilot comments you addressed by marking their review
    threads "Resolved":
    - For every comment you fixed, find the thread whose `comments.nodes.databaseId`
      matches that comment's `id` from step 1.
    - Collect the matched thread node `id`s that are still `isResolved: false`
      (only threads you actually changed).
    - Call the `resolve_threads` safe-output tool with those thread node `id`s as a
      single comma-separated string. The tool resolves them. Do not resolve
      unrelated threads.
 6. Push the committed fix to this pull request's branch by calling the
    `push_to_pull_request_branch` safe output.

Your push re-triggers the native Copilot review (the review gate is configured
in repository settings). The loop ends when Copilot approves or when no
actionable comments remain.
