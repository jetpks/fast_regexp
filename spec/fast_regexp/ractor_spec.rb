# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "Ractor support" do
  def ractor_value(ractor)
    ractor.respond_to?(:value) ? ractor.value : ractor.take
  end

  it "makes a compiled pattern and its native backend shareable" do
    re = Fast::Regexp.new(".*")
    expect(Ractor.make_shareable(re)).to be(re)
    expect(Ractor.shareable?(re)).to be true
    expect(Ractor.shareable?(re.native)).to be true
  end

  [false, true].each do |warm_names|
    it "uses one pattern concurrently with #{warm_names ? 'warmed' : 'unwarmed'} capture names" do
      re = Fast::Regexp.new('(?P<word>\w+)=(?P<num>\d+)')
      re.names if warm_names
      Ractor.make_shareable(re)

      workers = Array.new(4) do
        Ractor.new(re) do |pattern|
          Ractor.receive
          10.times.map do
            match = pattern.match("a=1 b=2")
            [pattern.object_id, pattern.match?("a=1"), pattern === "a=1",
             pattern =~ " a=1", pattern.names, pattern.captures_count,
             match[:word], match.named_captures, match.byteoffset(:num),
             pattern.scan("a=1 b=2"), pattern.scan_matches("a=1 b=2").map(&:to_s),
             pattern.sub("a=1 b=2", "$2:$1"), pattern.gsub("a=1 b=2", "${num}"),
             pattern.sub("a=1 b=2") { |m| m[:num] },
             pattern.gsub("a=1 b=2") { |m| m[:word].upcase }]
          end
        end
      end

      workers.each { |worker| worker.send(:start) }
      expected = [re.object_id, true, true, 1, %w[word num], 2,
                  "a", {"word" => "a", "num" => "1"}, [2, 3],
                  [["a", "1"], ["b", "2"]], ["a=1", "b=2"],
                  "1:a b=2", "1 2", "1 b=2", "A B"]

      expect(workers.map { |worker| ractor_value(worker) }).to all(eq([expected] * 10))
    end
  end

  it "shares a match and keeps its snapshot and capture names alive after GC" do
    haystack = +" before a=1 after"
    match = Fast::Regexp.new('(?P<word>\w+)=(?P<num>\d+)').match(haystack)
    Ractor.make_shareable(match)
    haystack.replace("changed")
    GC.start
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    worker = Ractor.new(match) do |m|
      [Ractor.shareable?(m), Ractor.shareable?(m.string), m.names,
       m.named_captures, m.to_a, m.captures, m.pre_match, m.post_match,
       m.byteoffset(:word), m.string]
    end
    expect(ractor_value(worker)).to eq([
      true, true, %w[word num], {"word" => "a", "num" => "1"},
      ["a=1", "a", "1"], ["a", "1"], " before ", " after", [8, 9],
      " before a=1 after"
    ])
  end

  it "shares an entire scan_matches result" do
    matches = Fast::Regexp.new('(?P<word>\w+)=(?P<num>\d+)').scan_matches("a=1 b=2")
    Ractor.make_shareable(matches)
    expect(Ractor.shareable?(matches)).to be true
    worker = Ractor.new(matches) do |ms|
      ms.map { |m| [m.to_s, m.named_captures, m.string, m.byteoffset(:num)] }
    end
    expect(ractor_value(worker)).to eq([
      ["a=1", {"word" => "a", "num" => "1"}, "a=1 b=2", [2, 3]],
      ["b=2", {"word" => "b", "num" => "2"}, "a=1 b=2", [6, 7]]
    ])
  end

  it "shares a set between ractors" do
    set = Ractor.make_shareable(Fast::Regexp::Set.new(["abc", "def", "xyz"]))
    workers = Array.new(4) do
      Ractor.new(set) do |patterns|
        [patterns.object_id, patterns.match("abcdef"), patterns.match?("xyz"), patterns.patterns]
      end
    end
    expect(workers.map { |worker| ractor_value(worker) })
      .to all(eq([set.object_id, [0, 1], true, ["abc", "def", "xyz"]]))
  end

  it "shares a stdlib match result" do
    match = Ractor.make_shareable(Fast::Regexp.new('(?<word>\w+)(?=:)').match("ruby:1"))
    worker = Ractor.new(match) { |m| [Ractor.shareable?(m), m[:word], m.named_captures, m.string] }
    expect(ractor_value(worker)).to eq([true, "ruby", {"word" => "ruby"}, "ruby:1"])
  end

  [false, true].each do |warm_replacement|
    it "substitutes with a shared stdlib pattern #{warm_replacement ? 'after' : 'before'} first use" do
      re = Fast::Regexp.new('(?<word>\w+)(?=:)')
      re.gsub("a:1", "$1") if warm_replacement
      Ractor.make_shareable(re)
      worker = Ractor.new(re) do |pattern|
        [pattern.sub("a:1 b:2", "[$1]"), pattern.gsub("a:1 b:2", "[${word}]"),
         pattern.gsub("a:1 b:2", "[$1]"), pattern.gsub("a:1 b:2") { |m| m[:word].upcase }]
      end
      expect(ractor_value(worker)).to eq(["[a]:1 b:2", "[a]:1 [b]:2", "[a]:1 [b]:2", "A:1 B:2"])
    end
  end

  it "substitutes with a manually frozen stdlib-backed pattern" do
    re = Fast::Regexp.new('(?<word>\w+)(?=:)')
    expect(re.stdlib?).to be(true)
    re.freeze
    expect(re.sub("a:1 b:2", "[$1]")).to eq("[a]:1 b:2")
    expect(re.gsub("a:1 b:2", "[${word}]")).to eq("[a]:1 [b]:2")
    expect(re.sub("a:1 b:2") { |m| m[:word].upcase }).to eq("A:1 b:2")
    expect(re.gsub("a:1 b:2") { |m| m[:word].upcase }).to eq("A:1 B:2")
    expect(re).to be_frozen
  end

  it "raises native errors inside workers" do
    compiler = Ractor.new do
      begin
        Fast::Regexp.new("(", backend: :fast)
        nil
      rescue ArgumentError => e
        [e.class, e.message]
      end
    end
    error_class, message = ractor_value(compiler)
    expect(error_class).to be(ArgumentError)
    expect(message).to include("regex parse error", "unclosed group")

    lookup = Ractor.new do
      begin
        Fast::Regexp.new("a").match("a")[nil]
        nil
      rescue TypeError => e
        [e.class, e.message]
      end
    end
    error_class, message = ractor_value(lookup)
    expect(error_class).to be(TypeError)
    expect(message).to include("no implicit conversion of capture key")
  end

  it "moving an unshared native match fails" do
    worker = Ractor.new { Ractor.receive }
    match = Fast::Regexp.new('(?P<word>\w+)=(?P<num>\d+)').match("a=1 b=2")
    expect(Ractor.shareable?(match)).to be false
    # Ruby 3.4: TypeError "allocator undefined for Fast::Regexp::Native::MatchData";
    # Ruby 4.0: Ractor::Error "can not move Fast::Regexp::Native::MatchData object."
    expected = RUBY_VERSION.start_with?("3.") ? TypeError : Ractor::Error
    expect { worker.send(match, move: true) }.to raise_error(expected, /Fast::Regexp::Native::MatchData/)
    worker.send(:done)
    expect(ractor_value(worker)).to be(:done)
  end

  it "constructs and uses every native type first in non-main ractors" do
    source = <<~'RUBY'
      require "fast_regexp"
      GC.stress = true if %w[1 true yes].include?(ENV["GC_STRESS"].to_s.downcase)
      workers = Array.new(4) do
        Ractor.new do
          re = Fast::Regexp.new(/(?<word>foo)/i)
          match = re.match("FOO")
          set = Fast::Regexp::Set.new(["foo"])
          raise "bad match" unless match[:word] == "FOO" && re.names == ["word"]
          raise "bad set" unless set.match("foo") == [0]
          Ractor.make_shareable(match)
        end
      end
      workers.each do |worker|
        match = worker.respond_to?(:value) ? worker.value : worker.take
        raise "bad shared match" unless Ractor.shareable?(match) && match[:word] == "FOO"
      end
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", source)
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end

  it "loads the library for the first time from concurrent workers" do
    source = <<~'RUBY'
      workers = Array.new(4) do
        Ractor.new do
          require "fast_regexp"
          Fast::Regexp.new("foo").match?("foo")
        end
      end
      workers.each do |worker|
        result = worker.respond_to?(:value) ? worker.value : worker.take
        raise "bad match" unless result == true
      end
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", source)
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
