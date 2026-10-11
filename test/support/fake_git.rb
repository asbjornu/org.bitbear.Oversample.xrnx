# frozen_string_literal: true

require_relative "../../scripts/lib/ci"

module Ci
  # Stand-in for Ci::Git. Facts are configured per test; calls are recorded.
  class FakeGit
    Status = Struct.new(:ok) { def success? = ok }

    attr_reader :events

    def initialize(merge_base: "basesha", rev_parse: {}, ancestors: {}, resolve: {},
                   logs: {}, ls_remote: nil, ls_remote_fail: false, rebase_ok: true)
      @merge_base = merge_base
      @rev_parse = rev_parse
      @ancestors = ancestors
      @resolve = resolve
      @logs = logs
      @ls_remote = ls_remote
      @ls_remote_fail = ls_remote_fail
      @rebase_ok = rebase_ok
      @events = []
    end

    def config(key, value) = @events << [:config, key, value]

    def merge_base(a, b)
      @events << [:merge_base, a, b]
      @merge_base
    end

    def rev_parse(ref)
      @events << [:rev_parse, ref]
      @rev_parse.fetch(ref, "sha-#{ref}")
    end

    def ancestor?(ancestor, descendant)
      @events << [:ancestor?, ancestor, descendant]
      @ancestors.fetch([ancestor, descendant], true)
    end

    def resolve(ref)
      @events << [:resolve, ref]
      @resolve[ref]
    end

    def log(format, ref)
      @events << [:log, format, ref]
      @logs.fetch([format, ref]) { raise Ci::Git::Error, "no log for #{format} #{ref}" }
    end

    def ls_remote(remote, ref)
      @events << [:ls_remote, remote, ref]
      raise Ci::Git::Error, "ls-remote failed" if @ls_remote_fail

      @ls_remote
    end

    def push(*args)
      @events << [:push, *args]
    end

    def run(*args, input: nil, env: {})
      @events << [:run, *args]
      ["", "", Status.new(true)]
    end

    def rebase(args, env: {})
      @events << [:rebase, args, env]
      ["", "", Status.new(@rebase_ok)]
    end
  end
end
