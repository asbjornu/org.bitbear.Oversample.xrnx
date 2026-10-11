#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "stringio"

require_relative "../scripts/copilot_review_request"
require_relative "support/fake_gh"

module Ci
  class CopilotReviewRequestTest < Minitest::Test
    HEAD = "head123"

    def runner(gh)
      out = StringIO.new
      r = CopilotReviewRequest::Runner.new(client: gh, repo: "o/r", number: 1,
                                           author: "asbjornu", out: out)
      [r, out]
    end

    def pull(overrides = {})
      { "state" => "open", "draft" => false,
        "user" => { "login" => "asbjornu" },
        "head" => { "repo" => { "full_name" => "o/r" }, "sha" => HEAD } }.merge(overrides)
    end

    def base_gh
      gh = FakeGh.new(login: "maintainer")
      gh.on(:get, %r{/pulls/1$}) { pull }
      gh.on(:get_all, %r{/commits}) { [] }
      gh.on(:get_all, %r{/reviews}) { [] }
      gh.on(:post, %r{/requested_reviewers}) { "{}" }
      gh
    end

    def test_draft_is_skipped
      gh = base_gh
      gh.on(:get, %r{/pulls/1$}) { pull("draft" => true) }
      r, out = runner(gh)
      r.run
      assert_includes out.string, "is a draft"
      assert_empty gh.events_for(:post)
    end

    def test_foreign_author_is_skipped
      gh = base_gh
      gh.on(:get, %r{/pulls/1$}) { pull("user" => { "login" => "someone" }) }
      r, out = runner(gh)
      r.run
      assert_includes out.string, "not asbjornu"
      assert_empty gh.events_for(:post)
    end

    def test_fork_is_skipped
      gh = base_gh
      gh.on(:get, %r{/pulls/1$}) { pull("head" => { "repo" => { "full_name" => "x/y" }, "sha" => HEAD }) }
      r, out = runner(gh)
      r.run
      assert_includes out.string, "fork"
      assert_empty gh.events_for(:post)
    end

    def test_requests_review_when_head_unreviewed
      gh = base_gh
      r, out = runner(gh)
      r.run
      assert_includes out.string, "Requested a Copilot review"
      assert_equal ["repos/o/r/pulls/1/requested_reviewers"],
                   gh.events_for(:post).map(&:first)
    end

    def test_request_failure_propagates
      gh = base_gh
      gh.on(:post, %r{/requested_reviewers}) { raise Ci::Gh::Error, "boom" }
      r, = runner(gh)
      assert_raises(Ci::Gh::Error) { r.run }
    end

    def test_skips_when_head_already_reviewed
      gh = base_gh
      gh.on(:get_all, %r{/reviews}) do
        [{ "user" => { "login" => "copilot-pull-request-reviewer[bot]" }, "commit_id" => HEAD }]
      end
      r, out = runner(gh)
      r.run
      assert_includes out.string, "already has a Copilot review"
      assert_empty gh.events_for(:post)
    end

    def test_quiet_skip_when_fixer_only_head_under_active_dispatch
      gh = base_gh
      gh.on(:get_all, %r{/commits}) do
        [{ "commit" => { "message" => "fixup! Add thing" },
           "author" => { "login" => "github-actions[bot]" } }]
      end
      gh.on(:get_all, %r{/issues/1/comments}) do
        [{ "body" => Markers.state_marker(review: "1", pr: "1", round: "1",
                                          run: "9", head: "base00"),
           "id" => 1, "created_at" => "2024-01-01T00:00:00Z",
           "user" => { "login" => "maintainer" } }]
      end
      gh.on(:get, %r{/compare/}) do
        { "status" => "ahead", "total_commits" => 1,
          "commits" => [{ "author" => { "login" => "github-actions[bot]" } }] }
      end
      r, out = runner(gh)
      r.run
      assert_includes out.string, "squash workflow will re-request"
      assert_empty gh.events_for(:post)
    end
  end
end
