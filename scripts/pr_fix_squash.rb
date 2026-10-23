#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Folds the fixer's fixup! commits on a PR branch and force-pushes, then records
# a squash anchor so later runs know which head was already folded. The
# branch is fixer-managed between rounds. See pr-fix-squash.yml.

require_relative "lib/ci"
require "shellwords"

module Ci
  module PrFixSquash
    class Runner
      def initialize(git:, client:, repo:, number:, base_ref:, head_ref:,
                     token_user:, seq_editor:, out: $stdout, err: $stderr)
        @git = git
        @gh = client
        @repo = repo
        @number = number
        @base_ref = base_ref
        @head_ref = head_ref
        @token_user = token_user
        @seq_editor = seq_editor
        @out = out
        @err = err
      end

      def run
        @git.config("user.name", Ci::FIXER_BOT)
        @git.config("user.email", "#{Ci::FIXER_BOT}@users.noreply.github.com")
        base = @git.merge_base("origin/#{@base_ref}", "HEAD")

        state = Markers.latest_state(@gh, @repo, @number, @token_user)
        anchor = Markers.latest_anchor(@gh, @repo, @number, @token_user)
        @anchor_id = anchor&.comment_id

        anchor_head = choose_anchor(published: anchor&.head, anchor_review: anchor&.review,
                                    state_review: state&.review, state_head: state&.head)
        if anchor_head.nil?
          log("No active fixer dispatch for this head; nothing to squash")
          return 0
        end

        head = @git.rev_parse("HEAD")
        cmp = compare(anchor_head, head)
        if cmp.nil?
          warn("Could not read the compare range; requesting a review to recover")
          request_review
          return 1
        end

        commits = cmp["commits"] || []
        if (cmp["total_commits"] || 0) > commits.length
          log("Compare range truncated; refusing to rewrite")
          return 0
        end

        case verdict(commits)
        when "fixups"
          run_rebase(base, state&.review, head)
        when "normal"
          log("Only fixer normal commits since dispatch; requesting a review")
          request_review
          0
        else
          log("Commits since the dispatch head are not purely fixer fixups; nothing to squash")
          0
        end
      end

      private

      # Prefer this workflow's own anchor for the same round, then the
      # orchestrator's dispatch head, then an earlier anchor. The dispatch head
      # is used only while it is still an ancestor of HEAD: a concurrent
      # re-dispatch can record a head this run already rewrote.
      def choose_anchor(published:, anchor_review:, state_review:, state_head:)
        if state_review && anchor_review == state_review && published && ancestor?(published)
          published
        elsif state_head && ancestor?(state_head)
          state_head
        elsif published && ancestor?(published)
          log("Dispatch head is not an ancestor; keeping the published anchor #{published}")
          published
        end
      end

      def ancestor?(ref)
        @git.ancestor?(ref, "HEAD")
      end

      def run_rebase(base, review, orig_head)
        unless rebase(base)
          log("Squash failed; requesting a review")
          request_review
          return 1
        end

        new_head = @git.rev_parse("HEAD")
        begin
          @git.push("--force-with-lease", "origin", "HEAD:#{@head_ref}")
        rescue Ci::Git::Error
          # The verify step below treats an unlanded push as a recovery.
        end
        verify_and_anchor(new_head, review, orig_head)
      end

      def rebase(base)
        _out, _err, status = @git.rebase(
          ["-i", "--rebase-merges", base],
          env: { "GIT_SEQUENCE_EDITOR" => @seq_editor, "GIT_EDITOR" => ":" }
        )
        return true if status.success?

        @git.run("rebase", "--abort")
        false
      end

      # A rejected --force-with-lease usually means another push already moved
      # the remote head, and that push fired its own synchronize. Requesting a
      # review from this stale run would race the queued squash and could review
      # the newer, still-unsquashed head, so only recover when the remote stayed
      # unchanged (or could not be read).
      def verify_and_anchor(new_head, review, orig_head)
        remote_head, verified = verify_remote(new_head)
        if verified
          log("Squashed and force-pushed #{@head_ref}")
          3.times { return 0 if write_anchor(review, new_head) }
          warn("Could not record the squash anchor at #{new_head}")
        elsif remote_head && remote_head != orig_head
          log("Remote head moved to #{remote_head[0, 12]}; a newer push drives the loop")
          return 0
        else
          warn("Squash did not land or could not be verified (remote at #{remote_head.to_s[0, 12]})")
        end

        # No synchronize fired, so nothing will retry: request a fresh review
        # (the recovery path) and fail visibly.
        warn("Requesting a fresh review to recover the round")
        request_review
        1
      end

      # Retry ls-remote: a transient failure must not abort the step under
      # `set -e` and strand the anchor after a landed push. Only a remote ref
      # that equals the rewritten head proves the push landed; a reachable but
      # stale ref means `--force-with-lease` rejected the push.
      def verify_remote(new_head)
        remote_head = nil
        3.times do
          begin
            remote_head = @git.ls_remote("origin", "refs/heads/#{@head_ref}")
            return [remote_head, remote_head == new_head]
          rescue Ci::Git::Error
            remote_head = nil
            sleep 3
          end
        end
        [remote_head, false]
      end

      def write_anchor(review, head)
        body = Markers.anchor_marker(review: review, head: head)
        if @anchor_id
          @gh.patch("repos/#{@repo}/issues/comments/#{@anchor_id}", { "body" => body })
        else
          resp = @gh.post("repos/#{@repo}/issues/#{@number}/comments", { "body" => body })
          @anchor_id = JSON.parse(resp)["id"].to_s
        end
        true
      rescue Ci::Gh::Error
        false
      end

      def verdict(commits)
        return "empty" if commits.empty?
        return "mixed" if commits.any? { |c| author_login(c) != Ci::FIXER_BOT }
        return "fixups" if commits.any? { |c| subject(c).start_with?("fixup! ") }

        "normal"
      end

      def author_login(commit)
        commit.dig("author", "login") || "unknown"
      end

      def subject(commit)
        commit.dig("commit", "message").to_s.split("\n").first.to_s
      end

      # Retry a transient read failure: the compare range decides whether we
      # rewrite the branch, so an unreadable response must not masquerade as an
      # empty range, which would report a silent no-op. nil once exhausted.
      def compare(base, head)
        3.times do
          begin
            return @gh.get("repos/#{@repo}/compare/#{base}...#{head}")
          rescue Ci::Gh::Error
            sleep 3
          end
        end
        nil
      end

      def request_review
        @gh.post("repos/#{@repo}/pulls/#{@number}/requested_reviewers",
                 { "reviewers" => ["copilot-pull-request-reviewer[bot]"] })
      end

      def log(message)
        @out.puts message
        nil
      end

      def warn(message)
        @err.puts message
        nil
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  token = ENV["GH_TOKEN"]
  gh = Ci::Gh.new(token: token)
  editor = "ruby #{Shellwords.escape(File.expand_path('seq_editor.rb', __dir__))}"
  exit Ci::PrFixSquash::Runner.new(
    git: Ci::Git.new,
    client: gh,
    repo: ENV.fetch("REPO"),
    number: ENV.fetch("PR"),
    base_ref: ENV.fetch("BASE_REF"),
    head_ref: ENV.fetch("HEAD_REF"),
    token_user: gh.login,
    seq_editor: editor
  ).run
end
