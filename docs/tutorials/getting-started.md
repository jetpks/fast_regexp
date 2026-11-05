---
type: tutorial
---

# Getting started with `fast_regexp`

**Goal:** install the gem and run your first match, substitution, and
multi-pattern scan — compiling the extension only happens on platforms
without a precompiled gem.

**Prerequisites:**

- Ruby 3.4 or newer
- Bundler (`gem install bundler`)
- A [Rust toolchain](https://rustup.rs/) (`cargo` on `PATH`) — only if your
  platform doesn't get a precompiled gem (see below)

## 1. Install

Add the gem to your `Gemfile`:

```ruby
gem "fast_regexp"
```

…and install:

```sh
bundle install
```

Precompiled native gems cover **arm64-darwin**, **x86_64-linux**, and
**aarch64-linux** on Ruby **3.4** and **4.0** — on those combinations the
install is a download, no Rust needed. Any other platform/Ruby combo
installs the source gem and compiles the extension at install time; if you
see "cargo: command not found" there, install Rust first.

## 2. Your first match

```ruby
require "fast_regexp"

re = Fast::Regexp.new('(\w+):(\d+)')
m = re.match("ruby:123, rust:456")

m[0]            # => "ruby:123"   (whole match)
m[1]            # => "ruby"
m[2]            # => "123"
m.pre_match     # => ""
m.post_match    # => ", rust:456"
```

`#match` returns a [`Fast::Regexp::MatchData`](../reference/fast-regexp-matchdata.md)
on a hit, or `nil` on no match — same shape as stdlib `::Regexp#match`.

## 3. Substitution

`#sub` and `#gsub` use rust/regex's template syntax (`$1`, `${name}`, `$$`):

```ruby
re = Fast::Regexp.new('(\w+):(\d+)')
re.gsub("ruby:123 rust:456", '$2-$1')
# => "123-ruby 456-rust"
```

Block form receives a `MatchData`:

```ruby
Fast::Regexp.new('\d+').gsub("a1 b22 c333") { |m| "<#{m[0].size}>" }
# => "a<1> b<2> c<3>"
```

## 4. Multi-pattern scan

For "does this string match any of these patterns?" use
[`Fast::Regexp::Set`](../reference/fast-regexp-set.md):

```ruby
set = Fast::Regexp::Set.new(["abc", "def", "ghi"])
set.match("ghidefabc")   # => [0, 1, 2]
set.match?("xyz")        # => false
```

## 5. What if rust/regex doesn't support my pattern?

It requires no setup — `Fast::Regexp` transparently falls back to stdlib `::Regexp`
for features like lookaround and backreferences:

```ruby
re = Fast::Regexp.new('foo(?=bar)')
re.fast?               # => false
re.stdlib?             # => true
re.match?("foobar")    # => true
```

See [Engine fallback architecture](../explainers/engine-fallback.md) for the
"why" and [Handle patterns rust/regex can't compile](../how-to/handle-unsupported-syntax.md)
for the "how to spot it."

## Next steps

- [Migrate from stdlib `::Regexp`](../how-to/migrate-from-stdlib-regexp.md)
- [`Fast::Regexp` reference](../reference/fast-regexp.md)
- [Use fast_regexp inside Ractors](../how-to/use-in-ractors.md)
