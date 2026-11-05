# fast_regexp

[![Gem Version](https://badge.fury.io/rb/fast_regexp.svg)](https://badge.fury.io/rb/fast_regexp)
[![Test](https://github.com/jetpks/fast_regexp/workflows/CI/badge.svg)](https://github.com/jetpks/fast_regexp/actions)

Fast, drop-in regex for Ruby — backed by [rust/regex](https://docs.rs/regex/latest/regex/) with transparent fallback to the stdlib `::Regexp` engine for features rust/regex doesn't support (lookaround, backreferences, possessive quantifiers, etc.).

You get rust/regex's speed on the common path, and a single uniform API (`Fast::Regexp`, `Fast::Regexp::MatchData`) regardless of which engine actually ran underneath.

## Installation

Add as a dependency:

```ruby
# In your Gemfile
gem "fast_regexp"

# Or without Bundler
gem install fast_regexp
```

Precompiled native gems are published for **arm64-darwin**, **x86_64-linux**,
and **aarch64-linux** against Ruby **3.4** and **4.0** — no Rust
toolchain required on those platforms.

On any other platform/Ruby combo, Bundler/RubyGems falls back to the source
gem and compiles the extension at install time. That path needs
[Rust](https://www.rust-lang.org/) (install via [rustup](https://rustup.rs/)).

Include in your code:

```ruby
require "fast_regexp"
```

## Usage

Regular expressions should be pre-compiled before use:

```ruby
re = Fast::Regexp.new('p.t{2}ern*')
# => #<Fast::Regexp "p.t{2}ern*">
```

> [!TIP]
> Note the use of *single quotes* when passing the regular expression as
> a string to `rust/regex` so that the backslashes aren't interpreted as escapes.

You can also build from an existing Ruby `Regexp` — trailing flags (`/i`,
`/x`, `/m`) are translated to inline form for the rust engine:

```ruby
Fast::Regexp.new(/foo/i).pattern    # => "(?i)foo"
Fast::Regexp.new(/foo.bar/m).match?("foo\nbar")  # => true (Ruby's /m = dotall)
```

### Matching

`#match` returns a `Fast::Regexp::MatchData` on a hit and `nil` on no match —
matching Ruby's `Regexp#match` shape:

```ruby
m = Fast::Regexp.new('(\w+):(\d+)').match("ruby:123, rust:456")
m[0]              # => "ruby:123"   (whole match)
m[1]              # => "ruby"
m[2]              # => "123"
m.pre_match       # => ""
m.post_match      # => ", rust:456"
m.captures        # => ["ruby", "123"]
m.to_a            # => ["ruby:123", "ruby", "123"]
m.byteoffset(0)   # => [0, 8]

Fast::Regexp.new('\d+').match("abc")  # => nil
```

Named captures use rust/regex's `(?P<name>...)` syntax:

```ruby
m = Fast::Regexp.new('(?P<word>\w+):(?P<num>\d+)').match("ruby:123")
m[:word]            # => "ruby"
m["num"]            # => "123"
m.named_captures    # => { "word" => "ruby", "num" => "123" }
```

`#match?`, `#===`, and `#=~` are also available:

```ruby
re = Fast::Regexp.new('\d+')
re.match?("123")                          # => true
re === "abc 42"                           # => true (works in case/when)
re =~ "abc 42"                            # => 4 (byte offset of first match)
```

### Scanning

```ruby
Fast::Regexp.new('\w+:\d+').scan("ruby:123, rust:456")
# => ["ruby:123", "rust:456"]

Fast::Regexp.new('(\w+):(\d+)').scan("ruby:123, rust:456")
# => [["ruby", "123"], ["rust", "456"]]
```

Both `#scan` and `#scan_matches` run on either engine and return identical
results, including on patterns that fell back to stdlib `::Regexp`.

For per-match positions and pre/post-match access, use `#scan_matches`:

```ruby
Fast::Regexp.new('(\w+):(\d+)').scan_matches("ruby:123, rust:456").map { |m| m.byteoffset(0) }
# => [[0, 8], [10, 18]]
```

### Substitution

`#sub` and `#gsub` use rust/regex's native replacement template — `$1`,
`${name}`, and `$$` for a literal `$`:

```ruby
re = Fast::Regexp.new('(\w+):(\d+)')
re.sub("ruby:123 rust:456",  '$2-$1')   # => "123-ruby rust:456"
re.gsub("ruby:123 rust:456", '$2-$1')   # => "123-ruby 456-rust"
```

Block form receives a `MatchData`:

```ruby
Fast::Regexp.new('\d+').gsub("a1 b22 c333") { |m| "<#{m[0].size}>" }
# => "a<1> b<2> c<3>"
```

Pass `literal: true` to disable `$`-expansion entirely.

### Other

```ruby
Fast::Regexp.new('\w+:\d+').pattern         # => "\\w+:\\d+"
Fast::Regexp.new('(?P<n>\w+)').names        # => ["n"]
Fast::Regexp.new('(a)(b)').captures_count   # => 2
```

### Engine fallback

rust/regex doesn't support lookaround, backreferences, or possessive
quantifiers. Rather than make you manage two regex libraries, `Fast::Regexp`
silently falls back to stdlib `::Regexp` when it sees something rust/regex
can't compile. The public API (`#match`, `#sub`, `#gsub`, `#===`, `#=~`,
`MatchData`) is identical on both paths, so callers don't have to care which
engine ran — but you can inspect or reach the underlying object when you
need to:

```ruby
fast = Fast::Regexp.new('\w+')
fast.fast?       # => true
fast.native      # => #<Fast::Regexp::Native ...>  (rust-backed)

slow = Fast::Regexp.new('foo(?=bar)')   # lookahead — rust/regex rejects
slow.stdlib?     # => true
slow.stdlib      # => /foo(?=bar)/  (the real ::Regexp)
slow.match?("foobar")  # => true
```

`Fast::Regexp::MatchData` exposes the same `#native?` / `#stdlib?` / `#native`
/ `#stdlib` accessors. Replacement templates use rust/regex syntax (`$1`,
`${name}`, `$$`) on both paths; the stdlib fallback translates them for you.

You can force a specific engine via the `backend:` kwarg:

```ruby
Fast::Regexp.new('\w+', backend: :fast)     # rust/regex only; raises on unsupported
Fast::Regexp.new(pat,   backend: :stdlib)   # skip rust/regex; use ::Regexp directly
Fast::Regexp.new('\w+', backend: :auto)     # default — try rust, fall back on reject
```

> [!NOTE]
> The fast path is byte-based (rust/regex's `regex::bytes`), so `#=~` returns
> a *byte* offset. The stdlib fallback path returns the byte offset too, for
> API consistency.

> [!WARNING]
> `rust/regex` syntax differs from Ruby's built-in
> [`Regexp`](https://docs.ruby-lang.org/en/3.4/Regexp.html) — see the
> [rust/regex syntax page](https://docs.rs/regex/latest/regex/index.html#syntax).
> When fallback kicks in, your pattern is interpreted by stdlib `::Regexp`
> instead, so Ruby's syntax applies for that compile.

### Searching simultaneously

`Fast::Regexp::Set` represents a collection of
regular expressions that can be searched for simultaneously. Calling `Fast::Regexp::Set#match` will return an array containing the indices of all the patterns that matched.

```ruby
set = Fast::Regexp::Set.new(["abc", "def", "ghi", "xyz"])

set.match("abcdefghi") # => [0, 1, 2]
set.match("ghidefabc") # => [0, 1, 2]
```

> [!NOTE]
> Matches arrive in the order the constituent patterns were declared,
> not the order they appear in the haystack.

To check whether at least one pattern from the set matches the haystack:

```ruby
Fast::Regexp::Set.new(["abc", "def"]).match?("abc")
# => true

Fast::Regexp::Set.new(["abc", "def"]).match?("123")
# => false
```

Inspect original patterns:

```ruby
Fast::Regexp::Set.new(["abc", "def"]).patterns
# => ["abc", "def"]
```

## Encoding

`fast_regexp` expects UTF-8 haystacks — ASCII-8BIT strings work too, and match
results always come back tagged UTF-8. Matching runs over the raw bytes
(rust/regex's `regex::bytes`), so searching a haystack that contains invalid
UTF-8 doesn't raise, where stdlib raises `ArgumentError`:

```ruby
"abc\xFFdef" =~ /a(.)c/
# => ArgumentError: invalid byte sequence in UTF-8

Fast::Regexp.new('a(.)c').match("abc\xFFdef")
# => #<Fast::Regexp::MatchData "abc">
```

In the default Unicode-aware mode a `.` or character class won't match
*across* an invalid byte. To match bytes anywhere, disable Unicode
awareness — both `Fast::Regexp` and `Fast::Regexp::Set` accept `unicode:`
(default `true`):

```ruby
Fast::Regexp.new('c(.)d', unicode: false).match("abc\xFFdef").to_a
# => ["c\xFFd", "\xFF"]

Fast::Regexp.new('\w+').match('ю٤夏')[0]
# => "ю٤夏"

Fast::Regexp.new('\w+', unicode: false).match('ю٤夏')
# => nil

Fast::Regexp::Set.new(['\w', '\d', '\s']).match("ю٤\u2000")
# => [0, 1, 2]

Fast::Regexp::Set.new(['\w', '\d', '\s'], unicode: false).match("ю٤\u2000")
# => []
```

## Ractors

Patterns, sets, and match results support `Ractor.make_shareable` — it
returns the same object, now frozen. The native extension declares itself
Ractor-safe at load time, so there is nothing to enable:

```ruby
re = Ractor.make_shareable(Fast::Regexp.new('(?P<word>\w+)=(?P<num>\d+)'))

workers = Array.new(4) do
  Ractor.new(re) do |pattern|
    pattern.match("a=1 b=2")[:word]   # => "a"
  end
end
workers.map { |r| r.respond_to?(:value) ? r.value : r.take }
# => ["a", "a", "a", "a"]
```

Ruby 3.4 reads a Ractor's result with `#take`; Ruby 4.0 replaced it with
`#value`. The `respond_to?` read above runs on both — the same idiom the
spec suite uses.

What is guaranteed (each point pinned by
[`spec/fast_regexp/ractor_spec.rb`](spec/fast_regexp/ractor_spec.rb)):

- A shared pattern is fully usable in every worker: `match`, `match?`,
  `===`, `=~`, `scan`, `scan_matches`, and `sub`/`gsub` in template and
  block form all work, with the same results as on the main Ractor.
- Workers can `require "fast_regexp"` concurrently, including as the gem's
  first load, and can construct their own patterns, matches, and sets —
  the first construction of every native type works inside a non-main
  Ractor.
- Matches are frozen snapshots: the haystack is snapshotted at match time,
  so mutating it afterwards and then running GC with compaction leaves a
  shared match's data intact. `MatchData#string` returns that snapshot.
- Stdlib-fallback patterns are shareable too, and substitute correctly
  after being frozen or made shareable, without any warm-up call.

Recipes: [Use fast_regexp inside Ractors](docs/how-to/use-in-ractors.md).
Per-class details: the "Ractor safety" sections of
[`Fast::Regexp`](docs/reference/fast-regexp.md),
[`MatchData`](docs/reference/fast-regexp-matchdata.md), and
[`Set`](docs/reference/fast-regexp-set.md).

## Documentation

In-depth docs live under [`docs/`](docs/README.md), organized via the
[Diátaxis](https://diataxis.fr/) framework:

- **Tutorial:** [Getting started](docs/tutorials/getting-started.md)
- **How-to:** [Migrate from stdlib `::Regexp`](docs/how-to/migrate-from-stdlib-regexp.md), [Handle unsupported syntax](docs/how-to/handle-unsupported-syntax.md), [Use fast_regexp inside Ractors](docs/how-to/use-in-ractors.md)
- **Reference:** [`Fast::Regexp`](docs/reference/fast-regexp.md), [`MatchData`](docs/reference/fast-regexp-matchdata.md), [`Set`](docs/reference/fast-regexp-set.md)
- **Explainers:** [Engine fallback](docs/explainers/engine-fallback.md), [Benchmarks](docs/explainers/benchmarks.md)

## Performance

Measured with `bundle exec ruby benchmark/operations.rb` — one run on
2026-11-05, Apple M4 Max, `ruby 4.0.9`, fast_regexp 0.9.0 (the full table is
on the [benchmarks page](docs/explainers/benchmarks.md)):

- `match?` runs 8–9x stdlib `::Regexp`, on a hit and on a 200 KB miss;
  `scan` 2–5x; `gsub` with a template 7x on a 200 KB haystack — in one
  object, where stdlib allocates a `String` per match. `Set#match?` over
  four patterns is 2x a `Regexp.union`.
- Reading a `MatchData` costs the same objects as `::MatchData`: each
  accessor allocates exactly what it returns. `match?`, `=~`, `===` and
  `Set#match?` allocate nothing.
- Compiling a pattern is the one place rust/regex is slower: it builds its
  automaton up front (~256 µs for a small pattern in that run, against
  stdlib's ~1 µs), so compile once and keep the object.

## Development

```sh
bin/setup     # install deps
bin/console   # interactive prompt to play around
rake compile  # (re)compile extension
rake spec     # run tests
bundle exec ruby benchmark/operations.rb   # the benchmarks page's table
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/jetpks/fast_regexp.

## Credits

`fast_regexp` is a fork of
[`rust_regexp`](https://github.com/ocvit/rust_regexp) by Dmytro Horoshko —
huge thanks for the original bindings and the clean magnus integration that
made this work easy to extend. This fork rebrands the gem, reshapes the
public API (`Fast::Regexp`, real `MatchData`, `sub`/`gsub`, `===`/`=~`,
`Regexp`-constructor coercion), and adds transparent fallback to stdlib
`::Regexp` for patterns rust/regex can't compile.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
