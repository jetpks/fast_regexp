# frozen_string_literal: true

RSpec.describe Fast::Regexp do
  it "has a version number" do
    expect(Fast::Regexp::VERSION).not_to be nil
  end

  describe ".new" do
    it "returns a compiled regexp from a pattern string" do
      expect(described_class.new('\w+')).to be_a(described_class)
    end

    it "accepts a Ruby Regexp and translates trailing flags inline" do
      re = described_class.new(/foo/i)
      expect(re.match?("FOO")).to be true
      expect(re.pattern).to eq "(?i)foo"
    end

    it "translates Ruby's /m (dotall) to rust/regex's (?s)" do
      re = described_class.new(/foo.bar/m)
      expect(re.match?("foo\nbar")).to be true
    end

    it "raises ArgumentError for invalid patterns (rejected by both engines)" do
      expect { described_class.new('(') }.to raise_error(ArgumentError)
    end

    it "falls back to ::Regexp for unsupported features (lookaround)" do
      re = described_class.new('foo(?=bar)')
      expect(re).to be_stdlib
      expect(re).not_to be_fast
      expect(re.match?("foobar")).to be true
      expect(re.match?("foobaz")).to be false
    end

    it "falls back to ::Regexp for backreferences" do
      re = described_class.new('(\w+) \1')
      expect(re).to be_stdlib
      expect(re.match?("hi hi")).to be true
      expect(re.match?("hi bye")).to be false
    end
  end

  describe "fallback API" do
    it "exposes #fast? / #stdlib? and #native / #stdlib for direct access" do
      fast = described_class.new('\w+')
      slow = described_class.new('(?=x)x')

      expect(fast).to be_fast
      expect(fast.native).to be_a(Fast::Regexp::Native)
      expect(fast.stdlib).to be_nil

      expect(slow).to be_stdlib
      expect(slow.stdlib).to be_a(::Regexp)
      expect(slow.native).to be_nil
    end

    it "returns Fast::Regexp::MatchData regardless of backend" do
      m = described_class.new('foo(?=bar)').match("foobar")
      expect(m).to be_a(Fast::Regexp::MatchData)
      expect(m).to be_stdlib
      expect(m[0]).to eq "foo"
      expect(m.stdlib).to be_a(::MatchData)
    end

    it "supports sub/gsub on the stdlib path with rust-style templates" do
      re = described_class.new('(?<g>\w+)(?=:)')
      expect(re).to be_stdlib
      expect(re.sub("ruby:123", '<${g}>')).to eq "<ruby>:123"
      expect(re.gsub("a:1 b:2", '[$1]')).to eq "[a]:1 [b]:2"
    end
  end

  describe ".create_many" do
    it "compiles a hash of patterns into a symbol-keyed hash of Fast::Regexp" do
      re = described_class.create_many(word: '\w+', num: '\d+')
      expect(re.keys).to eq [:word, :num]
      expect(re[:word]).to be_a(described_class)
      expect(re[:num].match("abc 42")[0]).to eq "42"
    end

    it "returns an empty hash when given no patterns" do
      expect(described_class.create_many).to eq({})
    end

    it "propagates compile errors with the offending pattern's context" do
      expect { described_class.create_many(ok: '\w+', bad: '(') }.to raise_error(ArgumentError)
    end
  end

  describe "backend: kwarg" do
    it "defaults to :auto" do
      expect(described_class.new('\w+')).to be_fast
      expect(described_class.new('(?=x)x')).to be_stdlib
    end

    it "with backend: :fast raises instead of falling back" do
      expect { described_class.new('(?=x)x', backend: :fast) }.to raise_error(ArgumentError)
    end

    it "with backend: :fast still compiles supported patterns on rust/regex" do
      re = described_class.new('\w+', backend: :fast)
      expect(re).to be_fast
    end

    it "with backend: :stdlib skips rust/regex even for supported patterns" do
      re = described_class.new('\w+', backend: :stdlib)
      expect(re).to be_stdlib
      expect(re.match?("hello")).to be true
    end

    it "with backend: :stdlib propagates RegexpError for malformed patterns" do
      expect { described_class.new('(', backend: :stdlib) }.to raise_error(::RegexpError)
    end

    it "rejects unknown backend values" do
      expect { described_class.new('\w+', backend: :nope) }.to raise_error(ArgumentError, /backend must be/)
    end
  end

  describe "#match" do
    it "returns nil on no match" do
      expect(described_class.new('\d+').match("abc")).to be_nil
    end

    it "returns a MatchData on hit" do
      m = described_class.new('\w+').match("hello")
      expect(m).to be_a(described_class::MatchData)
      expect(m[0]).to eq "hello"
    end

    it "exposes captures at [1], [2], ..." do
      m = described_class.new('(\w+):(\d+)').match("ruby:123")
      expect(m[0]).to eq "ruby:123"
      expect(m[1]).to eq "ruby"
      expect(m[2]).to eq "123"
    end

    it "supports negative indices" do
      m = described_class.new('(\w+):(\d+)').match("ruby:123")
      expect(m[-1]).to eq "123"
    end

    it "exposes pre_match / post_match" do
      m = described_class.new('\d+').match("abc 42 xyz")
      expect(m.pre_match).to eq "abc "
      expect(m.post_match).to eq " xyz"
    end

    it "exposes byteoffsets" do
      m = described_class.new('\d+').match("abc 42 xyz")
      expect(m.byteoffset(0)).to eq [4, 6]
      expect(m.byte_begin(0)).to eq 4
      expect(m.byte_end(0)).to eq 6
    end

    it "exposes captures and to_a" do
      m = described_class.new('(\w+):(\d+)').match("ruby:123")
      expect(m.captures).to eq ["ruby", "123"]
      expect(m.to_a).to eq ["ruby:123", "ruby", "123"]
      expect(m.size).to eq 3
    end

    it "exposes named captures" do
      m = described_class.new('(?P<word>\w+):(?P<num>\d+)').match("ruby:123")
      expect(m[:word]).to eq "ruby"
      expect(m["num"]).to eq "123"
      expect(m.named_captures).to eq("word" => "ruby", "num" => "123")
      expect(m.names).to eq ["word", "num"]
    end

    it "returns nil for non-participating capture groups" do
      m = described_class.new('(a)|(b)').match("b")
      expect(m[1]).to be_nil
      expect(m[2]).to eq "b"
      expect(m.captures).to eq [nil, "b"]
    end
  end

  describe "#match?" do
    it "returns true/false" do
      re = described_class.new('\d+')
      expect(re.match?("123")).to be true
      expect(re.match?("abc")).to be false
    end
  end

  describe "#===" do
    it "matches against strings" do
      re = described_class.new('^\d+$')
      expect(re === "123").to be true
      expect(re === "abc").to be false
      expect(re === nil).to be false
    end

    it "works inside case/when" do
      result = case "ruby:123"
               when described_class.new('^\d+$') then :num
               when described_class.new('^\w+:\d+$') then :pair
               end
      expect(result).to eq :pair
    end
  end

  describe "#=~" do
    it "returns the byte offset of the first match" do
      expect(described_class.new('\d+') =~ "abc 42").to eq 4
    end

    it "returns nil on no match" do
      expect(described_class.new('\d+') =~ "abc").to be_nil
    end
  end

  describe "#scan" do
    it "returns matches as strings when there are no capture groups" do
      expect(described_class.new('\w+').scan("a b c")).to eq ["a", "b", "c"]
    end

    it "returns arrays of captures when there are capture groups" do
      expect(described_class.new('(\w):(\d)').scan("a:1 b:2")).to eq [["a", "1"], ["b", "2"]]
    end
  end

  describe "#scan_matches" do
    it "returns an array of MatchData for each match" do
      matches = described_class.new('(\w+):(\d+)').scan_matches("ruby:123 rust:456")
      expect(matches.length).to eq 2
      expect(matches.map { |m| m[0] }).to eq ["ruby:123", "rust:456"]
      expect(matches[1].byteoffset(0)).to eq [9, 17]
    end
  end

  describe "#sub" do
    it "replaces the first match using rust/regex templates" do
      re = described_class.new('(\w+):(\d+)')
      expect(re.sub("ruby:123 rust:456", '$2-$1')).to eq "123-ruby rust:456"
    end

    it "supports a block taking MatchData" do
      re = described_class.new('\d+')
      result = re.sub("count:42 left:7") { |m| (m[0].to_i * 2).to_s }
      expect(result).to eq "count:84 left:7"
    end

    it "supports literal: true to treat $-references as text" do
      re = described_class.new('foo')
      expect(re.sub("foo", '$1 wins', literal: true)).to eq "$1 wins"
    end

    it "returns a copy of the haystack on no match (block form)" do
      re = described_class.new('XXX')
      expect(re.sub("foo") { "bar" }).to eq "foo"
    end
  end

  describe "#gsub" do
    it "replaces every match using rust/regex templates" do
      re = described_class.new('(\w+):(\d+)')
      expect(re.gsub("ruby:123 rust:456", '$2-$1')).to eq "123-ruby 456-rust"
    end

    it "supports a block taking MatchData for every match" do
      re = described_class.new('\d+')
      result = re.gsub("a1 b22 c333") { |m| "<#{m[0].size}>" }
      expect(result).to eq "a<1> b<2> c<3>"
    end

    it "handles a haystack with no matches" do
      expect(described_class.new('\d+').gsub("abc", 'X')).to eq "abc"
      expect(described_class.new('\d+').gsub("abc") { "X" }).to eq "abc"
    end
  end

  describe "#pattern / #inspect / #to_s" do
    it "returns the source pattern" do
      re = described_class.new('\w+')
      expect(re.pattern).to eq '\w+'
      expect(re.to_s).to eq '\w+'
      expect(re.inspect).to eq '#<Fast::Regexp "\\\\w+">'
    end
  end

  describe "concurrency" do
    let(:large_haystack) { (("foo:#{rand(1_000_000)} " * 200) + "ruby:42") }

    it "is correct for haystacks above the GVL-release threshold" do
      m = described_class.new('(\w+):(\d+)').match(large_haystack)
      expect(m).not_to be_nil
      expect(m[0]).to be_a(String)
    end

    it "is safe to call from many threads in parallel" do
      re = described_class.new('(\w+):(\d+)')
      threads = 8.times.map do
        Thread.new do
          50.times.map { re.scan(large_haystack).length }
        end
      end
      expected = re.scan(large_haystack).length
      expect(threads.map(&:value).flatten.uniq).to eq [expected]
    end

    it "is safe to call from fibers" do
      require "fiber"
      re = described_class.new('\d+')
      results = []
      fibers = 4.times.map do |i|
        Fiber.new(blocking: false) do
          results << re.scan("count:#{i} " + large_haystack).length
        end
      end
      fibers.each(&:resume)
      expect(results.uniq.length).to eq 1
    end
  end
end
