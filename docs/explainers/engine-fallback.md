---
type: explanation
---

# Engine fallback architecture

## The problem

rust/regex is fast and has linear-time matching guarantees — but it
deliberately omits features that prevent those guarantees: lookaround,
backreferences, and possessive quantifiers, among others. Ruby's stdlib
`::Regexp` supports those features but is slower.

A real-world codebase usually has a handful of "stdlib-only" patterns mixed
in with hundreds of patterns that rust/regex would happily handle. Forcing
the caller to manage two regex libraries — one for the fast cases, one for
the rest — pushes that complexity into every call site.

## The model

`Fast::Regexp` is a thin Ruby façade over two backends. When you call
`Fast::Regexp.new(pattern)`:

1. We try `rust/regex` first via the native extension.
2. On `ArgumentError` from the engine (lookaround, backrefs, etc.), we
   transparently compile the same pattern with stdlib `::Regexp`.
3. The resulting `Fast::Regexp` object holds whichever backend won, and
   every public method (`#match`, `#sub`, `#gsub`, `#===`, `#=~`, `#scan`,
   …) dispatches accordingly.
4. `#match` always returns a `Fast::Regexp::MatchData`. On the fast path
   that is the native match object itself (`Fast::Regexp::Native::MatchData`
   subclasses `Fast::Regexp::MatchData`); on the stdlib path it is a small
   Ruby wrapper adapting `::MatchData` to the same public surface.

```
                  Fast::Regexp.new(pattern)
                            │
                            ▼
                  rust/regex compile?
                  ┌─────────┴─────────┐
                 yes                  no
                  │                   │
                  ▼                   ▼
        Fast::Regexp::Native    ::Regexp (fallback)
                  │                   │
                  └────────┬──────────┘
                           ▼
                     Fast::Regexp
                  (one façade, one type)
                           │
                           ▼
                       #match
                           │
                           ▼
                  Fast::Regexp::MatchData
          (the native match itself, or a wrapper
           around ::MatchData on the fallback path)
```

## Consequences

**Callers see one type.** `is_a?(Fast::Regexp)` is true regardless of
which engine ran. `MatchData` exposes the same `#[]`, `#captures`,
`#named_captures`, `#pre_match`, `#post_match`, `#byteoffset` on both
paths.

**Replacement template syntax is unified.** `sub`/`gsub` use rust-style
templates (`$1`, `${name}`, `$$`) on both paths — the stdlib path
translates them to Ruby's `\1`/`\k<name>` internally, including the
special case where `$N` refers to a *named* group (Ruby's gsub ignores
`\N` for those, so the translator emits `\k<name>` instead).

**Pattern-bad-in-both is still an error.** If neither engine can compile
the pattern, we raise `ArgumentError` carrying rust/regex's (typically more
detailed) error message.

**Performance is bimodal but predictable.** A pattern's engine choice is
stable for the life of the `Fast::Regexp`. There's no per-call decision —
the decision is at compile time. You can assert "this hot-path pattern is
on rust/regex" with `expect(re).to be_fast` in a test.

**`Fast::Regexp::Set` does not fall back.** Multi-pattern matching is a
rust/regex feature with no stdlib equivalent. `Set.new` raises on any
unsupported pattern.

## Alternatives considered

- **Manual two-library juggling.** Callers tag each pattern with which
  engine to use. Rejected — pushes mechanical knowledge into business code,
  and a new pattern with one lookaround forces rewriting the wrapper.
- **Compile both engines, pick at match time.** Doubles compile cost,
  doubles memory, no behavioral benefit since the engine choice is
  deterministic from the pattern.
- **Refuse to compile unsupported patterns.** What the gem did pre-0.5.0.
  Forces consumers to deal with the divergence themselves; the original
  motivation for this rewrite was the friction from that posture.

## Overriding the choice

The auto-selection is the default, but you can force a specific backend
when needed:

```ruby
Fast::Regexp.new('\w+', backend: :fast)     # rust/regex only; raise on unsupported
Fast::Regexp.new(pat,   backend: :stdlib)   # ::Regexp only; skip the rust attempt
```

`:fast` is useful on hot paths where you want a loud failure if someone
introduces a pattern that would quietly fall back. `:stdlib` saves the
wasted rust-compile attempt when you already know the pattern uses
features rust/regex doesn't support. The default remains `:auto` —
designed for callers who don't want to think about it.

## Escape hatches

When you need the underlying engine object (passing to a library that
expects a `::Regexp`, calling a rust/regex-specific method, etc.):

```ruby
re = Fast::Regexp.new('\w+')
re.native    # => #<Fast::Regexp::Native ...>
re.stdlib    # => nil  (rust path)

re = Fast::Regexp.new('foo(?=bar)')
re.native    # => nil  (stdlib path)
re.stdlib    # => /foo(?=bar)/
```

Same accessors exist on `Fast::Regexp::MatchData`. This keeps the abstraction
porous on purpose — the goal is "you don't have to think about it," not
"you can't reach the underlying tools."

## See also

- [`Fast::Regexp` reference](../reference/fast-regexp.md)
- [Handle patterns rust/regex can't compile](../how-to/handle-unsupported-syntax.md)
