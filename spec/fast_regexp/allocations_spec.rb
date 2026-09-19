# frozen_string_literal: true

# Allocation budgets for the fast path: what each operation costs in Ruby
# objects beyond its own result. Counts are GC.stat, exact. Everything a
# measured block touches is bound to a local first, so the count is the
# library's, not the example's.
RSpec.describe "allocations" do
  # Objects allocated per call of the block, averaged over +times+ calls.
  def allocations(times = 100, &block)
    times.times(&block)
    GC.start
    before = GC.stat(:total_allocated_objects)
    times.times(&block)
    (GC.stat(:total_allocated_objects) - before) / times.to_f
  end

  let(:line) { "app[web.1] ERROR request_id=abc123 status=500 path=/api/v1/users duration=42ms" }
  let(:big) { Array.new(200) { |i| line.sub("abc123", "req#{i}") }.join("\n").freeze }

  it "answers match?, ===, =~ and Set#match? without allocating" do
    re = Fast::Regexp.new('(\w+)=(\d+)')
    set = Fast::Regexp::Set.new(['\d+', "ERROR"])
    line = self.line
    expect(allocations { re.match?(line) }).to be < 1
    expect(allocations { re === line }).to be < 1
    expect(allocations { re =~ line }).to be < 1
    expect(allocations { set.match?(line) }).to be < 1
  end

  it "builds a match from a frozen haystack in one object, and a snapshot for an unfrozen one" do
    re = Fast::Regexp.new('(\w+)=(\d+)')
    frozen = line
    unfrozen = +line
    expect(allocations { re.match(frozen) }).to be < 2
    expect(allocations { re.match(unfrozen) }).to be < 3
  end

  it "scans matches in one object per match, plus the array and one shared snapshot" do
    re = Fast::Regexp.new('(\w+)=(\d+)')
    big = +self.big
    matches = re.scan_matches(big).size
    expect(allocations(10) { re.scan_matches(big) }).to be < matches + 3
  end

  it "substitutes a template in one object, the result" do
    re = Fast::Regexp.new('(\w+)=(\d+)')
    big = self.big
    expect(allocations { re.sub(big, "$2=$1") }).to be < 2
    expect(allocations(10) { re.gsub(big, "$2=$1") }).to be < 2
    expect(allocations(10) { re.gsub(big, "-", literal: true) }).to be < 2
  end

  it "substitutes with a block in one MatchData per match, plus the result" do
    re = Fast::Regexp.new('(\w+)=(\d+)')
    big = self.big
    matches = re.scan_matches(big).size
    expect(allocations(10) { re.gsub(big) { "x" } }).to be < matches + 2
  end

  it "looks captures up by index, name or symbol in one object, the capture" do
    m = Fast::Regexp.new('(?P<key>\w+)=(?P<value>\d+)').match(line)
    expect(allocations { m[1] }).to be < 2
    expect(allocations { m[:key] }).to be < 2
    expect(allocations { m["key"] }).to be < 2
  end

  it "hands out interned group names: names in one object, named_captures in one plus the values" do
    m = Fast::Regexp.new('(?P<key>\w+)=(?P<value>\d+)').match(line)
    expect(allocations { m.names }).to be < 2
    expect(allocations { m.named_captures }).to be < 4
  end

  it "answers Set#match in one object, the result" do
    set = Fast::Regexp::Set.new(['\d+', "ERROR"])
    line = self.line
    expect(allocations { set.match(line) }).to be < 2
  end
end
