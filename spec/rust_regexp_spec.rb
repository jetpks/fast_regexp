# frozen_string_literal: true

RSpec.describe RustRegexp do
  it "has a version number" do
    expect(RustRegexp::VERSION).not_to be nil
  end

  describe ".new" do
    it "returns a compiled regexp" do
      re = described_class.new('\w+')
      expect(re).to be_a(described_class)
    end
  end

  describe "#match" do
    examples = [
      ['\w+:\d+', "ruby:123, rust:456", {}, ["ruby:123"]],
      ['(\w+):(\d+)', 'ruby:123, rust:456', {}, ["ruby", "123"]],
      ['(\w+):(\d+)', '123', {}, []],
      ['\w+', "абв", {}, ["абв"]],
      ['\w+', "абв", {unicode: false}, []],
    ]

    examples.each do |pattern, haystack, options, expected_matches|
      context "with pattern: #{pattern.inspect}, haystack: #{haystack.inspect}" do
        it "returns #{expected_matches.inspect}" do
          re = described_class.new(pattern, **options)
          matches = re.match(haystack)

          expect(matches).to eq expected_matches
        end
      end
    end
  end

  describe "#scan" do
    examples = [
      ['\w+:\d+', "ruby:123, rust:456", {}, ["ruby:123", "rust:456"]],
      ['(\w+):(\d+)', 'ruby:123, rust:456', {}, [["ruby", "123"], ["rust", "456"]]],
      ['(\w+):(\d+)', '123', {}, []],
      ['\w:\w', "а:б", {}, ["а:б"]],
      ['\w:\w', "а:б", {unicode: false}, []],
    ]

    examples.each do |pattern, haystack, options, expected_matches|
      context "with pattern: #{pattern.inspect}, haystack: #{haystack.inspect}" do
        it "returns #{expected_matches.inspect}" do
          re = described_class.new(pattern, **options)
          matches = re.scan(haystack)

          expect(matches).to eq expected_matches
        end
      end
    end
  end

  describe "#match?" do
    it "checks whether regexp is matched" do
      re = described_class.new('\d+')

      expect(re.match?("123")).to eq true
      expect(re.match?("abc")).to eq false
    end
  end

  describe "#pattern" do
    it "returns original regular expression pattern" do
      re = described_class.new('\w+')
      expect(re.pattern).to eq '\w+'
    end
  end

  describe "concurrency" do
    # Haystacks larger than the in-extension GVL_RELEASE_THRESHOLD (1024 bytes)
    # exercise the rb_thread_call_without_gvl path so other Ruby threads /
    # fibers can run while a match is in progress.
    let(:large_haystack) { (("foo:#{rand(1_000_000)} " * 200) + "ruby:42") }

    it "returns correct results for haystacks above the GVL-release threshold" do
      re = described_class.new('(\w+):(\d+)')
      result = re.match(large_haystack)
      expect(result.length).to eq 2
      expect(result[0]).to be_a(String)
    end

    it "is safe to call from many threads in parallel" do
      re = described_class.new('(\w+):(\d+)')
      threads = 8.times.map do
        Thread.new do
          50.times.map { re.scan(large_haystack).length }
        end
      end
      results = threads.map(&:value)
      expected = re.scan(large_haystack).length
      expect(results.flatten.uniq).to eq [expected]
    end

    it "is safe to call from fibers under a fiber scheduler" do
      require "fiber"
      re = described_class.new('\d+')
      results = []
      fibers = 4.times.map do |i|
        Fiber.new(blocking: false) do
          results << [i, re.scan("count:#{i} " + large_haystack).length]
        end
      end
      fibers.each(&:resume)
      expect(results.length).to eq 4
      expect(results.map { |_, n| n }.uniq.length).to eq 1
    end
  end
end
