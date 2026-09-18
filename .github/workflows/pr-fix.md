---
on:
  workflow_dispatch:
concurrency:
  job-discriminator: ${{ github.run_id }}
permissions:
  contents: read
  pull-requests: read
  copilot-requests: write
# The agent runs the OpenCode CLI against OpenCode Zen, billed privately to
# the repository owner via the `OPENAI_API_KEY` repository secret. The secret
# name is NOT OpenAI's: gh-aw's universal-llm-consumer engine mode hard-maps
# the OpenAI-compatible provider route to `secrets.OPENAI_API_KEY` (falling
# back to `secrets.CODEX_API_KEY`) and `engine.provider.auth.secret` cannot
# rename it. The key is held by the AWF api-proxy sidecar and is excluded from
# the agent container.
engine:
  id: opencode
  version: "1.2.14"
  env:
    OPENAI_BASE_URL: "https://opencode.ai/zen/v1"
imports:
  - shared/opencode.md
model: openai/deepseek-v4.1-flash
models:
  # OpenCode Zen list price for deepseek-v4.1-flash, so the proxy can meter the
  # run instead of failing with unknown_model_ai_credits.
  default-ai-credits-pricing:
    input: 0.30
    output: 1.20
excluded-env:
  - COPILOT_GITHUB_TOKEN
  - GITHUB_TOKEN
  - OPENAI_API_KEY
network:
  allowed:
    - defaults
    - opencode.ai
    # Explicit FQDN (not just the `copilot` set) so it is carried into the
    # built-in threat-detection job's own AWF config, which only receives the
    # workflow's literal domains. Detection runs on the Copilot route and
    # cannot be repointed; the agent itself targets opencode.ai.
    - api.githubcopilot.com
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
          meta=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$number" \
            --jq '[.state, (.draft | tostring), .head.repo.full_name, .user.login] | @tsv' 2>/dev/null || true)
          pr_state=$(printf '%s' "$meta" | cut -f1)
          pr_draft=$(printf '%s' "$meta" | cut -f2)
          head_repo=$(printf '%s' "$meta" | cut -f3)
          pr_author=$(printf '%s' "$meta" | cut -f4)
          if [ "$pr_state" != "open" ] || [ "$pr_draft" = "true" ] \
             || [ "$head_repo" != "$GITHUB_REPOSITORY" ] || [ "$pr_author" != "$AUTHOR" ]; then
            echo "ok=false" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          echo "ok=true" >> "$GITHUB_OUTPUT"
  agent:
    needs: [guard]
    if: needs.guard.outputs.ok == 'true'
---

# PR Fixer (OpenCode)

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
- Engine: the fixer runs on the OpenCode CLI (`shared/opencode.md`). The engine
  provider is `openai`, so gh-aw routes through the AWF api-proxy's OpenAI
  target, which `engine.env.OPENAI_BASE_URL` points at OpenCode Zen
  (`https://opencode.ai/zen/v1`), serving `deepseek-v4.1-flash`. The Zen key is
  the `OPENAI_API_KEY` repository secret: a source credential held by the
  api-proxy sidecar and listed in `excluded-env`, so it is never present in the
  agent container. The shared definition disables OpenCode's built-in
  `opencode`, `openai`, and `copilot` providers, so the only selectable
  provider is the local proxy. The runtime harness (`harness-script`) resolves
  the endpoint and an advertised model id from the proxy's `/reflect` before
  spawning the CLI. `opencode.ai` is allowed for the proxy's upstream, and
  `api.githubcopilot.com` is also allowed because the built-in threat-detection
  pass below still runs on the Copilot route; the agent itself does not use it.
- Threat detection: gh-aw runs a built-in post-agent Copilot threat-detection
  pass on every workflow; its engine cannot be changed from frontmatter. It is
  small and bounded by `GH_AW_DEFAULT_DETECTION_MAX_AI_CREDITS`.
- MCP bearer: the config adapter writes the gateway's MCP `headers` (including
  its bearer token) into `opencode.jsonc` in the workspace, which is mounted
  into the agent container. Mode 0600 does not hide it from the agent, which
  runs as the same user; gh-aw has no out-of-workspace config mount for the
  OpenCode engine (the upstream Goose adapter has the same property). The token
  only unlocks the gateway, which enforces the same tool guard policies.
- Same-repo guard: the pre-agent `steps:` guard rejects a dispatch whose
  `aw_context` does not name a same-repository pull request, so the agent never
  activates against untrusted fork code with repository secrets available.
- File allowlist: the `allowed-files` globs above limit the model to the
  project's source paths. The .github/workflows/ directory (including the
  compiled lock file) is intentionally excluded; those files are edited by
  the engineer and recompiled, not by the fixer. Targeting .github/workflows/
  paths in allowed-files would require a GitHub App token with workflows:
  write, which is not configured here.
- Repository instructions: `*.md` is deliberately NOT in `allowed-files`, so
  the fixer cannot push changes to `AGENTS.md` (or any other instructions
  file) even though the OpenCode engine's agent-side safe-outputs config does
  not list `AGENTS.md` in `protected_files`. The compiled Copilot engine added
  it there; the OpenCode engine's `behaviors.manifest` files are only enforced
  by the handler config. Keep the allowlist as the primary agent-side guard.
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
raised, using the OpenCode CLI.

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
     git config user.name "github-actions[bot]"
     git config user.email "github-actions[bot]@users.noreply.github.com"
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
       parents=$(git show -s --format=%P "$sha" 2>/dev/null | wc -w | tr -d ' ')
       if [ -n "$base" ] && [ -n "$sha" ] && [ "$sha" != "$base" ] \
          && git merge-base --is-ancestor "$base" "$sha" \
          && [ "$parents" -le 1 ]; then
         git commit --fixup="$sha" -- "$f"
         git commit --amend -m "fixup! $(git log -1 --format=%s "$sha")" -m "aw-fixup-target=$sha"
       else
         git commit -m "fix: address Copilot review ($f)" -- "$f"
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
