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
