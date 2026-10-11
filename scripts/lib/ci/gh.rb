# frozen_string_literal: true

require "json"
require "open3"

module Ci
  # Thin wrapper over the gh CLI. Every network call goes through here, so
  # tests inject a fake and assert on the calls. It returns parsed JSON instead
  # of piping through jq, which removes the sed/awk/jq parsing that the shell
  # workflows relied on.
  class Gh
    class Error < StandardError; end

    def initialize(bin: "gh", token: nil)
      @bin = bin
      @token = token
    end

    # Raw stdout of `gh api <args>`. An explicit token overrides the default.
    def api(*args, input: nil, token: nil, allow_failure: false)
      out, err, status = capture("api", *args, input: input, token: token)
      return out if status.success?
      raise Error, "gh api #{args.join(' ')} failed: #{err.strip}" unless allow_failure

      err
    end

    # Parsed JSON object for a single endpoint.
    def get(path, token: nil)
      JSON.parse(api(path, token: token))
    end

    # Parsed JSON array across all pages.
    def get_all(path, token: nil)
      pages = JSON.parse(api("--paginate", "--slurp", path, token: token))
      pages.flat_map { |p| p.is_a?(Array) ? p : [p] }
    end

    def post(path, body, token: nil, allow_failure: false)
      request("POST", path, body, token: token, allow_failure: allow_failure)
    end

    def patch(path, body, token: nil, allow_failure: false)
      request("PATCH", path, body, token: token, allow_failure: allow_failure)
    end

    def delete(path, token: nil, allow_failure: false)
      api("-X", "DELETE", path, token: token, allow_failure: allow_failure)
    end

    # Run `gh <args>` for non-api subcommands (e.g. `gh aw run`).
    def run(*args, token: nil, allow_failure: false)
      out, err, status = capture(*args, token: token)
      return out if status.success?
      raise Error, "gh #{args.join(' ')} failed: #{err.strip}" unless allow_failure

      err
    end

    def login(token: nil)
      api("user", "--jq", ".login", token: token).strip
    end

    private

    def request(method, path, body, token:, allow_failure:)
      api("-X", method, path, "--input", "-",
          input: JSON.generate(body), token: token, allow_failure: allow_failure)
    end

    def capture(*args, input: nil, token: nil)
      env = {}
      effective = token || @token
      env["GH_TOKEN"] = effective if effective
      Open3.capture3(env, @bin, *args, stdin_data: input || "")
    end
  end
end
