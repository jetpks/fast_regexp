# frozen_string_literal: true

# Operation benchmark: every public Fast::Regexp operation with the stdlib
# ::Regexp equivalent beside it, reported as one table: iterations per
# second (benchmark-ips) and Ruby objects allocated per call (GC.stat,
# exact). Haystacks and patterns are built once outside the loops, so the
# counts are the library's, not the caller's. Rust-side allocations (copies
# of the haystack) don't show in Ruby's counters; they show in the time
# column.
#
#   bundle exec ruby benchmark/operations.rb
#   BENCH_QUICK=1 bundle exec ruby benchmark/operations.rb

require "benchmark/ips"
require_relative "../lib/fast_regexp"

QUICK = ENV["BENCH_QUICK"]

# One log line (embedded in its RVALUE), a 2 KB page, and a 200 KB log with
# a few thousand matches.
line = "2026-09-19T00:12:03Z app[web.1] ERROR request_id=abc123 status=500 path=/api/v1/users duration=42ms"
page = Array.new(20) { |i| line.sub("abc123", "req#{i}").sub("500", (200 + i).to_s) }.join("\n")
big = Array.new(2_000) { |i| line.sub("abc123", "req#{i}").sub("500", (200 + i).to_s) }.join("\n")

fast = Fast::Regexp.new('(\w+)=(\d+)')
std = /(\w+)=(\d+)/
fast_named = Fast::Regexp.new('(?P<key>\w+)=(?P<value>\d+)')
std_named = /(?<key>\w+)=(?<value>\d+)/
fast_digits = Fast::Regexp.new('\d+')
std_digits = /\d+/
fast_miss = Fast::Regexp.new("nothing like this")
std_miss = /nothing like this/
patterns = ['\bERROR\b', "status=5\\d\\d", "path=/api/v\\d+/users", "duration=\\d+ms"]
fast_set = Fast::Regexp::Set.new(patterns)
std_union = Regexp.union(patterns.map { |p| Regexp.new(p) })
std_list = patterns.map { |p| Regexp.new(p) }

fast_match = fast_named.match(line)
std_match = std_named.match(line)

# operation => [Fast::Regexp call, stdlib call]
OPERATIONS = {
  "new, (\\w+)=(\\d+)" => [-> { Fast::Regexp.new('(\w+)=(\d+)') }, -> { Regexp.new('(\w+)=(\d+)') }],
  "match?, line, hit" => [-> { fast.match?(line) }, -> { std.match?(line) }],
  "match?, 200 KB, miss" => [-> { fast_miss.match?(big) }, -> { std_miss.match?(big) }],
  "match, line" => [-> { fast.match(line) }, -> { std.match(line) }],
  "match then [1], line" => [-> { fast.match(line)[1] }, -> { std.match(line)[1] }],
  "=~, line" => [-> { fast =~ line }, -> { std =~ line }],
  "===, line" => [-> { fast === line }, -> { std === line }],
  "scan, 200 KB, no groups" => [-> { fast_digits.scan(big) }, -> { big.scan(std_digits) }],
  "scan, 200 KB, groups" => [-> { fast.scan(big) }, -> { big.scan(std) }],
  "scan_matches, 200 KB" => [-> { fast.scan_matches(big) }, -> { big.to_enum(:scan, std).map { Regexp.last_match } }],
  "sub, line, template" => [-> { fast.sub(line, "$2=$1") }, -> { line.sub(std, '\2=\1') }],
  "gsub, 200 KB, template" => [-> { fast.gsub(big, "$2=$1") }, -> { big.gsub(std, '\2=\1') }],
  "gsub, 200 KB, literal" => [-> { fast.gsub(big, "x", literal: true) }, -> { big.gsub(std, "x") }],
  "gsub, 200 KB, block" => [-> { fast.gsub(big) { |m| m[2] } }, -> { big.gsub(std) { $2 } }],
  "gsub, 2 KB, no match" => [-> { fast_miss.gsub(page, "x") }, -> { page.gsub(std_miss, "x") }],
  "Set#match, line, 4 patterns" => [-> { fast_set.match(line) }, -> { std_list.each_index.select { |i| std_list[i].match?(line) } }],
  "Set#match?, line, 4 patterns" => [-> { fast_set.match?(line) }, -> { std_union.match?(line) }],
  "MatchData#[1]" => [-> { fast_match[1] }, -> { std_match[1] }],
  "MatchData#[:key]" => [-> { fast_match[:key] }, -> { std_match[:key] }],
  "MatchData#captures" => [-> { fast_match.captures }, -> { std_match.captures }],
  "MatchData#named_captures" => [-> { fast_match.named_captures }, -> { std_match.named_captures }],
  "MatchData#pre_match" => [-> { fast_match.pre_match }, -> { std_match.pre_match }],
  "MatchData#string" => [-> { fast_match.string }, -> { std_match.string }],
  "MatchData#byteoffset(0)" => [-> { fast_match.byteoffset(0) }, -> { std_match.byteoffset(0) }]
}.freeze

# Objects allocated per call, averaged over enough calls to fit in about half
# a second, so one-off allocations outside the call don't count.
def objects_per_call(call)
  call.call
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  call.call
  once = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  times = (0.5 / once).clamp(3, 10_000).to_i
  GC.start
  before = GC.stat(:total_allocated_objects)
  times.times { call.call }
  (GC.stat(:total_allocated_objects) - before) / times.to_f
end

def commas(number)
  number.round.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
end

report = Benchmark.ips do |x|
  x.quiet = true
  x.config(time: QUICK ? 0.5 : 2, warmup: QUICK ? 0.2 : 1)
  OPERATIONS.each do |name, (fast_call, std_call)|
    x.report("#{name} fast", &fast_call)
    x.report("#{name} stdlib", &std_call)
  end
end
ips = report.entries.to_h { |entry| [entry.label, entry.ips] }

puts "| Operation | Fast::Regexp i/s | ::Regexp i/s | Fast::Regexp objects/call | ::Regexp objects/call |"
puts "|---|---|---|---|---|"
OPERATIONS.each do |name, (fast_call, std_call)|
  row = [name, commas(ips.fetch("#{name} fast")), commas(ips.fetch("#{name} stdlib")),
    commas(objects_per_call(fast_call)), commas(objects_per_call(std_call))]
  puts "| #{row.join(" | ")} |"
end
puts
puts "#{RUBY_DESCRIPTION}; fast_regexp #{Fast::Regexp::VERSION}"
