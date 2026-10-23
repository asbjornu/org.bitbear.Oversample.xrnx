#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "stringio"

require_relative "../scripts/pr_fix_squash"
require_relative "support/fake_gh"
require_relative "support/fake_git"

module Ci
  class PrFixSquashTest < Minitest::Test
    def runner(gh, git)
      out = StringIO.new
      err = StringIO.new
      r = PrFixSquash::Runner.new(
        git: git, client: gh, repo: "o/r", number: 1,
        base_ref: "main", head_ref: "fix/pr", token_user: "maintainer",
        seq_editor: "ruby /tmp/seq_editor.rb", out: out, err: err
      )
      [r, out, err]
    end

    def git
      FakeGit.new(merge_base: "basesha", rev_parse: { "HEAD" => "newhead" },
                  ls_remote: "newhead")
    end

    def comments_with_markers(anchor_id: 55)
      [
        { "body" => Markers.state_marker(review: "77", pr: "1", round: "2",
                                         run: "111", head: "base00"),
          "id" => 900, "created_at" => "2024-01-02T00:00:00Z",
          "user" => { "login" => "maintainer" } },
        { "body" => Markers.anchor_marker(review: "77", head: "base00"),
          "id" => anchor_id, "created_at" => "2024-01-01T00:00:00Z",
          "user" => { "login" => "maintainer" } }
      ]
    end

    def test_nothing_to_squash_without_active_dispatch
      gh = FakeGh.new
      gh.on(:get_all, %r{/comments}) { [] }
      g = git
      r, out, = runner(gh, g)
      assert_equal 0, r.run
      assert_includes out.string, "nothing to squash"
      assert_empty g.events.select { |e| e.first == :rebase }
    end

    def test_squashes_fixups_and_records_anchor
      gh = FakeGh.new
      gh.on(:get_all, %r{/comments}) { comments_with_markers }
      gh.on(:get, %r{/compare/}) do
        { "total_commits" => 2,
          "commits" => [
            { "author" => { "login" => Ci::FIXER_BOT }, "commit" => { "message" => "fix things" } },
            { "author" => { "login" => Ci::FIXER_BOT }, "commit" => { "message" => "fixup! fix things" } }
          ] }
      end
      gh.on(:patch, %r{/issues/comments/55$}) { "{}" }
      g = git
      r, out, = runner(gh, g)
      assert_equal 0, r.run

      rebase = g.events.find { |e| e.first == :rebase }
      assert_includes rebase[2]["GIT_SEQUENCE_EDITOR"], "seq_editor.rb"
      assert(g.events.any? { |e| e.first == :push })
      assert_includes out.string, "Squashed and force-pushed"
      assert_equal ["repos/o/r/issues/comments/55"], gh.events_for(:patch).map(&:first)
      assert_includes gh.events_for(:patch).first[1]["body"], "aw-pr-fix-squash-anchor"
    end

    def test_rebase_failure_requests_review_and_fails
      gh = FakeGh.new
      gh.on(:get_all, %r{/comments}) { comments_with_markers }
      gh.on(:get, %r{/compare/}) do
        { "total_commits" => 1,
          "commits" => [{ "author" => { "login" => Ci::FIXER_BOT },
                          "commit" => { "message" => "fixup! fix things" } }] }
      end
      gh.on(:post, %r{/requested_reviewers}) { "{}" }
      g = FakeGit.new(merge_base: "basesha", rev_parse: { "HEAD" => "newhead" },
                      ls_remote: "newhead", rebase_ok: false)
      r, out, = runner(gh, g)
      assert_equal 1, r.run
      assert_includes out.string, "Squash failed"
      assert_equal ["repos/o/r/pulls/1/requested_reviewers"],
                   gh.events_for(:post).map(&:first)
    end

    def test_unlanded_push_requests_review_and_fails
      gh = FakeGh.new
      gh.on(:get_all, %r{/comments}) { comments_with_markers }
      gh.on(:get, %r{/compare/}) do
        { "total_commits" => 1,
          "commits" => [{ "author" => { "login" => Ci::FIXER_BOT },
                          "commit" => { "message" => "fixup! fix things" } }] }
      end
      gh.on(:post, %r{/requested_reviewers}) { "{}" }
      g = FakeGit.new(merge_base: "basesha", rev_parse: { "HEAD" => %w[orighead newhead] },
                      ls_remote: "orighead")
      r, _out, err = runner(gh, g)
      assert_equal 1, r.run
      assert_includes err.string, "did not land"
      assert_equal ["repos/o/r/pulls/1/requested_reviewers"],
                   gh.events_for(:post).map(&:first)
    end

    def test_superseded_push_does_not_request_review
      gh = FakeGh.new
      gh.on(:get_all, %r{/comments}) { comments_with_markers }
      gh.on(:get, %r{/compare/}) do
        { "total_commits" => 1,
          "commits" => [{ "author" => { "login" => Ci::FIXER_BOT },
                          "commit" => { "message" => "fixup! fix things" } }] }
      end
      gh.on(:post, %r{/requested_reviewers}) { "{}" }
      g = FakeGit.new(merge_base: "basesha", rev_parse: { "HEAD" => %w[orighead newhead] },
                      ls_remote: "otherhead")
      r, out, = runner(gh, g)
      assert_equal 0, r.run
      assert_includes out.string, "newer push drives the loop"
      assert_empty gh.events_for(:post)
    end

    def test_compare_failure_requests_review_and_fails
      gh = FakeGh.new
      gh.on(:get_all, %r{/comments}) { comments_with_markers }
      gh.on(:get, %r{/compare/}) { raise Ci::Gh::Error, "boom" }
      gh.on(:post, %r{/requested_reviewers}) { "{}" }
      r, _out, err = runner(gh, git)
      r.define_singleton_method(:sleep) { |_seconds| }
      assert_equal 1, r.run
      assert_includes err.string, "Could not read the compare range"
      assert_equal ["repos/o/r/pulls/1/requested_reviewers"],
                   gh.events_for(:post).map(&:first)
    end

    def test_normal_path_review_request_failure_propagates
      gh = FakeGh.new
      gh.on(:get_all, %r{/comments}) { comments_with_markers }
      gh.on(:get, %r{/compare/}) do
        { "total_commits" => 1,
          "commits" => [{ "author" => { "login" => Ci::FIXER_BOT },
                          "commit" => { "message" => "ordinary fix" } }] }
      end
      gh.on(:post, %r{/requested_reviewers}) { raise Ci::Gh::Error, "boom" }
      r, = runner(gh, git)
      assert_raises(Ci::Gh::Error) { r.run }
    end

    def test_normal_commits_request_review_without_rewriting
      gh = FakeGh.new
      gh.on(:get_all, %r{/comments}) { comments_with_markers }
      gh.on(:get, %r{/compare/}) do
        { "total_commits" => 1,
          "commits" => [{ "author" => { "login" => Ci::FIXER_BOT },
                          "commit" => { "message" => "ordinary fix" } }] }
      end
      gh.on(:post, %r{/requested_reviewers}) { "{}" }
      g = git
      r, out, = runner(gh, g)
      assert_equal 0, r.run
      assert_includes out.string, "requesting a review"
      refute(g.events.any? { |e| e.first == :rebase })
      assert_equal ["repos/o/r/pulls/1/requested_reviewers"],
                   gh.events_for(:post).map(&:first)
    end
  end
end
