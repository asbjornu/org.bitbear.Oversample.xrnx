#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Flags pull requests that modify files which deserve extra human scrutiny.
# Maintains a single sticky comment per PR and removes it when nothing
# sensitive is touched. See .github/workflows/sensitive-file-warning.yml.

require_relative "lib/ci"

module Ci
  module SensitiveFileWarning
    MARKER = "<!-- sensitive-file-warning -->"

    # Paths that warrant extra review. Mirrors gh-aw's protected-file set plus
    # this repository's dotfiles and dependency manifests.
    PATTERNS = [
      %r{\A\.github/},
      %r{\A\.agents/},
      /\A\.luacheckrc\z/,
      /\A\.gitattributes\z/,
      /\A\.gitignore\z/,
      /\ACODEOWNERS\z/,
      /\AAGENTS\.md\z/,
      /\AREADME\.md\z/,
      /\ALICENSE\z/,
      /\A(package|package-lock)\.json\z/,
      /\A(yarn|pnpm-lock)\.(lock|yaml)\z/,
    ].freeze

    module_function

    # Pure: files matching any pattern, preserving input order.
    def matching_files(files, patterns = PATTERNS)
      files.select { |f| patterns.any? { |p| p.match?(f) } }
    end

    # Pure: the sticky-comment body for the given files.
    def comment_body(files)
      lines = [
        MARKER,
        "> [!WARNING]",
        "> This pull request modifies files that deserve extra scrutiny:",
      ]
      files.each { |f| lines << "- `#{f}`" }
      lines << ""
      lines << "A human should confirm these changes are intended before merge."
      lines.join("\n") + "\n"
    end

    class Runner
      def initialize(client:, repo:, number:, token_user:, out: $stdout)
        @client = client
        @repo = repo
        @number = number
        @token_user = token_user
        @out = out
      end

      def run
        files = @client.get_all("repos/#{@repo}/pulls/#{@number}/files?per_page=100")
                       .map { |f| f["filename"] }
        hits = SensitiveFileWarning.matching_files(files)
        comment = @client.get_all("repos/#{@repo}/issues/#{@number}/comments?per_page=100")
                         .find { |c| owned?(c) }

        if hits.empty?
          @out.puts "No sensitive files touched."
          @client.delete("repos/#{@repo}/issues/comments/#{comment['id']}") if comment
          return
        end

        body = SensitiveFileWarning.comment_body(hits)
        if comment
          @client.patch("repos/#{@repo}/issues/comments/#{comment['id']}", { "body" => body })
        else
          @client.post("repos/#{@repo}/issues/#{@number}/comments", { "body" => body })
        end
        @out.puts "Posted sensitive-file warning for: #{hits.join(' ')}"
      end

      private

      # Only the marker comment authored by the token user is ours to patch or
      # delete; a participant can post the hidden marker first to hijack it.
      def owned?(comment)
        comment["body"].to_s.include?(MARKER) && comment.dig("user", "login") == @token_user
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  client = Ci::Gh.new
  Ci::SensitiveFileWarning::Runner.new(
    client: client,
    repo: ENV.fetch("REPO"),
    number: ENV.fetch("PR"),
    token_user: client.login
  ).run
end
