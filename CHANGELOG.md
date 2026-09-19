# Changelog

All notable changes to this gem are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.7.0] - 2026-09-19

### Changed

- **Haystacks are read in place.** Every native call copied the whole
  haystack into a Rust buffer before searching it; `sub`/`gsub` copied the
  replacement too, and the result a third time when nothing matched. Calls
  that hand nothing back to Ruby now read the argument's bytes directly.
  `match?` on a 200 KB miss runs 1.7x faster; `gsub` with no match 1.3x.
- **A fast-path match is the `MatchData`.** `Fast::Regexp::Native::MatchData`
  now subclasses `Fast::Regexp::MatchData`, so `#match` and `#scan_matches`
  return the native object itself instead of a Ruby wrapper around it — one
  object per match instead of two, and one fewer method dispatch on every
  accessor. `is_a?(Fast::Regexp::MatchData)` still holds; `#native?`,
  `#native`, `#backend` and `#stdlib` keep their answers; `m.class` is now
  `Fast::Regexp::Native::MatchData` on the fast path. The stdlib path keeps
  the wrapper.
- **`MatchData#string` is a frozen snapshot** of the haystack on both paths
  (the haystack itself when it was already frozen), the guarantee
  `::MatchData#string` gives. The fast path used to return a fresh copy per
  call and the stdlib wrapper the caller's mutable String; the match's own
  data was always safe from later mutation, and still is — now without
  copying the haystack per match. `dup` and `clone` of a fast-path match
  return the match itself (it is immutable).
- **Block-form `sub`/`gsub` run in one native pass**, yielding one
  `MatchData` per match and splicing the block's result in the way
  `String#gsub` does: `to_s`, `Object#to_s` if that isn't a String, and
  Ruby's encoding negotiation for the append (an incompatible replacement
  raises `Encoding::CompatibilityError`). Per match this
  costs the `MatchData` and whatever the block returns, where it cost five
  objects before; 200 KB `gsub` with a block runs 1.8x faster.
- **`=~` builds nothing**: it asks the engine for the first match's offset
  (0 objects, was 2; 2.7x faster).
- **Capture lookup by name no longer raises internally.** `m[:name]` and
  `m["name"]` tried an Integer conversion first and paid for the exception
  it raised — 5 objects and 10x stdlib's time per lookup. Lookup now
  dispatches on the key's type: 1 object, on par with `::MatchData`.
- **Group names are interned once per pattern**, on first use; `#names` and
  `#named_captures` hand out the same frozen Strings on every call. Name
  keys in any encoding, and `to_str` objects, look groups up as before.

### Fixed

- `=~` on a pattern that fell back to stdlib raised `NoMethodError`: the
  wrapper's `MatchData#byte_begin`/`byte_end` delegated to methods
  `::MatchData` doesn't have. They now derive from `byteoffset`.
- `MatchData#match`, documented as an alias of `#to_s`, existed only on the
  native class. It exists on the stdlib wrapper too.
- The CI job that reruns the suite with `GC_STRESS` set was a plain rerun;
  `spec_helper` now turns `GC.stress` on under it.

### Added

- `benchmark/operations.rb`: every public operation with the stdlib
  `::Regexp` equivalent beside it — iterations per second and objects per
  call. Results and method on the
  [benchmarks page](docs/explainers/benchmarks.md).
- `spec/fast_regexp/allocations_spec.rb` freezes the objects-per-call
  budget of every fast-path operation.

## [0.6.2] and earlier

See the git history.
