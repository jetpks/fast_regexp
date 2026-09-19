---
type: reference
---

# `Fast::Regexp`

A compiled regex backed by either [rust/regex](https://docs.rs/regex/) (fast
path) or stdlib `::Regexp` (fallback). The public API is identical on both.

## Constructor

### `Fast::Regexp.new(pattern, backend: :auto, unicode: true)`

Compile a pattern.

| Parameter   | Type                     | Default | Description |
| ----------- | ------------------------ | ------- | ----------- |
| `pattern`   | `String` or `::Regexp`   | —       | Source pattern. `::Regexp` flags are translated to inline form (`(?i)`, `(?x)`, `(?s)`) for the fast path. |
| `backend:`  | `:auto`, `:fast`, `:stdlib` | `:auto` | Force a specific engine. `:auto` tries rust/regex and falls back to `::Regexp`; `:fast` raises if rust/regex rejects the pattern; `:stdlib` skips rust/regex entirely. |
| `unicode:`  | `Boolean`                | `true`  | rust/regex's unicode awareness. Ignored on the stdlib path. |

**Raises** `ArgumentError` if the pattern is malformed in both engines
(`:auto`), if rust/regex rejects the pattern (`:fast`), or if `backend:`
isn't one of the recognized values. **Raises** `RegexpError` if `:stdlib`
is forced and the pattern is malformed in Ruby's engine.

**Returns** a `Fast::Regexp`. Use `#fast?` / `#stdlib?` to learn which
backend ended up handling it.

### `Fast::Regexp.create_many(*patterns, **named) → Array<Fast::Regexp> | Hash{Symbol => Fast::Regexp}`

Bulk-compile a set of patterns. Two call shapes:

```ruby
# Keyword form — returns a symbol-keyed hash. Handy for named constants.
RE = Fast::Regexp.create_many(word: '\w+', num: '\d+').freeze
RE[:word].match("hello")

# Positional form — returns an array, preserving order.
patterns = Fast::Regexp.create_many('\w+', '\d+')
patterns.first.match("hello")
```

Mixing positional and keyword args in the same call raises `ArgumentError`.
Each pattern is compiled with `Fast::Regexp.new(pat)` (default options);
for per-pattern options call `.new` directly.

## Instance methods

### `#match(haystack) → Fast::Regexp::MatchData | nil`

First match. Returns a [`MatchData`](fast-regexp-matchdata.md) or `nil`.

### `#match?(haystack) → Boolean`

True if the pattern matches anywhere in `haystack`.

### `#===(other) → Boolean`

Case-equality. Returns `false` for non-string-like values, enabling
`case`/`when` and RSpec `match` matcher.

### `#=~(other) → Integer | nil`

Byte offset of the first match, or `nil`. **Byte-based**, not character-based.
Builds no `MatchData` on the fast path.

### `#scan(haystack) → Array<String> | Array<Array<String | nil>>`

All non-overlapping matches. Returns strings when the pattern has no capture
groups; arrays of group strings otherwise. Non-participating groups are
`nil`.

### `#scan_matches(haystack) → Array<Fast::Regexp::MatchData>`

All matches as `MatchData` objects (use this when you need positions or
pre/post-match data for each hit).

### `#sub(haystack, replacement = nil, literal: false, &block) → String`

Replace the first match.

- String form: rust-style templates (`$1`, `${name}`, `$$`). On the stdlib
  fallback path these are translated to Ruby's `\1`/`\k<name>` automatically.
- Block form: receives a `MatchData` per match; the return value's `to_s`
  substitutes for the match. On the fast path the haystack is read from a
  frozen snapshot while the block runs, so the block may do anything to
  the original String. With no match, a copy of the haystack comes back in
  its own encoding.
- `literal: true`: treat the replacement as a literal string (no
  `$`-expansion).

### `#gsub(haystack, replacement = nil, literal: false, &block) → String`

Same as `#sub` but replaces every match.

### `#pattern → String`

The compiled source string (possibly with translated flags if constructed
from a `::Regexp`).

### `#to_s → String`

Alias for `#pattern`.

### `#inspect → String`

`"#<Fast::Regexp \"...\">"`, with a `(stdlib)` marker when running on the
fallback engine.

### `#captures_count → Integer`

Number of capturing groups (excluding the implicit whole-match group). On
the stdlib fallback path this is computed by parsing the source.

### `#names → Array<String>`

Named capture groups, in declaration order.

### `#fast? → Boolean`

`true` when the pattern compiled successfully on rust/regex.

### `#stdlib? → Boolean`

`true` when the pattern fell back to stdlib `::Regexp`.

### `#native → Fast::Regexp::Native | nil`

The underlying rust-backed object, or `nil` on the stdlib path.

### `#stdlib → ::Regexp | nil`

The underlying stdlib regex, or `nil` on the fast path.

### `#backend → Fast::Regexp::Native | ::Regexp`

The active backend regardless of type — convenient for delegation.

## Examples

```ruby
Fast::Regexp.new('\w+:\d+').scan("a:1 b:2")
# => ["a:1", "b:2"]

Fast::Regexp.new(/foo/i).pattern
# => "(?i)foo"

Fast::Regexp.new('(?P<name>\w+)').match("ruby")[:name]
# => "ruby"
```

## Related

- [`Fast::Regexp::MatchData`](fast-regexp-matchdata.md)
- [`Fast::Regexp::Set`](fast-regexp-set.md)
- [Engine fallback architecture](../explainers/engine-fallback.md)
