#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "stringio"

require_relative "../scripts/sensitive_file_warning"
require_relative "support/fake_gh"

module Ci
  class SensitiveMatchingTest < Minitest::Test
    include SensitiveFileWarning

    def test_anchored_not_substring
      assert_empty matching_files(["docs/my.github/x"])
    end

    def test_selects_and_preserves_order
      files = ["src/a.lua", "AGENTS.md", ".github/workflows/x.yml", "README.md"]
      assert_equal ["AGENTS.md", ".github/workflows/x.yml", "README.md"],
                   matching_files(files)
    end

    def test_empty_input
      assert_empty matching_files([])
    end
  end

  class SensitiveCommentBodyTest < Minitest::Test
    include SensitiveFileWarning

    def test_body_shape
      body = comment_body(["AGENTS.md", "README.md"])
      assert_includes body, MARKER
      assert_includes body, "> [!WARNING]"
      assert_includes body, "- `AGENTS.md`"
      assert_includes body, "- `README.md`"
      assert_includes body, "before merge"
    end
  end

  class SensitiveRunnerTest < Minitest::Test
    FILES = "repos/o/r/pulls/1/files?per_page=100"
    COMMENTS = "repos/o/r/issues/1/comments?per_page=100"
    POST_COMMENTS = "repos/o/r/issues/1/comments"

    def build(files:, comments: [])
      gh = FakeGh.new
      gh.on(:get_all, FILES, files.map { |f| { "filename" => f } })
      gh.on(:get_all, COMMENTS, comments)
      gh.on(:post, POST_COMMENTS) { '{"id":900}' }
      gh.on(:patch, %r{/issues/comments/\d+$}) { "{}" }
      gh.on(:delete, %r{/issues/comments/\d+$}) { "" }
      out = StringIO.new
      [gh, out, SensitiveFileWarning::Runner.new(
        client: gh, repo: "o/r", number: 1, token_user: "maintainer", out: out
      )]
    end

    def test_no_hits_no_comment_does_nothing
      gh, out, runner = build(files: ["src/a.lua"])
      runner.run
      assert_includes out.string, "No sensitive files touched."
      assert_empty gh.events_for(:post)
      assert_empty gh.events_for(:delete)
    end

    def test_no_hits_deletes_existing_comment
      gh, _out, runner = build(
        files: ["src/a.lua"],
        comments: [{ "body" => SensitiveFileWarning::MARKER, "id" => 555,
                     "user" => { "login" => "maintainer" } }]
      )
      runner.run
      assert_equal ["repos/o/r/issues/comments/555"], gh.events_for(:delete).map(&:first)
    end

    def test_ignores_marker_comment_from_other_user
      gh, _out, runner = build(
        files: ["src/a.lua"],
        comments: [{ "body" => SensitiveFileWarning::MARKER, "id" => 555,
                     "user" => { "login" => "intruder" } }]
      )
      runner.run
      assert_empty gh.events_for(:delete)
      assert_empty gh.events_for(:patch)
    end

    def test_hits_no_comment_posts
      gh, _out, runner = build(files: ["src/a.lua", ".github/workflows/x.yml"])
      runner.run
      path, body = gh.events_for(:post).first
      assert_equal POST_COMMENTS, path
      assert_includes body["body"], SensitiveFileWarning::MARKER
      assert_includes body["body"], ".github/workflows/x.yml"
    end

    def test_hits_existing_comment_patches
      gh, _out, runner = build(
        files: ["AGENTS.md"],
        comments: [{ "body" => SensitiveFileWarning::MARKER, "id" => 777,
                     "user" => { "login" => "maintainer" } }]
      )
      runner.run
      assert_equal ["repos/o/r/issues/comments/777"], gh.events_for(:patch).map(&:first)
      assert_empty gh.events_for(:post)
    end

    def test_posts_its_own_when_marker_is_from_other_user
      gh, _out, runner = build(
        files: ["AGENTS.md"],
        comments: [{ "body" => SensitiveFileWarning::MARKER, "id" => 777,
                     "user" => { "login" => "intruder" } }]
      )
      runner.run
      assert_equal [POST_COMMENTS], gh.events_for(:post).map(&:first)
      assert_empty gh.events_for(:patch)
    end
  end
end
