---
type: how-to
---

# Handle patterns rust/regex can't compile

**Goal:** detect, inspect, and (if you need to) react to patterns that
trigger the stdlib fallback.

## What triggers fallback

rust/regex rejects, and `Fast::Regexp` falls back to `::Regexp`, when a
pattern uses:

- Lookaround: `(?=...)`, `(?!...)`, `(?<=...)`, `(?<!...)`
- Backreferences: `\1`, `\k<name>`
- Possessive quantifiers: `*+`, `++`, `?+`, `{n,m}+`
- Other features outside [rust/regex syntax](https://docs.rs/regex/latest/regex/index.html#syntax)

## Check which engine a pattern uses

```ruby
re = Fast::Regexp.new('foo(?=bar)')
re.fast?     # => false
re.stdlib?   # => true
```

The same predicates exist on `MatchData`:

```ruby
m = re.match("foobar")
m.native?    # => false
m.stdlib?    # => true
```

## Reach the underlying engine object

```ruby
re = Fast::Regexp.new('\w+')
re.native    # => #<Fast::Regexp::Native ...>   (rust-backed)
re.stdlib    # => nil

re = Fast::Regexp.new('(?=foo)foo')
re.native    # => nil
re.stdlib    # => /(?=foo)foo/
```

Use these when you need a feature only one backend exposes — e.g. passing
the stdlib `::Regexp` to a library that only accepts core Ruby regexes.

## Force a specific backend

There is no "force fast" or "force stdlib" knob. The intent is that callers
don't think about it. If you need to assert that a hot-path pattern is on
the fast engine, check `#fast?` in a test:

```ruby
RSpec.describe "regex hot path" do
  it "stays on rust/regex" do
    expect(MyClass::HOT_PATH_PATTERN).to be_fast
  end
end
```

## Detect unsupported patterns at boot

If you'd rather know up-front:

```ruby
patterns = load_patterns_from_config
fallbacks = patterns.reject { |p| Fast::Regexp.new(p).fast? }
warn "patterns on stdlib fallback: #{fallbacks.inspect}" if fallbacks.any?
```

This is purely informational — fallback patterns still work correctly.

## Caveats

- A pattern that's malformed in *both* engines (e.g. unbalanced parens like
  `'('`) raises `ArgumentError`, surfaced from the rust/regex compile attempt
  with its (more detailed) error message.
- The fallback path uses Ruby's regex syntax, not rust/regex's. If your
  pattern relies on rust-specific syntax *and* a feature rust/regex doesn't
  support, you'll get a compile error from `::Regexp` instead. Rewrite for
  one engine or the other.
