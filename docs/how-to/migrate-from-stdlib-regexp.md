---
type: how-to
---

# Migrate from stdlib `::Regexp`

**Goal:** swap an existing codebase from `::Regexp` to `Fast::Regexp` with
minimal call-site changes.

## TL;DR

```ruby
# before
re = /(\w+):(\d+)/
# after
re = Fast::Regexp.new(/(\w+):(\d+)/)
```

The constructor accepts a `::Regexp` directly and translates trailing flags
(`/i`, `/x`, `/m`) into inline `(?ixs)` form so the rust/regex engine sees
them. Most read-only call sites work unchanged.

## Method mapping

| stdlib `::Regexp`      | `Fast::Regexp`                | Notes |
| ---------------------- | ----------------------------- | ----- |
| `=~ "str"`             | same                          | Returns a **byte** offset (not a character offset). |
| `=== "str"`            | same                          | Works in `case`/`when`. |
| `match("str")`         | same                          | Returns `Fast::Regexp::MatchData` or `nil`. |
| `match?("str")`        | same                          | |
| `"str".scan(re)`       | `re.scan("str")`              | Same return shape. |
| `"str".sub(re, repl)`  | `re.sub("str", repl)`         | **Template syntax is rust-style** (`$1`, `${name}`). |
| `"str".gsub(re, repl)` | `re.gsub("str", repl)`        | Same as `sub`. |
| `re.source`            | `re.pattern`                  | Returns the (possibly translated) source string. |

## Replacement template changes

Rust uses `$N` / `${name}` instead of `\N` / `\k<name>`:

```ruby
# stdlib
"a:1".gsub(/(\w+):(\d+)/, '\2-\1')        # => "1-a"

# fast_regexp
Fast::Regexp.new('(\w+):(\d+)').gsub("a:1", '$2-$1')   # => "1-a"
```

For a literal `$` in the replacement, use `$$` or pass `literal: true`:

```ruby
Fast::Regexp.new('foo').sub("foo", '$1 wins', literal: true)
# => "$1 wins"
```

If you have a lot of `\N`-style replacements you'd rather not touch, the
block form is the universal escape hatch — it works identically across both
engines:

```ruby
Fast::Regexp.new('(\w+):(\d+)').gsub("a:1") { |m| "#{m[2]}-#{m[1]}" }
```

## What you don't have to migrate

Patterns rust/regex doesn't support (lookaround, backreferences) will
silently fall back to stdlib `::Regexp`. The API and return types stay the
same. See [Engine fallback architecture](../explainers/engine-fallback.md).

## Verification

After migrating, run your test suite and confirm:

- Replacement strings still produce expected output (template syntax!).
- `=~`-based offset comparisons still make sense if your strings contain
  multibyte characters — `Fast::Regexp#=~` returns bytes, not characters.

## Caveats

- `Fast::Regexp` is byte-based. If your code calls
  `str[m.byte_begin(0)..m.byte_end(0)]` you're fine, but
  `str[m.begin(0)..m.end(0)]` (character offsets) is not supported on the
  fast path.
- `Fast::Regexp::Set` has no stdlib equivalent — multi-pattern matching
  there is a rust/regex-only feature.
