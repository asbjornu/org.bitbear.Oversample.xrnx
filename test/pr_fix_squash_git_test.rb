#!/usr/bin/env ruby
# frozen_string_literal: true
#
# End-to-end test for pr_fix_squash.rb against a real git repository: real
# commits, a real `git rebase -i` driven by scripts/seq_editor.rb, and a real
# force-push to a local bare remote. The gh client is faked, so no network.
#
# This complements the FakeGit unit tests: it proves the port produces the same
# folded history and push the shell version did, not just that decisions are
# wired correctly.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "stringio"

require_relative "../scripts/pr_fix_squash"
require_relative "support/fake_gh"

module Ci
  class PrFixSquashGitTest < Minitest::Test
    SEQ_EDITOR = File.expand_path("../scripts/seq_editor.rb", __dir__)

    def setup
      skip "git not available" unless git_available?

      @tmp = Dir.mktmpdir("squash-git")
      @remote = File.join(@tmp, "remote.git")
      @repo = File.join(@tmp, "repo")
      build_repositories
    end

    def teardown
      FileUtils.remove_entry(@tmp) if @tmp && Dir.exist?(@tmp)
    end

    def test_folds_fixup_and_force_pushes_to_remote
      gh = FakeGh.new(login: "maintainer")
      gh.on(:get_all, %r{/issues/1/comments}) do
        [{ "body" => Markers.state_marker(review: "77", pr: "1", round: "1",
                                          run: "111", head: @base_sha),
           "id" => 900, "created_at" => "2024-01-01T00:00:00Z",
           "user" => { "login" => "maintainer" } }]
      end
      gh.on(:get, %r{/compare/}) do
        { "total_commits" => 2,
          "commits" => [
            { "author" => { "login" => Ci::FIXER_BOT }, "commit" => { "message" => "Add feature" } },
            { "author" => { "login" => Ci::FIXER_BOT }, "commit" => { "message" => "fixup! Add feature" } }
          ] }
      end
      gh.on(:post, %r{/issues/1/comments}) { '{"id":4242}' }

      out = StringIO.new
      err = StringIO.new
      result = PrFixSquash::Runner.new(
        git: Git.new(chdir: @repo), client: gh, repo: "o/r", number: 1,
        base_ref: "main", head_ref: "fix/pr", token_user: "maintainer",
        seq_editor: "ruby #{SEQ_EDITOR}", out: out, err: err
      ).run

      assert_equal 0, result, "runner failed: #{out.string} #{err.string}"

      subjects = git("log", "--format=%s").split("\n")
      assert_equal ["Add feature", "Base commit"], subjects
      refute_includes subjects.join("\n"), "fixup!"

      local = git("rev-parse", "HEAD").strip
      remote = git("ls-remote", "origin", "refs/heads/fix/pr").split("\t").first
      assert_equal local, remote, "remote branch was not force-pushed to the folded head"

      anchors = gh.events_for(:post).select do |(_path, body)|
        body["body"].include?("aw-pr-fix-squash-anchor")
      end
      refute_empty anchors, "a squash anchor should be recorded"
      assert_includes anchors.first[1]["body"], "head=#{local}"
    end

    private

    def git_available?
      system("git --version > /dev/null 2>&1")
    end

    def git(*args)
      out, err, status = Open3.capture3("git", *args, chdir: @repo)
      raise "git #{args.join(' ')} failed: #{err}" unless status.success?

      out
    end

    def build_repositories
      FileUtils.mkdir_p(@remote)
      run_git(@remote, "init", "--bare", "-b", "main")
      FileUtils.mkdir_p(@repo)
      run_git(@repo, "init", "-b", "main")
      configure_identity(@repo)

      File.write(File.join(@repo, "file.txt"), "base\n")
      git("add", "file.txt")
      git("commit", "-m", "Base commit")
      @base_sha = git("rev-parse", "HEAD").strip
      git("remote", "add", "origin", @remote)
      git("push", "-u", "origin", "main")

      git("checkout", "-b", "fix/pr")
      append_and_commit("feature", "Add feature")
      feature_sha = git("rev-parse", "HEAD").strip
      append_and_commit("more", "fixup! Add feature", "aw-fixup-target=#{feature_sha}")
      git("push", "-u", "origin", "fix/pr")
    end

    def configure_identity(dir)
      run_git(dir, "config", "user.name", Ci::FIXER_BOT)
      run_git(dir, "config", "user.email", "#{Ci::FIXER_BOT}@users.noreply.github.com")
    end

    def append_and_commit(text, subject, body = nil)
      File.open(File.join(@repo, "file.txt"), "a") { |f| f.puts(text) }
      git("add", "file.txt")
      args = ["commit", "-m", subject]
      args += ["-m", body] if body
      git(*args)
    end

    def run_git(dir, *args)
      _out, err, status = Open3.capture3("git", *args, chdir: dir)
      raise "git #{args.join(' ')} failed: #{err}" unless status.success?
    end
  end
end
