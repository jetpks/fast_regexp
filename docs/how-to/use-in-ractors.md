---
type: how-to
---

# Use fast_regexp inside Ractors

**Goal:** share compiled regexes across Ractor workers — or build them
inside workers — and know what the frozen-snapshot guarantee buys you.

**Prerequisites:** Ruby 3.4 or newer (Ractor semantics), the gem installed.
Nothing needs enabling: the native extension declares itself Ractor-safe at
load time, so `require "fast_regexp"` works unchanged in any Ractor.

## Share one pattern across workers

Compile once on the main Ractor, make it shareable, and pass it to the
workers:

```ruby
require "fast_regexp"

re = Ractor.make_shareable(Fast::Regexp.new('(?P<word>\w+)=(?P<num>\d+)'))

workers = Array.new(4) do
  Ractor.new(re) do |pattern|
    [
      pattern.match?("a=1"),              # => true
      pattern.match("a=1")[:word],        # => "a"
      pattern.scan("a=1 b=2"),            # => [["a", "1"], ["b", "2"]]
      pattern.sub("a=1 b=2", "$2:$1")     # => "1:a b=2"
    ]
  end
end

workers.map { |r| r.respond_to?(:value) ? r.value : r.take }
# => 4 identical arrays
```

Reading a result: Ruby 3.4 uses `Ractor#take`, and Ruby 4.0 replaced it with
`Ractor#value`. Every example below reads results with
`r.respond_to?(:value) ? r.value : r.take` — the same idiom
`spec/fast_regexp/ractor_spec.rb` uses — so the examples run on both.

Every instance method works on a shared pattern in a worker: `match`,
`match?`, `===`, `=~`, `scan`, `scan_matches`, and `sub`/`gsub` in template
and block form, with the same results as on the main Ractor.

`Ractor.make_shareable` freezes the pattern and returns the same object —
all workers hold one object identity.

## Build patterns inside a worker

You don't have to pre-compile anything: a worker can load the library and
construct every native type itself — including the *first* construction of
each type happening inside a non-main Ractor:

```ruby
worker = Ractor.new do
  require "fast_regexp"
  re = Fast::Regexp.new(/(?<word>foo)/i)
  match = re.match("FOO")
  Ractor.make_shareable(match)
  match[:word]                 # => "FOO"
end

worker.respond_to?(:value) ? worker.value : worker.take
# => "FOO"
```

This also covers concurrent first loads: several workers calling
`require "fast_regexp"` at the same time is supported.

## Share a Set

`Fast::Regexp::Set` is shareable the same way, and all workers see the same
object:

```ruby
set = Ractor.make_shareable(Fast::Regexp::Set.new(["abc", "def", "xyz"]))

workers = Array.new(4) do
  Ractor.new(set) do |patterns|
    [patterns.object_id, patterns.match("abcdef"), patterns.match?("xyz")]
  end
end

workers.map { |r| r.respond_to?(:value) ? r.value : r.take }.uniq
# => [[set.object_id, [0, 1], true]]   (one entry: every worker saw the same object)
```

## Share match results (and why they're safe)

A `MatchData` is shareable too. The haystack it was taken over is a frozen
snapshot made at match time — the haystack itself when it was already
frozen, otherwise a frozen copy-on-write sibling — so later mutation of the
caller's string cannot reach the match:

```ruby
haystack = +" before a=1 after"
match = Fast::Regexp.new('(?P<word>\w+)=(?P<num>\d+)').match(haystack)
Ractor.make_shareable(match)

haystack.replace("changed")
GC.start

worker = Ractor.new(match) { |m| [m[:word], m.string] }
worker.respond_to?(:value) ? worker.value : worker.take
# => ["a", " before a=1 after"]
```

This survives GC with compaction as well: the snapshot and the capture names
stay valid after `GC.verify_compaction_references`, because everything the
match exposes is read from immutable state.

## Stdlib-fallback patterns

A pattern that fell back to stdlib `::Regexp` is shareable like any other —
freeze it (or `Ractor.make_shareable`) and use it from workers, no warm-up
call needed first:

```ruby
fallback = Ractor.make_shareable(Fast::Regexp.new('(?<word>\w+)(?=:)'))

worker = Ractor.new(fallback) do |pattern|
  [pattern.sub("a:1 b:2", "[$1]"), pattern.scan("a:1 b:2")]
end
worker.respond_to?(:value) ? worker.value : worker.take
# => ["[a]:1 b:2", [["a"], ["b"]]]
```

The engine choice doesn't change Ractor behavior; it only changes which
engine runs underneath.

## Related

- [README — Ractors](../../README.md#ractors): the guarantees, summarized.
- Ractor-safety sections: [`Fast::Regexp`](../reference/fast-regexp.md),
  [`Fast::Regexp::MatchData`](../reference/fast-regexp-matchdata.md),
  [`Fast::Regexp::Set`](../reference/fast-regexp-set.md).
- [Engine fallback architecture](../explainers/engine-fallback.md): why a
  pattern might be on the stdlib path at all.
