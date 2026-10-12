# frozen_string_literal: true

require_relative "ci/gh"
require_relative "ci/git"
require_relative "ci/markers"
require_relative "ci/seq_editor"

# Shared building blocks for the CI scripts under scripts/. Each script is a
# thin wrapper that wires real Gh/Git clients into a Runner; tests inject fakes.
module Ci
  COPILOT_LOGINS = [
    "copilot-pull-request-reviewer[bot]",
    "copilot-pull-request-reviewer",
    "Copilot",
    "copilot",
  ].freeze

  FIXER_BOT = "github-actions[bot]"

  def self.copilot_review?(review)
    COPILOT_LOGINS.include?(review.dig("user", "login"))
  end
end
