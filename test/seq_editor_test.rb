#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

require_relative "../scripts/lib/ci"

module Ci
  class SeqEditorTest < Minitest::Test
    def setup
      @subjects = {}
      @authors = {}
      @bodies = {}
      @sha = {}
    end

    def rewrite(lines)
      SeqEditor.rewrite(
        lines,
        resolve: ->(token) { @sha.fetch(token, token) },
        subject: ->(sha) { @subjects[sha] },
        author: ->(sha) { @authors[sha] },
        body: ->(sha) { @bodies[sha] }
      )
    end

    def test_moves_fixup_after_target_by_recorded_sha
      @sha = { "a" => "aaaa111", "b" => "bbbb222", "c" => "cccc333" }
      @subjects = {
        "aaaa111" => "Add feature",
        "bbbb222" => "Add test",
        "cccc333" => "fixup! Add feature",
      }
      @authors = { "cccc333" => Ci::FIXER_BOT }
      @bodies = { "cccc333" => "subject\n\naw-fixup-target=aaaa111" }

      todo = ["pick a Add feature", "pick b Add test", "fixup c Add feature"]
      assert_equal ["pick a Add feature", "fixup cccc333", "pick b Add test"], rewrite(todo)
    end

    def test_falls_back_to_subject_match_when_target_sha_stale
      @sha = { "a" => "aaaa111", "b" => "bbbb222", "c" => "cccc333" }
      @subjects = {
        "aaaa111" => "Add feature",
        "bbbb222" => "Add test",
        "cccc333" => "fixup! Add feature",
      }
      @authors = { "cccc333" => Ci::FIXER_BOT }
      @bodies = { "cccc333" => "subject\n\naw-fixup-target=dead999" }

      todo = ["pick a Add feature", "pick b Add test", "fixup c Add feature"]
      assert_equal ["pick a Add feature", "fixup cccc333", "pick b Add test"], rewrite(todo)
    end

    def test_aborts_when_fixer_fixup_has_no_target
      @sha = { "a" => "aaaa111", "c" => "cccc333" }
      @subjects = { "aaaa111" => "Add feature", "cccc333" => "fixup! Missing feature" }
      @authors = { "cccc333" => Ci::FIXER_BOT }
      @bodies = { "cccc333" => "aw-fixup-target=dead999" }

      todo = ["pick a Add feature", "fixup c Missing feature"]
      assert_raises(Ci::SeqEditor::UnmatchedFixup) { rewrite(todo) }
    end

    def test_ignores_fixup_by_non_bot
      @sha = { "a" => "aaaa111", "c" => "cccc333" }
      @subjects = { "aaaa111" => "Add feature", "cccc333" => "fixup! Add feature" }
      @authors = { "cccc333" => "someone" }

      todo = ["pick a Add feature", "fixup c Add feature"]
      assert_equal todo, rewrite(todo)
    end

    def test_two_fixups_keep_their_order
      @sha = { "a" => "aaaa111", "c" => "cccc333", "d" => "dddd444" }
      @subjects = {
        "aaaa111" => "Add feature",
        "cccc333" => "fixup! Add feature",
        "dddd444" => "fixup! Add feature",
      }
      @authors = { "cccc333" => Ci::FIXER_BOT, "dddd444" => Ci::FIXER_BOT }
      @bodies = {
        "cccc333" => "aw-fixup-target=aaaa111",
        "dddd444" => "aw-fixup-target=aaaa111",
      }

      todo = ["pick a Add feature", "fixup c Add feature", "fixup d Add feature"]
      assert_equal ["pick a Add feature", "fixup cccc333", "fixup dddd444"], rewrite(todo)
    end

    def test_target_sha_uses_last_match
      body = "aw-fixup-target=aaaa111\nmore text\naw-fixup-target=bbbb222"
      assert_equal "bbbb222", SeqEditor.target_sha(body)
    end

    def test_target_sha_rejects_short_or_nonhex
      assert_nil SeqEditor.target_sha("aw-fixup-target=abc")
      assert_nil SeqEditor.target_sha("aw-fixup-target=zzzzzzz")
    end
  end
end
