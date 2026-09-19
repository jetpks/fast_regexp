---
type: reference
---

# `Fast::Regexp::MatchData`

One match, from either engine. On the fast path the match *is* a
`Fast::Regexp::Native::MatchData`, a subclass of this class defined by the
extension, holding capture offsets into a frozen snapshot of the haystack;
on the stdlib path it is an instance of this class wrapping a `::MatchData`.
The public surface is identical regardless of which engine produced it, and
`is_a?(Fast::Regexp::MatchData)` is true for both.

`MatchData` is constructed by `Fast::Regexp#match` and `#scan_matches` — you
shouldn't instantiate it directly.

## Capture access

### `#[](key) → String | nil`

Returns a capture as a String, or `nil` if the group did not participate or
the index/name is unknown.

`key` may be an `Integer` (including negative indices), `String`, or
`Symbol` naming a capture, or anything that converts to an Integer (a
Float truncates), as with `::MatchData#[]`. Any other key raises
`TypeError`.

### `#to_a → Array<String | nil>`

All captures including the whole match at index 0.

### `#captures → Array<String | nil>`

All captures *excluding* the whole match.

### `#named_captures → Hash<String, String | nil>`

Named captures in declaration order.

### `#names → Array<String>`

Capture group names in declaration order.

### `#values_at(*indices) → Array<String | nil>`

Captures at the given indices/names.

### `#size → Integer`

Number of capture entries (including the whole match). Aliased as `#length`.

## Match position

### `#pre_match → String`

Substring of the haystack before the match.

### `#post_match → String`

Substring after the match.

### `#to_s → String`

The whole match. Aliased as `#match`.

### `#string → String`

The haystack the match was taken over, as a frozen snapshot on both paths —
the haystack itself when it was already frozen, otherwise a frozen
copy-on-write sibling of it — so mutating the original afterwards changes
nothing the match reads, the same guarantee `::MatchData#string` gives.

### `#dup`, `#clone`

A match is immutable; on the fast path both return the match itself.

### `#byteoffset(key) → [Integer, Integer] | [nil, nil]`

`[start, end]` byte offsets of the named/indexed capture.

### `#byte_begin(key) → Integer | nil`

Start byte offset of the capture.

### `#byte_end(key) → Integer | nil`

End byte offset of the capture.

## Backend escape hatches

### `#native? → Boolean`

`true` on the fast path (the match is a `Fast::Regexp::Native::MatchData`).

### `#stdlib? → Boolean`

`true` on the stdlib path (the match wraps a `::MatchData`).

### `#native → Fast::Regexp::Native::MatchData | nil`

The match itself on the fast path, or `nil` on the stdlib path.

### `#stdlib → ::MatchData | nil`

The wrapped `::MatchData`, or `nil` on the fast path.

### `#backend → Fast::Regexp::Native::MatchData | ::MatchData`

The active backend regardless of type: the match itself on the fast path.

## Enumeration & equality

### `#each(&block)`

Yields each capture (whole match first, then groups). `MatchData` includes
`Enumerable`.

### `#==(other) → Boolean`

Equal when both `#to_a` and `#string` match. Aliased as `#eql?`.

### `#hash → Integer`

## Examples

```ruby
m = Fast::Regexp.new('(?P<word>\w+):(?P<num>\d+)').match("ruby:123")
m[0]               # => "ruby:123"
m[:word]           # => "ruby"
m["num"]           # => "123"
m.named_captures   # => { "word" => "ruby", "num" => "123" }
m.byteoffset(0)    # => [0, 8]
m.pre_match        # => ""
m.post_match       # => ""
```

## Related

- [`Fast::Regexp`](fast-regexp.md)
- [Engine fallback architecture](../explainers/engine-fallback.md)
