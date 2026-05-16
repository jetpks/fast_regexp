---
type: explanation
---

# Concurrency and GVL release

## The problem

Most Ruby C extensions hold the Global VM Lock (GVL) for the duration of
any native call. That means:

- Other Ruby threads can't run while your regex matches.
- The non-blocking fiber scheduler can't make progress on its host thread.

For a regex matching against a multi-megabyte log line, holding the GVL for
tens of milliseconds turns "I have 8 threads" into "I have 1 thread that
sometimes pauses." Not ideal.

## The model

`Fast::Regexp` releases the GVL around the actual rust/regex execution,
giving you real concurrency on threads and play-nicely behavior with the
fiber scheduler.

```
   Ruby thread ──┬── call site
                 │       │
                 │   acquire GVL release callback
                 │       │
                 ▼       ▼
        ┌──────────────────────────┐
        │  copy haystack out of    │   (so GC compaction is safe)
        │  Ruby heap → Vec<u8>     │
        └────────────┬─────────────┘
                     │
                     ▼
         rb_thread_call_without_gvl
                     │
        ┌────────────┴─────────────┐
        │  rust/regex match runs   │   ← other Ruby threads, fibers
        │  (GVL is released)       │     can run during this window
        └────────────┬─────────────┘
                     │
                     ▼
              GVL reacquired
                     │
                     ▼
              build RString result
```

## Why we copy the haystack

Ruby 4 ships with a *compacting* GC. While the GVL is released, the GC may
move RString contents to a new address. A pointer we captured before
releasing would dangle, leading to either silent corruption or a crash.

The fix is to copy the haystack bytes into a `Vec<u8>` *while still holding
the GVL*. Once we hold the bytes ourselves, they're stable for the
duration of the match regardless of what the GC does.

The cost is one allocation + a memcpy per match call.

## The 1KB threshold

`without_gvl` itself has overhead — release / reacquire involves a few
syscalls and bookkeeping, on the order of a microsecond. For tiny matches
(short haystacks against small patterns) that overhead dominates the
match itself.

We define a `GVL_RELEASE_THRESHOLD` (1024 bytes today; see
`ext/fast_regexp/src/lib.rs`). If the haystack is below the threshold, we
run the match in-place with the GVL held. If it's at or above, we release.

The result:

- Tiny matches stay cheap (no release/reacquire overhead).
- Big matches don't block the world.

This is a heuristic — workloads with millions of small matches in tight
loops *might* prefer a higher threshold, and workloads dominated by
slow-but-short adversarial patterns might prefer a lower one. The current
default is a good middle ground for typical request-processing code.

## What this buys you

```ruby
re = Fast::Regexp.new('(\w+):(\d+)')

# Real parallelism on threads (CRuby with native threads):
threads = 8.times.map do
  Thread.new { 1000.times { re.scan(big_log_line) } }
end
threads.each(&:join)

# Fiber scheduler plays nice — the matching call yields the host thread
# instead of pinning it:
Fiber.new(blocking: false) { re.match(big_log_line) }.resume
```

The test suite covers both scenarios — see the `concurrency` describe block
in `spec/fast_regexp_spec.rb`.

## Caveats

- **The stdlib fallback path holds the GVL.** When `Fast::Regexp` ends up
  using `::Regexp`, you're back to the standard Ruby-extension behavior.
  Avoid putting pathological stdlib-only patterns on hot paths if
  concurrency matters; if you must, push them out to a worker thread.
- **The copy is not free.** For very small haystacks, the copy plus
  release/reacquire would cost more than the match — hence the threshold.
- **`Fast::Regexp::Set` follows the same model** for its matches against
  multi-pattern sets.

## See also

- [Engine fallback architecture](engine-fallback.md)
- [`Fast::Regexp` reference](../reference/fast-regexp.md)
- [rust/regex performance notes](https://docs.rs/regex/latest/regex/#performance)
