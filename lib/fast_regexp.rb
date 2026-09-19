# frozen_string_literal: true

require_relative "fast_regexp/version"

module Fast
  # Façade over rust/regex with a transparent fallback to stdlib `::Regexp`.
  #
  # `Fast::Regexp.new(pattern)` first tries to compile with rust/regex (fast,
  # byte-based). If the pattern uses features rust/regex does not support
  # (lookaround, backreferences, possessive quantifiers, etc.) we fall back
  # to `::Regexp` so consumers don't have to juggle two libraries.
  class Regexp
    NATIVE_EXTENSIONS = %w[.bundle .so .rb].freeze

    # Precompiled native gems ship per-ABI subdirs (`fast_regexp/4.0/...`),
    # the source-gem `rake compile` build lands flat (`fast_regexp/...`).
    # Pick whichever exists for the current Ruby ABI, with the per-ABI path
    # winning when both are present.
    def self.locate_native(base, ruby_version: RUBY_VERSION)
      abi = ruby_version[/\d+\.\d+/]
      candidates = [File.join(base, abi, "fast_regexp"), File.join(base, "fast_regexp")]
      candidates.find { |stem| NATIVE_EXTENSIONS.any? { |ext| File.exist?(stem + ext) } }
    end

    # One match, whichever engine produced it. On the fast path the match
    # *is* a `Fast::Regexp::Native::MatchData`, a subclass of this one
    # defined by the extension (so it must exist before the extension
    # loads); on the stdlib path it's an instance of this class wrapping the
    # `::MatchData`. Same public surface either way.
    class MatchData
      include Enumerable

      attr_reader :backend, :string

      def initialize(backend, haystack)
        @backend = backend
        @string = haystack
      end

      def native? = false
      def stdlib? = true

      def native = nil
      def stdlib = @backend

      def [](key) = @backend[key]
      def to_a = @backend.to_a
      def captures = @backend.captures
      def named_captures = @backend.named_captures
      def names = @backend.names
      def size = @backend.size
      alias_method :length, :size
      def pre_match = @backend.pre_match
      def post_match = @backend.post_match
      def to_s = @backend.to_s
      alias_method :match, :to_s

      # Byte-based offsets. `::MatchData#byteoffset` exists since Ruby 3.2;
      # its `byte_begin`/`byte_end` don't (3.4 added `bytebegin`/`byteend`),
      # so those two derive from `byteoffset` here.
      def byteoffset(key) = @backend.byteoffset(key)
      def byte_begin(key) = byteoffset(key)[0]
      def byte_end(key) = byteoffset(key)[1]

      def each(&block) = to_a.each(&block)
      def values_at(*indices) = indices.map { |i| self[i] }

      def ==(other)
        other.is_a?(MatchData) && to_a == other.to_a && string == other.string
      end
      alias_method :eql?, :==

      def hash = [to_a, string].hash

      def inspect = "#<Fast::Regexp::MatchData #{to_s.inspect}>"
    end
  end
end

native = Fast::Regexp.locate_native(File.expand_path("fast_regexp", __dir__))
raise LoadError, "could not locate fast_regexp native extension" unless native
require native

module Fast
  class Regexp
    class Native
      class MatchData
        def native? = true
        def stdlib? = false

        def native = self
        def stdlib = nil
        def backend = self
      end
    end

    RUBY_FLAG_MAP = {
      ::Regexp::IGNORECASE => "i",
      ::Regexp::EXTENDED => "x",
      ::Regexp::MULTILINE => "s" # Ruby's /m = dotall; in rust/regex that is (?s).
    }.freeze

    class << self
      # Compile a pattern. Accepts a String or a `::Regexp` (flags are
      # translated into a leading `(?...)` group so rust/regex sees them).
      # Falls back to `::Regexp` if rust/regex rejects the pattern.
      def new(pattern, **opts)
        translated = pattern.is_a?(::Regexp) ? translate_regexp(pattern) : pattern
        allocate.tap { |re| re.send(:initialize, translated, original: pattern, **opts) }
      end

      # Bulk-compile a set of patterns. Two call shapes:
      #
      #   Fast::Regexp.create_many(word: '\w+', num: '\d+')
      #   # => { word: #<Fast::Regexp ...>, num: #<Fast::Regexp ...> }
      #
      #   Fast::Regexp.create_many('\w+', '\d+')
      #   # => [#<Fast::Regexp ...>, #<Fast::Regexp ...>]
      #
      # Mixing the two raises ArgumentError — pick one shape per call.
      def create_many(*patterns, **named)
        if !patterns.empty? && !named.empty?
          raise ArgumentError, "create_many accepts positional patterns OR keyword patterns, not both"
        end
        return named.transform_values { |pat| new(pat) } if patterns.empty?
        patterns.map { |pat| new(pat) }
      end

      private

      def translate_regexp(regexp)
        flags = RUBY_FLAG_MAP.each_with_object(+"") do |(bit, char), acc|
          acc << char if (regexp.options & bit) != 0
        end
        flags.empty? ? regexp.source : "(?#{flags})#{regexp.source}"
      end
    end

    attr_reader :pattern, :backend

    BACKENDS = %i[auto fast stdlib].freeze

    # Internal — use `Fast::Regexp.new`. `original` is the unmodified input
    # (String or ::Regexp) so we can build an accurate stdlib fallback.
    # `backend:` forces a specific engine: `:auto` (default) tries rust/regex
    # and falls back to stdlib, `:fast` raises if rust/regex rejects the
    # pattern, `:stdlib` skips rust/regex entirely.
    def initialize(pattern, original: pattern, backend: :auto, **opts)
      raise ArgumentError, "backend must be one of #{BACKENDS.inspect}" unless BACKENDS.include?(backend)
      @pattern = pattern
      @backend = compile_backend(pattern, original, backend, opts)
    end

    def fast? = @backend.is_a?(Native)
    def stdlib? = !fast?

    # Escape hatches for callers that need the underlying object directly.
    def native = fast? ? @backend : nil
    def stdlib = stdlib? ? @backend : nil

    def match(haystack)
      haystack = coerce_string(haystack)
      return @backend._native_match(haystack) if fast?
      m = @backend.match(haystack)
      m && MatchData.new(m, haystack)
    end

    def match?(haystack)
      @backend.match?(coerce_string(haystack))
    end

    def ===(other)
      return false unless other.respond_to?(:to_str)
      match?(other.to_str)
    end

    # Byte offset of the first match (rust/regex is byte-based; stdlib path
    # also returns bytes here for API consistency).
    def =~(other)
      return nil unless other.respond_to?(:to_str)
      haystack = other.to_str
      return @backend._native_find(haystack) if fast?
      m = @backend.match(haystack)
      m && m.byteoffset(0)[0]
    end

    def scan(haystack)
      @backend.scan(coerce_string(haystack))
    end

    def scan_matches(haystack)
      haystack = coerce_string(haystack)
      return @backend.scan_matches(haystack) if fast?
      results = []
      haystack.scan(@backend) { results << MatchData.new(::Regexp.last_match, haystack) }
      results
    end

    def sub(haystack, replacement = nil, literal: false, &block)
      haystack = coerce_string(haystack)
      if block_given?
        raise ArgumentError, "wrong number of arguments (given 2, expected 1 with block)" if replacement
        fast? ? @backend._native_sub_block(haystack, &block) : stdlib_sub_with_block(haystack, &block)
      else
        raise ArgumentError, "wrong number of arguments (given 1, expected 2)" if replacement.nil?
        replacement = coerce_string(replacement)
        if fast?
          @backend._native_sub(haystack, replacement, literal)
        else
          haystack.sub(@backend, stdlib_replacement(replacement, literal))
        end
      end
    end

    def gsub(haystack, replacement = nil, literal: false, &block)
      haystack = coerce_string(haystack)
      if block_given?
        raise ArgumentError, "wrong number of arguments (given 2, expected 1 with block)" if replacement
        fast? ? @backend._native_gsub_block(haystack, &block) : stdlib_gsub_with_block(haystack, &block)
      else
        raise ArgumentError, "wrong number of arguments (given 1, expected 2)" if replacement.nil?
        replacement = coerce_string(replacement)
        if fast?
          @backend._native_gsub(haystack, replacement, literal)
        else
          haystack.gsub(@backend, stdlib_replacement(replacement, literal))
        end
      end
    end

    # On the fast path this comes from rust/regex directly. On the stdlib
    # fallback we walk the source counting capturing groups while honoring
    # escapes, character classes, and non-capturing / lookaround prefixes.
    def captures_count
      return @backend.captures_count if fast?
      count_stdlib_captures(@backend.source)
    end

    def names
      @backend.names
    end

    def inspect = "#<Fast::Regexp #{@pattern.inspect}#{stdlib? ? " (stdlib)" : ""}>"
    alias_method :to_s, :pattern

    private

    def count_stdlib_captures(source)
      count = 0
      i = 0
      len = source.length
      while i < len
        c = source[i]
        if c == "\\"
          i += 2
        elsif c == "["
          i += 1
          i += 1 while i < len && source[i] != "]"
          i += 1
        elsif c == "("
          # Capturing unless followed by (?:, (?=, (?!, (?#, (?<=, (?<!.
          prefix = source[i + 1, 4] || ""
          if prefix.start_with?("?:") || prefix.start_with?("?=") || prefix.start_with?("?!") ||
              prefix.start_with?("?#") || prefix.start_with?("?<=") || prefix.start_with?("?<!")
            i += 1
          else
            count += 1
            i += 1
          end
        else
          i += 1
        end
      end
      count
    end

    def compile_backend(pattern, original, backend, opts)
      return compile_stdlib(pattern, original) if backend == :stdlib
      Native._native_new(pattern, **opts)
    rescue ArgumentError => e
      raise if backend == :fast
      compile_stdlib(pattern, original, fallback_from: e)
    end

    def compile_stdlib(pattern, original, fallback_from: nil)
      return original if original.is_a?(::Regexp)
      ::Regexp.new(pattern)
    rescue ::RegexpError => e
      # Pattern is malformed in both engines (auto path) — surface the
      # original rust/regex error since it's typically more detailed.
      # Otherwise propagate the stdlib error as-is.
      raise(fallback_from ? ArgumentError.new(fallback_from.message) : e)
    end

    # Maps positional capture indices to names for the stdlib backend so we
    # can translate `$N` to `\k<name>` (Ruby's gsub ignores `\N` for named
    # groups). Only invoked from the stdlib path.
    def stdlib_name_by_index
      @stdlib_name_by_index ||= @backend.named_captures.flat_map { |n, idxs| idxs.map { |i| [i, n] } }.to_h
    end

    # Translate rust/regex replacement syntax ($N, ${name}, $$) into Ruby
    # syntax (\N, \k<name>, $) for the stdlib fallback path.
    def stdlib_replacement(template, literal)
      return template.gsub('\\', '\\\\\\\\') if literal

      template.gsub(/\$(\$|\d+|\{[^}]+\})/) do
        token = ::Regexp.last_match(1)
        case token
        when "$" then "$"
        when /\A\d+\z/
          name = stdlib_name_by_index[token.to_i]
          name ? "\\k<#{name}>" : "\\#{token}"
        else "\\k<#{token[1..-2]}>"
        end
      end
    end

    # Stdlib path: String#sub/#gsub already do single-pass iterate-and-replace
    # and set $~ inside the block, so wrap the current ::MatchData and yield.
    def stdlib_sub_with_block(haystack)
      haystack.sub(@backend) { yield(MatchData.new(::Regexp.last_match, haystack)).to_s }
    end

    def stdlib_gsub_with_block(haystack)
      haystack.gsub(@backend) { yield(MatchData.new(::Regexp.last_match, haystack)).to_s }
    end

    def coerce_string(value)
      return value if value.is_a?(String)
      return value.to_str if value.respond_to?(:to_str)
      raise TypeError, "no implicit conversion of #{value.class} into String"
    end
  end
end
