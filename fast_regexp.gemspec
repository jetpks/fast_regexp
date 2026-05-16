# frozen_string_literal: true

require_relative "lib/fast_regexp/version"

Gem::Specification.new do |spec|
  spec.name = "fast_regexp"
  spec.version = Fast::Regexp::VERSION
  spec.authors = ["Dmytro Horoshko", "Eric Jacobs"]
  spec.email = ["electric.molfar@gmail.com"]

  spec.summary = "Fast regex for Ruby, backed by rust/regex"
  spec.description = "Ruby bindings to rust/regex with a Fast::Regexp API: MatchData, sub/gsub, ===, =~, named captures, and GVL release for thread/fiber-friendly matching."
  spec.homepage = "https://github.com/jetpks/fast_regexp"
  spec.license = "MIT"
  spec.metadata = {
    "bug_tracker_uri" => "https://github.com/jetpks/fast_regexp/issues",
    "homepage_uri" => "https://github.com/jetpks/fast_regexp",
    "source_code_uri" => "https://github.com/jetpks/fast_regexp"
  }

  spec.files = Dir["lib/**/*.rb", "ext/fast_regexp/src/**/*.rs", "ext/fast_regexp/*.{toml,lock,rb}", "README.md", "LICENSE.txt"]
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/fast_regexp/extconf.rb"]

  spec.required_ruby_version = ">= 3.1.0"
end
