---
type: reference
---

# `Fast::Regexp::Set`

A collection of patterns that can be tested simultaneously against a
haystack. Returns the indices of all patterns that matched. Backed by
[rust/regex's `RegexSet`](https://docs.rs/regex/latest/regex/struct.RegexSet.html);
this class has **no stdlib fallback** — patterns must compile under
rust/regex.

## Constructor

### `Fast::Regexp::Set.new(patterns, unicode: true)`

| Parameter   | Type             | Default | Description |
| ----------- | ---------------- | ------- | ----------- |
| `patterns`  | `Array<String>`  | —       | Patterns to test simultaneously. |
| `unicode:`  | `Boolean`        | `true`  | rust/regex unicode awareness. |

**Raises** `ArgumentError` if any pattern is invalid or uses unsupported
syntax (lookaround, backrefs, etc.).

## Instance methods

### `#match(haystack) → Array<Integer>`

Indices of the patterns that matched, in declaration order (**not** in the
order the matches appear in the haystack).

### `#match?(haystack) → Boolean`

`true` if at least one pattern matches.

### `#patterns → Array<String>`

The original pattern strings.

## Ractor safety

- `Ractor.make_shareable` succeeds on a Set and returns the same object —
  one Set shared across workers answers correctly with a stable object
  identity.
- Sets can be constructed inside non-main Ractors, including as the first
  use of the type after load.

Recipes live in [Use fast_regexp inside Ractors](../how-to/use-in-ractors.md);
the [README's Ractors section](../../README.md#ractors) summarizes the
guarantees.

## Caveats

- Capture groups in member patterns are ignored — `Set` only reports *which*
  patterns matched, not the matched substrings or groups. Use a
  `Fast::Regexp` for capture extraction.
- Cannot fall back to stdlib — Ruby's `::Regexp` has no native multi-pattern
  equivalent.

## Examples

```ruby
set = Fast::Regexp::Set.new(["abc", "def", "ghi"])

set.match("ghidefabc")   # => [0, 1, 2]
set.match("xyz")         # => []
set.match?("xyz")        # => false
set.patterns             # => ["abc", "def", "ghi"]
```

## Related

- [`Fast::Regexp`](fast-regexp.md) — single-pattern matching with captures.
- [Use fast_regexp inside Ractors](../how-to/use-in-ractors.md)
