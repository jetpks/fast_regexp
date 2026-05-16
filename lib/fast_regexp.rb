# frozen_string_literal: true

require_relative "fast_regexp/version"
require_relative "fast_regexp/fast_regexp"

# Ruby-side conveniences on top of the Rust extension. The native class only
# exposes raw primitives (`_native_new`, `_native_match`, `_native_sub`,
# `_native_gsub`); everything user-facing lives here so the API can grow
# without touching FFI.
module Fast
  class Regexp
    RUBY_FLAG_MAP = {
      ::Regexp::IGNORECASE => "i",
      ::Regexp::EXTENDED => "x",
      ::Regexp::MULTILINE => "s" # Ruby's /m = dotall; in rust/regex that is (?s).
    }.freeze

    class << self
      # Accept either a pattern string or an existing `::Regexp`. When given a
      # Regexp the flags (`/i`, `/x`, `/m`) are translated into a leading
      # inline group so the rust/regex engine sees them. Unsupported features
      # (lookaround, backrefs) still raise from the engine with a clear
      # message.
      def new(pattern, **opts)
        pattern = translate_regexp(pattern) if pattern.is_a?(::Regexp)
        _native_new(pattern, **opts)
      end

      private

      def translate_regexp(regexp)
        flags = RUBY_FLAG_MAP.each_with_object(+"") do |(bit, char), acc|
          acc << char if (regexp.options & bit) != 0
        end
        flags.empty? ? regexp.source : "(?#{flags})#{regexp.source}"
      end
    end

    # Returns a `Fast::Regexp::MatchData` on hit, `nil` on miss — matching
    # Ruby's `Regexp#match` shape so the old `[]`-truthy-but-empty trap is
    # gone.
    def match(haystack)
      _native_match(coerce_string(haystack))
    end

    # Case-equality. Enables `case/when` and RSpec's
    # `expect(str).to match(re)`.
    def ===(other)
      return false unless other.respond_to?(:to_str)
      match?(other.to_str)
    end

    # Returns the byte offset of the first match, or nil. Matches the
    # semantics of `Regexp#=~` except positions are in **bytes** (rust/regex
    # is byte-based).
    def =~(other)
      return nil unless other.respond_to?(:to_str)
      m = match(other.to_str)
      m && m.byte_begin(0)
    end

    # `sub(haystack, replacement)` or `sub(haystack) { |m| ... }`.
    #
    # The string form uses rust/regex's native replacement template: `$1`,
    # `${name}`, `$$` for a literal `$`. To pass a replacement string that
    # contains `$` literally, pass `literal: true`.
    def sub(haystack, replacement = nil, literal: false, &block)
      haystack = coerce_string(haystack)
      if block
        raise ArgumentError, "wrong number of arguments (given 2, expected 1 with block)" if replacement
        m = match(haystack)
        return haystack.dup unless m
        "#{m.pre_match}#{block.call(m)}#{m.post_match}"
      else
        raise ArgumentError, "wrong number of arguments (given 1, expected 2)" if replacement.nil?
        _native_sub(haystack, coerce_string(replacement), literal)
      end
    end

    # `gsub(haystack, replacement)` or `gsub(haystack) { |m| ... }`. See
    # `#sub` for the template syntax.
    def gsub(haystack, replacement = nil, literal: false, &block)
      haystack = coerce_string(haystack)
      if block
        raise ArgumentError, "wrong number of arguments (given 2, expected 1 with block)" if replacement
        gsub_with_block(haystack, &block)
      else
        raise ArgumentError, "wrong number of arguments (given 1, expected 2)" if replacement.nil?
        _native_gsub(haystack, coerce_string(replacement), literal)
      end
    end

    def inspect
      "#<Fast::Regexp #{pattern.inspect}>"
    end

    alias_method :to_s, :pattern

    private

    def gsub_with_block(haystack)
      matches = scan_matches(haystack)
      return haystack.dup if matches.empty?

      out = String.new(encoding: Encoding::UTF_8)
      cursor = 0
      matches.each do |m|
        bs, be = m.byteoffset(0)
        out << haystack.byteslice(cursor, bs - cursor) if bs > cursor
        out << yield(m).to_s
        cursor = be
      end
      out << haystack.byteslice(cursor, haystack.bytesize - cursor) if cursor < haystack.bytesize
      out
    end

    def coerce_string(value)
      return value if value.is_a?(String)
      return value.to_str if value.respond_to?(:to_str)
      raise TypeError, "no implicit conversion of #{value.class} into String"
    end

    class MatchData
      include Enumerable

      def each(&block)
        to_a.each(&block)
      end

      def values_at(*indices)
        indices.map { |i| self[i] }
      end

      def ==(other)
        other.is_a?(MatchData) && to_a == other.to_a && string == other.string
      end
      alias_method :eql?, :==

      def hash
        [to_a, string].hash
      end
    end
  end
end
