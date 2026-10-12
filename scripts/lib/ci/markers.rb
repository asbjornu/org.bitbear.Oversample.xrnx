# frozen_string_literal: true

module Ci
  # Machine-readable state that the PR Fixer workflows pass between runs via
  # sticky comments. Centralised so the orchestrator and squash agree on the
  # format (the shell versions parsed this with sed/awk in two places).
  module Markers
    STATE = "<!-- aw-pr-fix-state"
    ANCHOR = "<!-- aw-pr-fix-squash-anchor"
    FAILURE = "<!-- aw-pr-fix-failure"

    State = Struct.new(:review, :pr, :round, :run, :head, :comment_id,
                       keyword_init: true)
    Anchor = Struct.new(:review, :head, :comment_id, keyword_init: true)

    module_function

    def parse_state(body, comment_id = nil)
      return nil unless body.to_s.include?(STATE)

      State.new(
        review: body[/review=(\d+)/, 1],
        pr: body[/\bpr=(\d+)/, 1],
        round: body[/round=(\d+)/, 1],
        run: body[/run=(\d+)/, 1],
        head: body[/head=([0-9a-f]+)/, 1],
        comment_id: comment_id
      )
    end

    def parse_anchor(body, comment_id = nil)
      return nil unless body.to_s.include?(ANCHOR)

      Anchor.new(
        review: body[/review=(\d+)/, 1],
        head: body[/head=([0-9a-f]+)/, 1],
        comment_id: comment_id
      )
    end

    def state_marker(review:, pr:, round:, run:, head:)
      "<!-- aw-pr-fix-state review=#{review} pr=#{pr} round=#{round} " \
        "run=#{run} head=#{head} -->"
    end

    def anchor_marker(review:, head:)
      "<!-- aw-pr-fix-squash-anchor review=#{review} head=#{head} -->"
    end

    def failure_marker(run_id)
      "<!-- aw-pr-fix-failure run=#{run_id} -->"
    end

    # Latest comment authored by +who+ whose body contains +needle+, or nil.
    def latest(client, repo, pr, who, needle)
      comments = client.get_all("repos/#{repo}/issues/#{pr}/comments?per_page=100")
      mine = comments.select do |c|
        c["body"].to_s.include?(needle) && c.dig("user", "login") == who
      end
      mine.max_by { |c| c["created_at"] }
    end

    # Parsed State for the latest fixer-state marker, or nil.
    def latest_state(client, repo, pr, who)
      comment = latest(client, repo, pr, who, STATE)
      comment && parse_state(comment["body"], comment["id"].to_s)
    end

    # Parsed Anchor for the latest squash anchor, or nil.
    def latest_anchor(client, repo, pr, who)
      comment = latest(client, repo, pr, who, ANCHOR)
      comment && parse_anchor(comment["body"], comment["id"].to_s)
    end
  end
end
