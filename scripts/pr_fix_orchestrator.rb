#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Dispatches the gh-aw PR Fixer for new Copilot reviews, one PR per cycle, and
# surfaces terminal fixer failures as PR comments. See pr-fix-orchestrator.yml.

require_relative "lib/ci"

module Ci
  module PrFixOrchestrator
    LOCK_PATH = ".github/workflows/pr-fix.lock.yml"
    FAILURE_CONCLUSIONS = %w[failure cancelled timed_out startup_failure stale missing].freeze

    class Runner
      def initialize(client:, repo:, server_url:, author:, max_rounds:,
                     dispatch_token: nil, out: $stdout)
        @gh = client
        @repo = repo
        @server_url = server_url
        @author = author
        @max_rounds = max_rounds.to_i
        @dispatch_token = dispatch_token
        @out = out
      end

      def run
        @token_user = @gh.login
        wf = @gh.get("repos/#{@repo}/actions/workflows")["workflows"]
                   .find { |w| w["path"] == LOCK_PATH }
        return log("pr-fix workflow not on the default branch yet; nothing to do") unless wf

        return log("A PR Fixer run is already pending; skipping this cycle") if fixer_pending?(wf["id"])

        each_candidate_pr do |pr, head|
          process(pr, head)
        end
      end

      private

      def fixer_pending?(wf_id)
        %w[in_progress queued].any? do |status|
          @gh.get("repos/#{@repo}/actions/workflows/#{wf_id}/runs?status=#{status}&per_page=1")["total_count"].to_i != 0
        end
      end

      # Yield each open, non-draft, same-repo PR authored by the configured
      # author, one at a time. Stops the whole cycle after a dispatch.
      def each_candidate_pr
        prs = @gh.get_all("repos/#{@repo}/pulls?state=open&per_page=100")
        prs.select! do |p|
          p["draft"] == false && p.dig("head", "repo", "full_name") == p.dig("base", "repo", "full_name")
        end
        prs.each do |pull|
          next unless pull.dig("user", "login") == @author

          pr = pull["number"].to_s
          head = @gh.get("repos/#{@repo}/pulls/#{pr}")["head"]["sha"]
          return if process(pr, head) == :dispatched
        end
      end

      def process(pr, head)
        state = Markers.latest_state(@gh, @repo, pr, @token_user)
        prev_review = state&.review
        prev_round = state&.round
        prev_run = state&.run
        prev_comment = state&.comment_id

        prev_concl = report_previous_failure(pr, prev_run)
        return :skip if prev_concl == :retry

        review = copilot_review_on(pr, head)
        unless review
          log("PR ##{pr}: no Copilot review on the current head")
          return :skip
        end

        if prev_review == review
          if prev_run.nil?
            log("PR ##{pr}: review #{review} has no observed run; re-dispatching")
          elsif FAILURE_CONCLUSIONS.include?(prev_concl)
            log("PR ##{pr}: previous run #{prev_run} concluded #{prev_concl}; re-dispatching review #{review}")
          else
            log("PR ##{pr}: review #{review} already dispatched (#{prev_concl})")
            return :skip
          end
        end

        round = prev_round.to_i + 1
        if round > @max_rounds
          log("PR ##{pr}: reached #{@max_rounds} rounds; leaving the rest to a human")
          return :skip
        end

        head_now = @gh.get("repos/#{@repo}/pulls/#{pr}")["head"]["sha"]
        if head_now != head
          log("PR ##{pr}: head moved from #{head} to #{head_now}; not dispatching (will re-evaluate)")
          return :skip
        end

        write_pending(pr, review, round, head, prev_comment)
        dispatch(pr, review, round, head)
      end

      # Reports a terminal failure of the previously dispatched run. Returns the
      # conclusion, or :retry when a transient read error means this PR should be
      # skipped until the next cycle.
      def report_previous_failure(pr, prev_run)
        return nil if prev_run.nil?

        conclusion = read_conclusion(prev_run)
        return :retry if conclusion.nil?

        if FAILURE_CONCLUSIONS.include?(conclusion)
          unless report_failure(pr, prev_run, conclusion)
            log("PR ##{pr}: could not report run #{prev_run} failure; will retry next cycle")
            return :retry
          end
        end
        conclusion
      end

      def read_conclusion(run_id)
        @gh.api("repos/#{@repo}/actions/runs/#{run_id}", "--jq", '.conclusion // "none"').strip
      rescue Ci::Gh::Error => e
        return "missing" if e.message.include?("HTTP 404")

        nil
      end

      def report_failure(pr, run_id, conclusion)
        marker = Markers.failure_marker(run_id)
        begin
          already = @gh.get_all("repos/#{@repo}/issues/#{pr}/comments?per_page=100")
                       .any? { |c| c["body"].to_s.include?(marker) && c.dig("user", "login") == @token_user }
        rescue Ci::Gh::Error
          return false
        end
        return true if already

        failed_jobs = failed_jobs_for(run_id, conclusion)
        return false if failed_jobs == :unreadable

        run_url = "#{@server_url}/#{@repo}/actions/runs/#{run_id}"
        body = +"🤖 PR Fixer run failed (`#{conclusion}`) — [view logs](#{run_url})."
        body << "\n\nFailed jobs:\n#{failed_jobs}" unless failed_jobs.empty?
        body << "\n\nThe orchestrator re-dispatches this review for another round " \
                "while the configured round limit allows; once no rounds remain, " \
                "a human needs to investigate.\n\n#{marker}"
        @gh.post("repos/#{@repo}/issues/#{pr}/comments", { "body" => body })
        true
      rescue Ci::Gh::Error
        false
      end

      # Newline-joined bullets for jobs that actually failed. :unreadable when
      # the jobs lookup fails, so the caller retries rather than reporting a
      # truncated list.
      def failed_jobs_for(run_id, conclusion)
        return "" if conclusion == "missing"

        jobs = @gh.get("repos/#{@repo}/actions/runs/#{run_id}/jobs?per_page=100")["jobs"]
        jobs.select { |j| %w[failure timed_out].include?(j["conclusion"]) }
            .map { |j| "- **#{j['name']}** (#{j['conclusion']})" }
            .join("\n")
      rescue Ci::Gh::Error
        :unreadable
      end

      # Latest Copilot review for the head that is in the COMMENTED state, or nil.
      def copilot_review_on(pr, head)
        cand = @gh.get_all("repos/#{@repo}/pulls/#{pr}/reviews?per_page=100")
                  .select { |r| Ci.copilot_review?(r) && r["commit_id"] == head }
                  .max_by { |r| r["submitted_at"] }
        return nil unless cand && cand["state"].to_s.upcase == "COMMENTED"

        cand["id"].to_s
      end

      def write_pending(pr, review, round, head, prev_comment)
        marker = Markers.state_marker(review: review, pr: pr, round: round, run: "none", head: head)
        body = "🤖 PR Fixer is working on Copilot review [`#{review}`](#{review_url(pr, review)}) " \
               "(round #{round}, fixes by [@#{@token_user}](#{@server_url}/#{@token_user})) — " \
               "dispatching a run for head `#{head[0, 7]}`… #{marker}"
        if prev_comment
          @gh.patch("repos/#{@repo}/issues/comments/#{prev_comment}", { "body" => body })
        else
          resp = @gh.post("repos/#{@repo}/issues/#{pr}/comments", { "body" => body })
          @pending_comment_id = JSON.parse(resp)["id"].to_s
        end
        @pending_comment_id = prev_comment if prev_comment
      end

      def dispatch(pr, review, round, head)
        log("PR ##{pr}: dispatching fixer for review #{review} (round #{round})")
        aw_context = JSON.generate(item_type: "pull_request", item_number: pr.to_i)
        dispatch_out = @gh.run("aw", "run", "pr-fix", "--repo", @repo,
                               "--raw-field", "aw_context=#{aw_context}",
                               token: @dispatch_token)
        @out.print(dispatch_out)
        run_id = dispatch_out[/\/actions\/runs\/(\d+)/, 1]
        if run_id.nil?
          # A successful `gh aw run` means a fixer is already running even
          # though its run id could not be read. Stop the cycle so we never
          # dispatch a second PR concurrently; the pending marker (run=none)
          # makes the next cycle re-evaluate this PR.
          log("PR ##{pr}: dispatched run not identified; marker stays pending (will retry)")
          return :dispatched
        end
        finalize(pr, review, round, head, run_id)
        :dispatched
      rescue Ci::Gh::Error => e
        @out.puts "Dispatch failed for PR ##{pr}; marker stays pending (will retry)"
        @out.puts e.message
        :skip
      end

      def finalize(pr, review, round, head, run_id)
        run_url = "#{@server_url}/#{@repo}/actions/runs/#{run_id}"
        marker = Markers.state_marker(review: review, pr: pr, round: round, run: run_id, head: head)
        body = "🤖 PR Fixer is working on Copilot review [`#{review}`](#{review_url(pr, review)}) " \
               "(round #{round}, fixes by [@#{@token_user}](#{@server_url}/#{@token_user})) — " \
               "[run \\##{run_id}](#{run_url}) for head `#{head[0, 7]}`. #{marker}"
        # Only log a failure; the dispatch already happened, and the next cycle
        # re-evaluates the still-pending marker. The caller stops the cycle
        # either way (one dispatch per cycle).
        return if write_marker(body, run_id, pr)

        @out.puts "PR ##{pr}: could not persist outcome for run #{run_id}; ending this cycle"
      end

      def write_marker(body, run_id, pr)
        3.times { return true if safe_patch(@pending_comment_id, body) }

        @out.puts "PR ##{pr}: could not update marker #{@pending_comment_id} for run #{run_id}; posting fallback"
        resp = @gh.post("repos/#{@repo}/issues/#{pr}/comments", { "body" => body })
        @pending_comment_id = JSON.parse(resp)["id"].to_s
        true
      rescue Ci::Gh::Error
        false
      end

      def safe_patch(comment_id, body)
        @gh.patch("repos/#{@repo}/issues/comments/#{comment_id}", { "body" => body })
        true
      rescue Ci::Gh::Error
        false
      end

      def review_url(pr, review)
        "#{@server_url}/#{@repo}/pull/#{pr}#pullrequestreview-#{review}"
      end

      def log(message)
        @out.puts message
        nil
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Ci::PrFixOrchestrator::Runner.new(
    client: Ci::Gh.new(token: ENV["GH_TOKEN"]),
    repo: ENV.fetch("REPO"),
    server_url: ENV.fetch("SERVER_URL"),
    author: ENV.fetch("AUTHOR", "asbjornu"),
    max_rounds: ENV.fetch("MAX_ROUNDS", "6"),
    dispatch_token: ENV["GH_AW_DISPATCH_TOKEN"]
  ).run
end
