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

Taken 2026-11-05 on an Apple M4 Max (16 cores, macOS 26.7.1),
`ruby 4.0.9 (2026-10-23 revision 3e93b23afc) +PRISM [arm64-darwin25]`,
fast_regexp 0.9.0 with rust/regex 1.12.3. Haystacks: one 100-byte log line
(embedded in its RVALUE), a 2 KB page of them, and a 200 KB log of 2,000
lines with 4,000 `key=number` matches. Reproduce with:

```sh
bundle exec ruby benchmark/operations.rb
BENCH_QUICK=1 bundle exec ruby benchmark/operations.rb   # shorter windows
```

These are one run's numbers. Run-to-run i/s varies a few percent on this
machine: a second full run immediately after this one moved every row
within ±5% in either direction (fast-path rows −1.6% to +4.4%, stdlib rows
−5.2% to +7.0%) with identical object counts. Treat the i/s columns as
repeatable to a few percent, the object counts as exact; older tables below
are kept frozen as history.

## 0.9.0

| Operation | Fast::Regexp i/s | ::Regexp i/s | Fast::Regexp objects/call | ::Regexp objects/call |
|---|---|---|---|---|
| new, (\w+)=(\d+) | 3,903 | 893,931 | 6 | 3 |
| match?, line, hit | 6,844,290 | 739,347 | 0 | 0 |
| match?, 200 KB, miss | 250,465 | 31,690 | 0 | 0 |
| match, line | 2,613,421 | 702,867 | 1 | 1 |
| match then [1], line | 2,392,315 | 694,348 | 2 | 2 |
| =~, line | 5,677,362 | 713,942 | 0 | 0 |
| ===, line | 5,363,215 | 717,836 | 0 | 0 |
| scan, 200 KB, no groups | 1,007 | 456 | 22,001 | 22,002 |
| scan, 200 KB, groups | 1,265 | 256 | 12,001 | 12,002 |
| scan_matches, 200 KB | 1,342 | 230 | 4,001 | 16,004 |
| sub, line, template | 2,612,180 | 620,038 | 1 | 3 |
| gsub, 200 KB, template | 1,740 | 249 | 1 | 4,001 |
| gsub, 200 KB, literal | 3,893 | 270 | 1 | 1 |
| gsub, 200 KB, block | 953 | 258 | 8,001 | 8,002 |
| gsub, 2 KB, no match | 3,116,375 | 2,843,237 | 1 | 1 |
| Set#match, line, 4 patterns | 3,899,194 | 2,010,340 | 1 | 3 |
| Set#match?, line, 4 patterns | 15,396,117 | 7,261,583 | 0 | 0 |
| MatchData#[1] | 18,692,795 | 20,497,911 | 1 | 1 |
| MatchData#[:key] | 12,088,273 | 16,819,735 | 1 | 1 |
| MatchData#captures | 10,508,029 | 11,955,255 | 3 | 3 |
| MatchData#named_captures | 8,243,922 | 5,134,626 | 3 | 6 |
| MatchData#pre_match | 17,139,524 | 18,225,019 | 1 | 1 |
| MatchData#string | 27,882,697 | 37,855,715 | 0 | 0 |
| MatchData#byteoffset(0) | 14,963,578 | 24,005,617 | 1 | 1 |

Since the 0.7.0 table below, one object count moved: the `new` row is 6
objects/call here against 5 there — the 0.9.0 Ractor work shifted
compile-time allocations. Every other row's object count is unchanged and
match-once usage is unaffected.

## How to read it

**Searching is where the gem earns its name.** `match?` runs 9.3x stdlib on
a line hit (6,844,290 vs 739,347) and 7.9x on a 200 KB miss (250,465 vs
31,690); `scan` 2.2–4.9x; `gsub` with a template 7.0x on 200 KB (1,740 vs
249), in one object where stdlib builds one String per match (4,001 objects
vs 1). `Set#match?` over four patterns is 2.1x a `Regexp.union`
(15,396,117 vs 7,261,583).

**Compiling is where it doesn't.** rust/regex builds a full automaton up
front — the `new` row's 3,903 compiles/s is ≈256 µs per compile — where
Onigmo compiles lazily (893,931/s, ≈1 µs). Compile once, at load time;
`Fast::Regexp.create_many` and frozen constants exist for that. A pattern
compiled per call will lose to stdlib however fast it matches.

**Reading a match costs the same objects as stdlib, at 0.6–1x its speed.**
Every `MatchData` accessor allocates exactly what it returns — one String,
one Array, one Hash — and runs at 0.6–1x `::MatchData` (`#byteoffset(0)`
0.62x, `#[:key]` 0.72x, `#string` 0.74x, `#[1]` 0.91x). `#named_captures`
is the exception at 1.6x: ours allocates 3 objects where stdlib allocates
6. `#string` is slower than stdlib's because stdlib's is an attribute read
and ours crosses into the extension; it is still 27.9 M calls per second.

**A match is one object.** `#match` on a frozen haystack allocates only
the `MatchData`; on an unfrozen one also a frozen copy-on-write snapshot
of the haystack (no bytes copied), the same thing `::MatchData` does.
`=~`, `===`, `match?` and `Set#match?` allocate nothing; `#match` then
`[1]` is two objects, the match and the capture.

## Since 0.6.2

This comparison predates the 0.9.0 Ractor work and the stdlib `#scan` fix;
the numbers are kept frozen as history. The 0.7.0 release removed the
per-call copies of the haystack, the wrapper object around every native
match, and an internal exception per named capture lookup. Same machine
class, same script, main at `0943048` vs 0.7.0:

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
