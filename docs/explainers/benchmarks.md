---
type: explanation
---

# Benchmarks: what each operation costs

Every public operation, with the stdlib `::Regexp` equivalent beside it,
measured by `benchmark/operations.rb`: iterations per second
(`benchmark-ips`, 2 s windows after 1 s warmup) and Ruby objects allocated
per call (`GC.stat`, exact, averaged over enough calls to fill half a
second). Haystacks and patterns are built once outside the loops, so the
object counts are the library's, not the caller's.

Taken 2026-09-19 on an Apple M2 Max (12 cores, macOS 26), Ruby 4.0.7,
fast_regexp 0.7.0 with rust/regex 1.x. Haystacks: one 100-byte log line
(embedded in its RVALUE), a 2 KB page of them, and a 200 KB log of 2,000
lines with 4,000 `key=number` matches. Reproduce with:

```sh
bundle exec ruby benchmark/operations.rb
BENCH_QUICK=1 bundle exec ruby benchmark/operations.rb   # shorter windows
```

## 0.7.0

| Operation | Fast::Regexp i/s | ::Regexp i/s | Fast::Regexp objects/call | ::Regexp objects/call |
|---|---|---|---|---|
| new, (\w+)=(\d+) | 3,817 | 888,123 | 5 | 3 |
| match?, line, hit | 7,903,055 | 816,996 | 0 | 0 |
| match?, 200 KB, miss | 259,159 | 31,701 | 0 | 0 |
| match, line | 3,668,461 | 783,301 | 1 | 1 |
| match then [1], line | 3,355,300 | 763,063 | 2 | 2 |
| =~, line | 6,376,577 | 794,030 | 0 | 0 |
| ===, line | 6,329,494 | 793,323 | 0 | 0 |
| scan, 200 KB, no groups | 1,007 | 467 | 22,001 | 22,002 |
| scan, 200 KB, groups | 1,300 | 277 | 12,001 | 12,002 |
| scan_matches, 200 KB | 1,436 | 258 | 4,001 | 16,004 |
| sub, line, template | 2,726,435 | 704,679 | 1 | 3 |
| gsub, 200 KB, template | 1,769 | 268 | 1 | 4,001 |
| gsub, 200 KB, literal | 3,917 | 293 | 1 | 1 |
| gsub, 200 KB, block | 1,022 | 268 | 8,001 | 8,002 |
| gsub, 2 KB, no match | 3,145,106 | 2,877,045 | 1 | 1 |
| Set#match, line, 4 patterns | 3,955,940 | 2,110,810 | 1 | 3 |
| Set#match?, line, 4 patterns | 15,905,670 | 8,353,154 | 0 | 0 |
| MatchData#[1] | 21,141,932 | 22,584,863 | 1 | 1 |
| MatchData#[:key] | 14,911,675 | 18,503,397 | 1 | 1 |
| MatchData#captures | 11,194,206 | 12,917,196 | 3 | 3 |
| MatchData#named_captures | 9,005,808 | 5,394,628 | 3 | 6 |
| MatchData#pre_match | 19,353,707 | 20,770,321 | 1 | 1 |
| MatchData#string | 32,633,202 | 44,844,676 | 0 | 0 |
| MatchData#byteoffset(0) | 16,695,769 | 28,680,127 | 1 | 1 |

## How to read it

**Searching is where the gem earns its name.** `match?` runs 8–10x
stdlib on a hit and on a 200 KB miss; `scan` 2–5x; `gsub` with a template
7–13x, in one object where stdlib builds one String per match for the
template form. `Set#match?` over four patterns is 2x a `Regexp.union`.

**Compiling is where it doesn't.** rust/regex builds a full automaton up
front (about 260 µs for a small pattern here) where Onigmo compiles lazily
(about 1 µs). Compile once, at load time; `Fast::Regexp.create_many` and
frozen constants exist for that. A pattern compiled per call will lose to
stdlib however fast it matches.

**Reading a match costs the same as stdlib.** Every `MatchData` accessor
allocates exactly what it returns — one String, one Array, one Hash — and
runs at 0.6–1x `::MatchData`'s speed. `#string` is slower than stdlib's
because stdlib's is an attribute read and ours crosses into the extension;
it is still 30 M calls per second.

**A match is one object.** `#match` on a frozen haystack allocates only
the `MatchData`; on an unfrozen one also a frozen copy-on-write snapshot
of the haystack (no bytes copied), the same thing `::MatchData` does.
`=~`, `===`, `match?` and `Set#match?` allocate nothing.

## Since 0.6.2

The 0.7.0 release removed the per-call copies of the haystack, the wrapper
object around every native match, and an internal exception per named
capture lookup. Same machine, same script, main at `0943048` vs 0.7.0:

| Operation | i/s 0.6.2 → 0.7.0 | objects/call 0.6.2 → 0.7.0 |
|---|---|---|
| match?, line, hit | 6,689,799 → 7,903,055 | 0 → 0 |
| match?, 200 KB, miss | 150,368 → 259,159 | 0 → 0 |
| match, line | 2,753,150 → 3,668,461 | 2 → 1 |
| =~, line | 2,292,646 → 6,376,577 | 2 → 0 |
| scan_matches, 200 KB | 1,118 → 1,436 | 8,002 → 4,001 |
| sub, line, template | 2,569,136 → 2,726,435 | 1 → 1 |
| gsub, 200 KB, block | 563 → 1,022 | 20,006 → 8,001 |
| gsub, 2 KB, no match | 2,407,035 → 3,145,106 | 1 → 1 |
| Set#match?, line | 13,609,973 → 15,905,670 | 0 → 0 |
| MatchData#[1] | 17,500,161 → 21,141,932 | 1 → 1 |
| MatchData#[:key] | 1,829,267 → 14,911,675 | 5 → 1 |
| MatchData#named_captures | 5,224,278 → 9,005,808 | 5 → 3 |
| MatchData#string | 51,093,888 → 32,633,202 | 0 → 0 |

Rows not listed moved within run-to-run noise (a few percent either way).
The one regression, `MatchData#string`, is the attribute read that became a
native call; it now returns the frozen snapshot the match was taken over
instead of the caller's mutable String.

## What the numbers don't show

Rust-side allocations are invisible to `GC.stat`. Before 0.7.0 every call
copied the whole haystack into a `Vec<u8>` and every match wrapped that
copy in an `Arc`; the time column is where that shows (the 200 KB miss
going from 150 k to 259 k calls per second is the copy, gone). The
allocation budgets that keep the counts above from regressing are in
`spec/fast_regexp/allocations_spec.rb`.
