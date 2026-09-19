# frozen_string_literal: true

RSpec.describe Fast::Regexp::MatchData do
  let(:re) { Fast::Regexp.new('(?P<key>\w+)=(?P<value>\d+)') }

  it "is the native MatchData itself on the fast path, with no wrapper" do
    m = re.match("status=500")
    expect(m).to be_a(described_class)
    expect(m).to be_a(Fast::Regexp::Native::MatchData)
    expect(m).to be_native
    expect(m.native).to be(m)
    expect(m.backend).to be(m)
    expect(m.stdlib).to be_nil
  end

  it "reads from a frozen snapshot, so mutating the haystack afterwards changes nothing" do
    haystack = +"key=1 tail"
    m = re.match(haystack)
    haystack.replace("zzzzzzzzzzzzzzzzzzzz")
    expect(m[0]).to eq "key=1"
    expect(m.post_match).to eq " tail"
    expect(m.string).to eq "key=1 tail"
    expect(m.string).to be_frozen
  end

  it "returns the haystack itself from #string when it was already frozen" do
    haystack = "key=1"
    expect(re.match(haystack).string).to be(haystack)
  end

  it "indexes by anything that converts to an Integer, like ::MatchData" do
    m = re.match("key=1")
    expect(m[1.9]).to eq "key"
    expect { m[nil] }.to raise_error(TypeError)
    expect { m[[]] }.to raise_error(TypeError)
  end

  it "aliases #match to #to_s on both paths" do
    expect(re.match("key=1").match).to eq "key=1"
    expect(Fast::Regexp.new('(?<key>\w+)(?=:)').match("key:1").match).to eq "key"
  end

  it "keeps the haystack's encoding when a block form finds nothing to replace" do
    binary = "x=1".b
    expect(Fast::Regexp.new("zzz").gsub(binary) { "!" }.encoding).to eq Encoding::BINARY
    expect(Fast::Regexp.new("zzz").sub(binary) { "!" }.encoding).to eq Encoding::BINARY
  end

  it "splices the block's #to_s for each match" do
    expect(re.gsub("a=1 b=2") { |m| m[:value].to_i * 10 }).to eq "10 20"
    expect(re.sub("a=1 b=2") { :sym }).to eq "sym b=2"
  end

  describe "on the stdlib path" do
    let(:slow) { Fast::Regexp.new('(?<key>\w+)(?=:)') }

    it "answers =~ with a byte offset" do
      expect(slow =~ "  ruby:1").to eq 2
      expect(slow =~ "nothing").to be_nil
    end

    it "derives byte_begin and byte_end from byteoffset" do
      m = slow.match("  ruby:1")
      expect(m.byteoffset(:key)).to eq [2, 6]
      expect(m.byte_begin(1)).to eq 2
      expect(m.byte_end(:key)).to eq 6
    end
  end
end

RSpec.describe Fast::Regexp::MatchData, "review follow-ups" do
  it "keeps interned group names alive from the moment they are made, even under GC stress" do
    names = Array.new(12) { |i| "zq#{i}xj_#{rand(1_000_000)}_wk" }
    pattern = names.each_with_index.map { |n, i| "(?P<#{n}>#{i})" }.join
    GC.stress = true
    re = Fast::Regexp.new(pattern)
    m = re.match((0..11).map(&:to_s).join)
    got = [re.names, m.names, m.named_captures.keys]
    GC.stress = false
    GC.start
    expect(got).to all(eq(names))
    expect(re.names).to eq(names)
  end

  it "negotiates the replacement's encoding in a block form like String#gsub" do
    re = Fast::Regexp.new("l")
    expect { re.gsub("héllo") { "ü".encode("ISO-8859-1") } }.to raise_error(Encoding::CompatibilityError)
    expect(re.gsub("hello") { "ü".encode("ISO-8859-1") }.encoding).to eq(Encoding::ISO_8859_1)
    expect(re.gsub("héllo") { "ü" }).to eq("héüüo")
  end

  it "takes a block result the way String#gsub does: to_s, then Object#to_s if that isn't a String" do
    odd = Object.new
    def odd.to_s = 42
    expect(Fast::Regexp.new("a").gsub("a=1") { odd }).to match(/\A#<Object:0x[0-9a-f]+>=1\z/)
    expect(Fast::Regexp.new("a").gsub("a=1") { :sym }).to eq("sym=1")
  end

  it "answers dup and clone with itself on the fast path" do
    m = Fast::Regexp.new('(\w+)').match("key")
    expect(m.dup).to be(m)
    expect(m.clone).to be(m)
    expect(m.clone(freeze: true)).to be(m)
  end

  it "returns a frozen snapshot from #string on both paths" do
    fast = Fast::Regexp.new('(\w+)=').match(+"a=1")
    slow = Fast::Regexp.new('(?<key>\w+)(?=:)').match(+"a:1")
    expect(fast.string).to eq("a=1").and be_frozen
    expect(slow.string).to eq("a:1").and be_frozen
  end

  it "looks names up from Strings in any encoding, and from objects with to_str" do
    m = Fast::Regexp.new('(?P<clé>\w+)=(?P<value>\d+)').match("a=1")
    expect(m["clé"]).to eq("a")
    expect(m["clé".encode("ISO-8859-1")]).to eq("a")
    expect(m["nope".encode("UTF-16LE")]).to be_nil
    key = Object.new
    def key.to_str = "value"
    expect(m[key]).to eq("1")
  end
end
