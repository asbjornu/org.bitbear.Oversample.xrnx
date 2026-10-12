# frozen_string_literal: true

require_relative "../../scripts/lib/ci"

module Ci
  # Records calls and answers from registered stubs. Matchers are a String
  # (exact path), a Regexp (against the path), or a Proc (all args).
  #
  #   gh = FakeGh.new(login: "maintainer")
  #   gh.on(:get, %r{/pulls/1$}) { { "state" => "open" } }
  class FakeGh
    attr_reader :events

    def initialize(login: "maintainer")
      @login = login
      @handlers = Hash.new { |h, k| h[k] = [] }
      @events = []
    end

    def on(method, matcher, value = nil, &block)
      @handlers[method] << [matcher, value, block]
      self
    end

    def events_for(method)
      @events.select { |(m, _)| m == method }.map { |(_, args)| args }
    end

    def login(token: nil)
      @login
    end

    def get(path, token: nil)
      call(:get, [path])
    end

    def get_all(path, token: nil)
      call(:get_all, [path])
    end

    def post(path, body, token: nil, allow_failure: false)
      call(:post, [path, body])
    end

    def patch(path, body, token: nil, allow_failure: false)
      call(:patch, [path, body])
    end

    def delete(path, token: nil, allow_failure: false)
      call(:delete, [path])
    end

    def api(*args, input: nil, token: nil, allow_failure: false)
      call(:api, args)
    end

    def run(*args, token: nil, allow_failure: false)
      call(:run, args)
    end

    private

    def call(method, args)
      @events << [method, args]
      handler = @handlers[method].reverse.find { |(m, _v, _b)| matches?(m, args) }
      raise Ci::Gh::Error, "FakeGh: no stub for #{method} #{args.inspect}" if handler.nil?

      value = handler[1]
      block = handler[2]
      block ? block.call(*args) : value
    end

    def matches?(matcher, args)
      path = args.first.to_s
      case matcher
      when String then path == matcher
      when Regexp then matcher.match?(path)
      when Proc then matcher.call(*args)
      else false
      end
    end
  end
end
