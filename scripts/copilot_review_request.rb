#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Requests a Copilot review for the current head of a same-repo PR authored by
# the fixer author, unless the head already carries one or the head only holds
# fixer commits under an active dispatch. See copilot-review-request.yml.

require_relative "lib/ci"

module Ci
  module CopilotReviewRequest
    class Runner
      def initialize(client:, repo:, number:, author:, out: $stdout)
        @gh = client
        @repo = repo
        @number = number
        @author = author
        @out = out
      end

      def run
        @token_user = @gh.login
        pull = @gh.get("repos/#{@repo}/pulls/#{@number}")

        return skip("is #{pull['state']}") unless pull["state"] == "open"
        return skip("is a draft") if pull["draft"] == true
        author = pull.dig("user", "login")
        return skip("author is #{author}, not #{@author}") unless author == @author

        head_repo = pull.dig("head", "repo", "full_name")
        return skip("is from a fork (#{head_repo})") unless head_repo == @repo

        head = pull.dig("head", "sha")
        return if quiet_skip_for_fixer_head(head)

        reviewed = copilot_reviews_on(head)
        return skip("head #{head} already has a Copilot review") unless reviewed.zero?

        request_review
        @out.puts "Requested a Copilot review for PR ##{@number} at #{head}"
      end

      private

      # True when the head only holds fixer commits under an active dispatch, in
      # which case the squash workflow will re-request on our behalf.
      def quiet_skip_for_fixer_head(head)
        commits = @gh.get_all("repos/#{@repo}/pulls/#{@number}/commits?per_page=100")
        fixup_authors = commits.select { |c| c.dig("commit", "message").to_s.start_with?("fixup!") }
                               .map { |c| c.dig("author", "login") || "unknown" }
        return false unless all_bot?(fixup_authors)

        state = Markers.latest_state(@gh, @repo, @number, @token_user)
        marker_head = state&.head
        entries = []
        status = "diverged"
        truncated = false
        unless marker_head.nil? || marker_head.empty?
          cmp = compare(marker_head, head)
          status = cmp["status"] || "diverged"
          total = cmp["total_commits"] || 0
          entries = cmp["commits"] || []
          truncated = total > entries.length
        end
        range_authors = entries.map { |c| c.dig("author", "login") || "unknown" }

        if !truncated && %w[ahead identical].include?(status) &&
           !range_authors.empty? && all_bot?(range_authors)
          @out.puts "Head has only fixer commits under an active dispatch; " \
                    "the squash workflow will re-request"
          return true
        end

        @out.puts "Fixer fixup! commits present but no purely-fixer active " \
                  "dispatch; requesting a review"
        false
      end

      def copilot_reviews_on(head)
        @gh.get_all("repos/#{@repo}/pulls/#{@number}/reviews?per_page=100")
           .count { |r| Ci.copilot_review?(r) && r["commit_id"] == head }
      end

      def compare(base, head)
        @gh.get("repos/#{@repo}/compare/#{base}...#{head}")
      rescue Ci::Gh::Error
        {}
      end

      def request_review
        @gh.post("repos/#{@repo}/pulls/#{@number}/requested_reviewers",
                 { "reviewers" => ["copilot-pull-request-reviewer[bot]"] })
      end

      def all_bot?(logins)
        !logins.empty? && logins.all? { |l| l == Ci::FIXER_BOT }
      end

      def skip(reason)
        @out.puts "PR ##{@number} #{reason}; skipping"
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Ci::CopilotReviewRequest::Runner.new(
    client: Ci::Gh.new,
    repo: ENV.fetch("REPO"),
    number: ENV.fetch("PR"),
    author: ENV.fetch("AUTHOR", "asbjornu")
  ).run
end
