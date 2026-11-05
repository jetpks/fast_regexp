# fast_regexp documentation

Documentation for `fast_regexp` organized by [Diátaxis](https://diataxis.fr/).
The repo [`README.md`](../README.md) is the front door — it carries the
install matrix, a usage tour, and the Ractor and performance overviews; the
pages below hold the depth.

## Tutorials — learn by doing

- [Getting started](tutorials/getting-started.md) — install and your first match, substitution, and Set scan.

## How-to guides — task recipes

- [Migrate from stdlib `::Regexp`](how-to/migrate-from-stdlib-regexp.md)
- [Handle patterns rust/regex can't compile](how-to/handle-unsupported-syntax.md)
- [Use fast_regexp inside Ractors](how-to/use-in-ractors.md)

## Reference — exact behaviour

- [`Fast::Regexp`](reference/fast-regexp.md)
- [`Fast::Regexp::MatchData`](reference/fast-regexp-matchdata.md)
- [`Fast::Regexp::Set`](reference/fast-regexp-set.md)

## Explainers — concepts and design

- [Engine fallback architecture](explainers/engine-fallback.md)
- [Benchmarks: what each operation costs](explainers/benchmarks.md)
