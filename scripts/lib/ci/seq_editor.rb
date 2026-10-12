# frozen_string_literal: true

module Ci
  # Rewrites a rebase todo so this repository's fixer fixup! commits sit directly
  # after their target, exactly like `--autosquash`. I/O-free: git facts are
  # passed in as callables, so the reordering logic is unit-testable. The
  # executable in scripts/seq_editor.rb wires the real git client.
  module SeqEditor
    # Raised when a fixer-authored fixup! has no in-range target. Leaving it as
    # a normal pick would publish a history that still contains the fixup, so
    # the next synchronize would try to fold it again.
    class UnmatchedFixup < StandardError; end

    module_function

    def rewrite(lines, resolve:, subject:, author:, body:)
      n = lines.length
      cmd = Array.new(n)
      sha = Array.new(n)
      subj = Array.new(n)

      lines.each_with_index do |line, i|
        first, rest = split(line)
        cmd[i] = first
        rest = strip_option(rest)
        token = rest.split(" ", 2).first.to_s
        resolved = resolve.call(token).to_s
        sha[i] = resolved.empty? ? token : resolved
        text = subject.call(sha[i])
        subj[i] = text.nil? || text.empty? ? rest_after_space(rest) : text
      end

      moved = {}
      move_to = Hash.new { |h, k| h[k] = [] }
      unmatched = []
      lines.each_index do |i|
        next unless subj[i].to_s.start_with?("fixup! ")
        next unless author.call(sha[i]).to_s == Ci::FIXER_BOT

        found = target_index(body.call(sha[i]), cmd, sha)
        if found.nil?
          target = subj[i].sub(/\Afixup! /, "")
          j = i - 1
          while j >= 0
            if cmd[j] == "pick" && subj[j] == target
              found = j
              break
            end
            j -= 1
          end
        end
        if found.nil?
          unmatched << subj[i]
          next
        end

        moved[i] = true
        move_to[found] << sha[i]
      end
      unless unmatched.empty?
        raise UnmatchedFixup, "no in-range target for fixer fixup(s): #{unmatched.join(', ')}"
      end

      lines.each_index.with_object([]) do |i, out|
        next if moved[i]

        out << lines[i]
        move_to[i].each { |s| out << "fixup #{s}" }
      end
    end

    # The last `aw-fixup-target=<sha>` line in the commit body, or nil.
    def target_sha(commit_body)
      commit_body.to_s.scan(/^aw-fixup-target=([0-9a-f]{7,40})[ \t]*$/).last&.first
    end

    def target_index(commit_body, cmd, sha)
      target = target_sha(commit_body)
      return nil if target.nil?

      sha.each_index { |k| return k if sha[k] == target && cmd[k] == "pick" }
      nil
    end

    def split(line)
      idx = line.index(" ")
      return [line, line] if idx.nil?

      [line[0...idx], line[(idx + 1)..]]
    end

    def strip_option(rest)
      return rest unless rest.start_with?("-C ", "-c ")

      rest.split(" ", 2)[1].to_s
    end

    def rest_after_space(rest)
      rest.sub(/\A[^ ]* /, "")
    end
  end
end
