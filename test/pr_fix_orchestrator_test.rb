#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "stringio"

require_relative "../scripts/pr_fix_orchestrator"
require_relative "support/fake_gh"

module Ci
  class PrFixOrchestratorTest < Minitest::Test
    def runner(gh)
      out = StringIO.new
      r = PrFixOrchestrator::Runner.new(
        client: gh, repo: "o/r", server_url: "https://github.com",
        author: "asbjornu", max_rounds: 6, dispatch_token: "dispatch-token", out: out
      )
      [r, out]
    end

    def base_gh
      gh = FakeGh.new(login: "maintainer")
      gh.on(:get, "repos/o/r/actions/workflows") do
        { "workflows" => [{ "id" => 5, "path" => PrFixOrchestrator::LOCK_PATH }] }
      end
      gh.on(:get, %r{runs\?status=in_progress}) { { "total_count" => 0 } }
      gh.on(:get, %r{runs\?status=queued}) { { "total_count" => 0 } }
      gh.on(:get_all, %r{/pulls\?state=open}) do
        [{ "number" => 1, "draft" => false,
           "user" => { "login" => "asbjornu" },
           "head" => { "repo" => { "full_name" => "o/r" } },
           "base" => { "repo" => { "full_name" => "o/r" } } }]
      end
      gh.on(:get, "repos/o/r/pulls/1") { { "head" => { "sha" => "head1" } } }
      gh.on(:get_all, %r{/issues/1/comments}) { [] }
      gh.on(:get_all, %r{/reviews}) do
        [{ "id" => 77, "state" => "COMMENTED", "commit_id" => "head1",
           "submitted_at" => "2024-01-01T00:00:00Z",
           "user" => { "login" => "copilot-pull-request-reviewer[bot]" } }]
      end
      gh.on(:post, %r{/issues/1/comments}) { '{"id":900}' }
      gh.on(:patch, %r{/issues/comments/900}) { "{}" }
      gh.on(:run, ->(*args) { args.first == "aw" }) do
        "View workflow run: https://github.com/o/r/actions/runs/424242\n"
      end
      gh
    end

    def test_no_workflow_on_default_branch
      gh = FakeGh.new(login: "maintainer")
      gh.on(:get, "repos/o/r/actions/workflows") { { "workflows" => [] } }
      r, out = runner(gh)
      r.run
      assert_includes out.string, "nothing to do"
      assert_empty gh.events_for(:run)
    end

    def test_skips_when_a_run_is_pending
      gh = base_gh
      gh.on(:get, %r{runs\?status=in_progress}) { { "total_count" => 1 } }
      r, out = runner(gh)
      r.run
      assert_includes out.string, "already pending"
      assert_empty gh.events_for(:run)
    end

    def test_dispatches_one_pr_and_records_run
      gh = base_gh
      r, out = runner(gh)
      r.run
      assert_includes out.string, "dispatching fixer for review 77 (round 1)"
      assert_equal 1, gh.events_for(:run).length

      patch = gh.events_for(:patch).first
      assert_equal "repos/o/r/issues/comments/900", patch[0]
      assert_includes patch[1]["body"], "run=424242"
      assert_includes patch[1]["body"], "<!-- aw-pr-fix-state"
    end

    def test_dispatch_without_run_url_stops_the_cycle
      gh = base_gh
      gh.on(:get_all, %r{/pulls\?state=open}) do
        [
          { "number" => 1, "draft" => false,
            "user" => { "login" => "asbjornu" },
            "head" => { "repo" => { "full_name" => "o/r" } },
            "base" => { "repo" => { "full_name" => "o/r" } } },
          { "number" => 2, "draft" => false,
            "user" => { "login" => "asbjornu" },
            "head" => { "repo" => { "full_name" => "o/r" } },
            "base" => { "repo" => { "full_name" => "o/r" } } }
        ]
      end
      gh.on(:run, ->(*args) { args.first == "aw" }) { "dispatched, no run url\n" }
      r, out = runner(gh)
      r.run
      assert_includes out.string, "dispatched run not identified"
      assert_equal 1, gh.events_for(:run).length
    end

    def test_reports_terminal_failure_and_redispatches
      gh = base_gh
      gh.on(:get_all, %r{/issues/1/comments}) do
        [{ "body" => "<!-- aw-pr-fix-state review=77 pr=1 round=1 run=111 head=head1 -->",
           "id" => 900, "created_at" => "2024-01-01T00:00:00Z",
           "user" => { "login" => "maintainer" } }]
      end
      gh.on(:api, %r{/actions/runs/111}) { "failure" }
      gh.on(:get, %r{/actions/runs/111/jobs}) do
        { "jobs" => [{ "name" => "squash", "conclusion" => "failure" }] }
      end
      gh.on(:post, %r{/issues/1/comments}) { '{"id":901}' }
      r, out = runner(gh)
      r.run
      assert_includes out.string, "concluded failure; re-dispatching"
      bodies = gh.events_for(:post).map { |(_path, body)| body["body"] }
      assert(bodies.any? { |b| b.include?("PR Fixer run failed") && b.include?("squash") })
    end
  end
end
