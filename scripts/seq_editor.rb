#!/usr/bin/env ruby
# frozen_string_literal: true
#
# GIT_SEQUENCE_EDITOR for pr_fix_squash.rb. Reads the rebase todo path from
# ARGV[0], folds the fixer's fixup! commits into their targets, and writes it
# back. Replaces the 68-line bash heredoc in pr-fix-squash.yml.

require_relative "lib/ci"

module Ci
  module SeqEditor
    module_function

    def run_file(path, git = Git.new)
      lines = File.readlines(path, chomp: true)
      rewritten = rewrite(
        lines,
        resolve: ->(token) { git.resolve(token) },
        subject: ->(sha) { safe_log(git, "%s", sha) },
        author: ->(sha) { safe_log(git, "%an", sha) },
        body: ->(sha) { safe_log(git, "%B", sha) }
      )
      File.write(path, rewritten.map { |line| "#{line}\n" }.join)
    rescue UnmatchedFixup => e
      warn("aborting rebase: #{e.message}")
      exit 1
    end

    def safe_log(git, format, sha)
      git.log(format, sha)
    rescue Ci::Git::Error
      nil
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Ci::SeqEditor.run_file(ARGV.fetch(0))
end
