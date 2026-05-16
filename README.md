# RustRegexp

[![Gem Version](https://badge.fury.io/rb/rust_regexp.svg)](https://badge.fury.io/rb/rust_regexp)
[![Test](https://github.com/ocvit/rust_regexp/workflows/CI/badge.svg)](https://github.com/ocvit/rust_regexp/actions)

Ruby bindings for [rust/regex](https://docs.rs/regex/latest/regex/) library.

## Installation

Install [Rust](https://www.rust-lang.org/) via [rustup](https://rustup.rs/) or in any other way.

Add as a dependency:

```ruby
# In your Gemfile
gem "rust_regexp"

# Or without Bundler
gem install rust_regexp
```

Include in your code:

```ruby
require "rust_regexp"
```

## Usage

Regular expressions should be pre-compiled before use:

```ruby
re = RustRegexp.new('p.t{2}ern*')
# => #<RustRegexp:...>
```

> [!TIP]
> Note the use of *single quotes* when passing the regular expression as
> a string to `rust/regex` so that the backslashes aren't interpreted as escapes.

You can also build from an existing Ruby `Regexp` — trailing flags (`/i`,
`/x`, `/m`) are translated to inline form for the rust engine:

```ruby
RustRegexp.new(/foo/i).pattern    # => "(?i)foo"
RustRegexp.new(/foo.bar/m).match?("foo\nbar")  # => true (Ruby's /m = dotall)
```

### Matching

`#match` returns a `RustRegexp::MatchData` on a hit and `nil` on no match —
matching Ruby's `Regexp#match` shape:

```ruby
m = RustRegexp.new('(\w+):(\d+)').match("ruby:123, rust:456")
m[0]              # => "ruby:123"   (whole match)
m[1]              # => "ruby"
m[2]              # => "123"
m.pre_match       # => ""
m.post_match      # => ", rust:456"
m.captures        # => ["ruby", "123"]
m.to_a            # => ["ruby:123", "ruby", "123"]
m.byteoffset(0)   # => [0, 8]

RustRegexp.new('\d+').match("abc")  # => nil
```

Named captures use rust/regex's `(?P<name>...)` syntax:

```ruby
m = RustRegexp.new('(?P<word>\w+):(?P<num>\d+)').match("ruby:123")
m[:word]            # => "ruby"
m["num"]            # => "123"
m.named_captures    # => { "word" => "ruby", "num" => "123" }
```

`#match?`, `#===`, and `#=~` are also available:

```ruby
re = RustRegexp.new('\d+')
re.match?("123")                          # => true
re === "abc 42"                           # => true (works in case/when)
re =~ "abc 42"                            # => 4 (byte offset of first match)
```

### Scanning

```ruby
RustRegexp.new('\w+:\d+').scan("ruby:123, rust:456")
# => ["ruby:123", "rust:456"]

RustRegexp.new('(\w+):(\d+)').scan("ruby:123, rust:456")
# => [["ruby", "123"], ["rust", "456"]]
```

For per-match positions and pre/post-match access, use `#scan_matches`:

```ruby
RustRegexp.new('(\w+):(\d+)').scan_matches("ruby:123, rust:456").map { |m| m.byteoffset(0) }
# => [[0, 8], [10, 18]]
```

### Substitution

`#sub` and `#gsub` use rust/regex's native replacement template — `$1`,
`${name}`, and `$$` for a literal `$`:

```ruby
re = RustRegexp.new('(\w+):(\d+)')
re.sub("ruby:123 rust:456",  '$2-$1')   # => "123-ruby rust:456"
re.gsub("ruby:123 rust:456", '$2-$1')   # => "123-ruby 456-rust"
```

Block form receives a `MatchData`:

```ruby
RustRegexp.new('\d+').gsub("a1 b22 c333") { |m| "<#{m[0].size}>" }
# => "a<1> b<2> c<3>"
```

Pass `literal: true` to disable `$`-expansion entirely.

### Other

```ruby
RustRegexp.new('\w+:\d+').pattern         # => "\\w+:\\d+"
RustRegexp.new('(?P<n>\w+)').names        # => ["n"]
RustRegexp.new('(a)(b)').captures_count   # => 2
```

> [!WARNING]
> `rust/regex` regular expression syntax differs from Ruby's built-in
> [`Regexp`](https://docs.ruby-lang.org/en/3.4/Regexp.html) library, see the
> [official syntax page](https://docs.rs/regex/latest/regex/index.html#syntax) for more
> details.

### Searching simultaneously

`RustRegexp::Set` represents a collection of
regular expressions that can be searched for simultaneously. Calling `RustRegexp::Set#match` will return an array containing the indices of all the patterns that matched.

```ruby
set = RustRegexp::Set.new(["abc", "def", "ghi", "xyz"])

set.match("abcdefghi") # => [0, 1, 2]
set.match("ghidefabc") # => [0, 1, 2]
```

> [!NOTE]
> Matches arrive in the order the constituent patterns were declared,
> not the order they appear in the haystack.

To check whether at least one pattern from the set matches the haystack:

```ruby
RustRegexp::Set.new(["abc", "def"]).match?("abc")
# => true

RustRegexp::Set.new(["abc", "def"]).match?("123")
# => false
```

Inspect original patterns:

```ruby
RustRegexp::Set.new(["abc", "def"]).patterns
# => ["abc", "def"]
```

## Encoding

Currently, `rust_regexp` expects the haystack to be an UTF-8 string.

It also supports parsing of strings with invalid UTF-8 characters by default. It's achieved via using `regex::bytes` instead of plain `regex` under the hood, so any byte sequence can be matched. The output match is encoded as UTF-8 string.

In case unicode awarness of matchers should be disabled, both `RustRegexp` and `RustRegexp::Set` support `unicode: false` option:

```ruby
RustRegexp.new('\w+').match('ю٤夏')
# => ["ю٤夏"]

RustRegexp.new('\w+', unicode: false).match('ю٤夏')
# => []

RustRegexp::Set.new(['\w', '\d', '\s']).match("ю٤\u2000")
# => [0, 1, 2]

RustRegexp::Set.new(['\w', '\d', '\s'], unicode: false).match("ю٤\u2000")
# => []
```

## Development

```sh
bin/setup     # install deps
bin/console   # interactive prompt to play around
rake compile  # (re)compile extension
rake spec     # run tests
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ocvit/rust_regexp.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
