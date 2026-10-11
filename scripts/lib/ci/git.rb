# frozen_string_literal: true

require "open3"

module Ci
  # Thin wrapper over the git CLI. The squash workflow's git plumbing lives here
  # so its decision logic can be tested with a fake.
  class Git
    class Error < StandardError; end

    def initialize(bin: "git", chdir: Dir.pwd)
      @bin = bin
      @chdir = chdir
    end

    # Run git with the given args. Returns [stdout, stderr, status]; callers use
    # `ok?` to branch. `env` is merged into the child environment, which the
    # rebase uses for GIT_SEQUENCE_EDITOR.
    def run(*args, input: nil, env: {})
      Open3.capture3(env, @bin, *args, chdir: @chdir, stdin_data: input || "")
    end

    def capture(*args, input: nil, env: {}, allow_failure: false)
      out, err, status = run(*args, input: input, env: env)
      return out if status.success?
      raise Error, "git #{args.join(' ')} failed: #{err.strip}" unless allow_failure

      [out, err, status]
    end

    def merge_base(a, b)
      capture("merge-base", a, b).strip
    end

    def ancestor?(ancestor, descendant)
      _out, _err, status = run("merge-base", "--is-ancestor", ancestor, descendant)
      status.success?
    end

    def rev_parse(ref)
      capture("rev-parse", ref).strip
    end

    # Resolve a token to a commit sha, or nil if it does not name one.
    def resolve(ref)
      out, _err, status = run("rev-parse", "--verify", "-q", "#{ref}^{commit}")
      status.success? ? out.strip : nil
    end

    def log(format, ref)
      capture("log", "-1", "--format=#{format}", ref).chomp
    end

    def ls_remote(remote, ref)
      capture("ls-remote", remote, ref).split("\t").first
    end

    def push(*args)
      capture("push", *args)
    end

    def rebase(args, env: {})
      run("rebase", *args, env: env)
    end

    def config(key, value)
      run("config", key, value)
    end
  end
end
