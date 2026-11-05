---
type: reference
---

# `Fast::Regexp`

A compiled regex backed by either [rust/regex](https://docs.rs/regex/) (fast
path) or stdlib `::Regexp` (fallback). The public API is identical on both
paths — including `#scan` and `#scan_matches`, which return the same results
whichever engine ran.

## Constructor

### `Fast::Regexp.new(pattern, backend: :auto, unicode: true)`

Compile a pattern.

| Parameter   | Type                     | Default | Description |
| ----------- | ------------------------ | ------- | ----------- |
| `pattern`   | `String` or `::Regexp`   | —       | Source pattern. `::Regexp` flags are translated to inline form (`(?i)`, `(?x)`, `(?s)`) for the fast path. Ruby's `/m` is dotall, which is `(?s)` in rust/regex. |
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
An empty call returns `{}`. Each pattern is compiled with
`Fast::Regexp.new(pat)` (default options); for per-pattern options call
`.new` directly.

## Class methods and constants

### `Fast::Regexp.locate_native(base, ruby_version: RUBY_VERSION) → String | nil`

Resolves the native extension's path under `base`: the per-ABI subdirectory
(`base/4.0/fast_regexp`) preferred over the flat layout (`base/fast_regexp`),
whichever exists. This is how `require "fast_regexp"` finds the precompiled
extension (prebuilt gems) versus a local `rake compile` build; callers rarely
need it.

### Constants

- `VERSION` — the gem version (`"0.9.0"`).
- `BACKENDS` — `[:auto, :fast, :stdlib]`, the accepted `backend:` values.
- `NATIVE_EXTENSIONS` — `[".bundle", ".so", ".rb"]`, the file suffixes
  probed when locating the extension.
- `RUBY_FLAG_MAP` — the `::Regexp` flag-to-inline-group translation table
  (`/i`→`(?i)`, `/x`→`(?x)`, `/m`→`(?s)`).

## Instance methods

### `#match(haystack) → Fast::Regexp::MatchData | nil`

First match. Returns a [`MatchData`](fast-regexp-matchdata.md) or `nil`.
A non-string haystack without `to_str` raises `TypeError`.

### `#match?(haystack) → Boolean`

True if the pattern matches anywhere in `haystack`. Same `TypeError`
coercion as `#match`.

### `#===(other) → Boolean`

Case-equality. Returns `false` for values without `to_str` (so `nil` →
`false`), enabling `case`/`when` and RSpec `match` matcher.

### `#=~(other) → Integer | nil`

Byte offset of the first match, or `nil`. **Byte-based**, not
character-based, on both paths. Builds no `MatchData` on the fast path.
Non-string `other` without `to_str` returns `nil`.

### `#scan(haystack) → Array<String> | Array<Array<String | nil>>`

All non-overlapping matches. Returns strings when the pattern has no capture
groups; arrays of group strings otherwise. Non-participating groups are
`nil`. Works on both engines with identical results; a stdlib-fallback
pattern scans via `String#scan` on the wrapped `::Regexp`.

### `#scan_matches(haystack) → Array<Fast::Regexp::MatchData>`

All matches as `MatchData` objects (use this when you need positions or
pre/post-match data for each hit). On the fast path every match shares one
frozen snapshot of the haystack; works on both engines.

### `#sub(haystack, replacement = nil, literal: false, &block) → String`

Replace the first match.

- String form: rust-style templates (`$1`, `${name}`, `$$`). On the stdlib
  fallback path these are translated to Ruby's `\1`/`\k<name>` automatically
  (including `$N` for a *named* group, which Ruby's `\N` can't address).
- Block form: receives a `MatchData` per match; the return value's `to_s`
  (`Object#to_s` if that isn't a String) substitutes for the match. On the
  fast path the haystack is read from a frozen snapshot while the block
  runs, so the block may do anything to the original String. With no match,
  a copy of the haystack comes back in its own encoding.
- `literal: true`: treat the replacement as a literal string (no
  `$`-expansion).
- **Raises** `TypeError` if `haystack` or `replacement` isn't
  string-convertible, `Encoding::CompatibilityError` if the block form
  yields a replacement whose encoding is incompatible with the haystack,
  and `ArgumentError` for misuse: a replacement *and* a block
  ("wrong number of arguments (given 2, expected 1 with block)"), or
  neither ("wrong number of arguments (given 1, expected 2)").

### `#gsub(haystack, replacement = nil, literal: false, &block) → String`

Same contract as `#sub` but replaces every match.

### `#pattern → String`

The compiled source string (possibly with translated flags if constructed
from a `::Regexp`).

### `#to_s → String`

Alias for `#pattern`.

### `#inspect → String`

`"#<Fast::Regexp \"...\">"`, with a ` (stdlib)` marker when running on the
fallback engine.

### `#captures_count → Integer`

Number of capturing groups (excluding the implicit whole-match group). On
the stdlib fallback path this is computed by parsing the source.

### `#names → Array<String>`

Named capture groups, in declaration order. On the fast path the strings are
interned and frozen.

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

## Ractor safety

- `Ractor.make_shareable` succeeds on a pattern and on its native backend,
  and returns the same object; all shared state is immutable, so nothing is
  copied.
- A shared pattern is fully usable in every worker — every instance method
  above, template and block substitution included, with the same results as
  on the main Ractor.
- Patterns (and every native type) can be constructed inside non-main
  Ractors, including the first construction after load; the class setup the
  extension needs completes at require time.

Recipes for all of the above live in
[Use fast_regexp inside Ractors](../how-to/use-in-ractors.md); the
[README's Ractors section](../../README.md#ractors) summarizes the
guarantees.

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
- [Use fast_regexp inside Ractors](../how-to/use-in-ractors.md)
