#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

require_relative "../scripts/lib/ci"
require_relative "support/fake_gh"

module Ci
  class MarkersTest < Minitest::Test
    def test_parse_state
      body = "🤖 … <!-- aw-pr-fix-state review=42 pr=7 round=3 run=12345 head=abc123 -->"
      state = Markers.parse_state(body, "99")
      assert_equal "42", state.review
      assert_equal "7", state.pr
      assert_equal "3", state.round
      assert_equal "12345", state.run
      assert_equal "abc123", state.head
      assert_equal "99", state.comment_id
    end

    def test_parse_state_run_none_is_nil
      body = "<!-- aw-pr-fix-state review=1 pr=2 round=0 run=none head=deadbeef -->"
      assert_nil Markers.parse_state(body).run
    end

    def test_parse_state_rejects_non_marker
      assert_nil Markers.parse_state("just a comment")
    end

    def test_parse_anchor
      body = "<!-- aw-pr-fix-squash-anchor review=42 head=abc123 -->"
      anchor = Markers.parse_anchor(body, "5")
      assert_equal "42", anchor.review
      assert_equal "abc123", anchor.head
      assert_equal "5", anchor.comment_id
    end

    def test_state_marker_round_trips
      marker = Markers.state_marker(review: "1", pr: "2", round: "3", run: "4", head: "aa")
      state = Markers.parse_state(marker)
      assert_equal %w[1 2 3 4 aa], [state.review, state.pr, state.round, state.run, state.head]
    end

    def test_latest_picks_newest_authored_by_user
      gh = FakeGh.new
      gh.on(:get_all, %r{/comments}) do
        [
          { "body" => "<!-- aw-pr-fix-state review=1 pr=9 round=1 run=111 head=a -->",
            "id" => 1, "created_at" => "2024-01-01T00:00:00Z", "user" => { "login" => "me" } },
          { "body" => "<!-- aw-pr-fix-state review=2 pr=9 round=2 run=222 head=b -->",
            "id" => 2, "created_at" => "2024-01-02T00:00:00Z", "user" => { "login" => "me" } },
          { "body" => "<!-- aw-pr-fix-state review=9 pr=9 round=9 run=999 head=c -->",
            "id" => 3, "created_at" => "2024-01-03T00:00:00Z", "user" => { "login" => "attacker" } }
        ]
      end
      comment = Markers.latest(gh, "o/r", 9, "me", Markers::STATE)
      assert_equal 2, comment["id"]
    end
  end
end
